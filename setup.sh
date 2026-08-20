#!/bin/sh
set -eu

# Create var/ directory structure
echo "Creating var/ directory structure..."
mkdir -p var/lib/llama
mkdir -p var/lib/llama-home
mkdir -p var/lib/webui
mkdir -p var/run/sockets
mkdir -p var/run/nginx
mkdir -p var/run/litellm
echo "Directories created successfully."

# Create nginx/certs directory for certificates
echo "Creating nginx/certs directory..."
mkdir -p nginx/certs

# The SANs the server cert must carry. `host.docker.internal` is the one the
# webui container uses to reach nginx over TLS with verification on, so a cert
# without it breaks every webui -> API request.
CERT_SANS="DNS:localhost, DNS:host.docker.internal, IP:127.0.0.1"
REISSUED=0

# Certs generated before webui moved to host.docker.internal (it used the
# pinned bridge gateway 172.31.0.1, since removed) have no such SAN. Those
# files exist and look fine, so a plain existence check silently keeps serving
# them and Open WebUI fails hostname verification on every call. Treat a cert
# missing the SAN as stale and reissue it.
cert_is_stale() {
    [ -f nginx/certs/server.crt ] || return 0
    openssl x509 -in nginx/certs/server.crt -noout -ext subjectAltName 2>/dev/null \
      | grep -q 'host\.docker\.internal' && return 1
    return 0
}

# The CA is only created once. Reissuing it would invalidate the copy baked
# into the webui image at build time (webui/Dockerfile), so it is deliberately
# untouched when it already exists.
echo "Generating certificates..."
if [ ! -f nginx/certs/ca.key ] || [ ! -f nginx/certs/ca.crt ]; then
    echo "Generating CA certificate..."
    openssl req -x509 -newkey rsa:4096 -nodes -keyout nginx/certs/ca.key \
      -out nginx/certs/ca.crt -days 3650 -subj "/CN=llamacpp-serve CA" 2>/dev/null
    echo "CA generated."
else
    echo "CA already exists, keeping it (webui's baked-in copy must keep matching)."
fi

# The server cert is (re)issued when missing or stale. Signed by the existing
# CA, so the webui image does not need rebuilding -- only nginx restarting.
if [ ! -f nginx/certs/server.key ] || [ ! -f nginx/certs/server.crt ] || cert_is_stale; then
    if [ -f nginx/certs/server.crt ]; then
        echo "Existing server.crt lacks DNS:host.docker.internal (pre-upgrade cert)."
        echo "Reissuing it from the existing CA."
        REISSUED=1
    fi
    rm -f nginx/certs/server.csr

    echo "Generating server key and CSR..."
    openssl req -newkey rsa:4096 -nodes -keyout nginx/certs/server.key \
      -out nginx/certs/server.csr -subj "/CN=localhost" 2>/dev/null

    echo "Signing server certificate..."
    openssl x509 -req -in nginx/certs/server.csr \
      -CA nginx/certs/ca.crt -CAkey nginx/certs/ca.key \
      -CAcreateserial -out nginx/certs/server.crt -days 3650 \
      -extensions v3_req -extfile /dev/stdin <<EOF
[ v3_req ]
subjectAltName = $CERT_SANS
EOF
    echo "Server certificate issued for: $CERT_SANS"
else
    echo "Server certificate is current, skipping generation."
fi

# Create .env with generated secrets if it does not exist yet. The default
# stack does not need it; it is ready for docker-compose.litellm.yml.
#
# An .env that predates a setting is migrated rather than replaced: the LiteLLM
# overlay interpolates ${LITELLM_WEBUI_KEY:?...}, and Compose fails that at
# *parse* time -- before any service starts and regardless of env_file -- so an
# un-migrated .env breaks `docker compose up` outright on upgrade.
echo "Checking .env..."

# Append KEY=VALUE only when KEY is absent or empty. Never overwrites a value
# the operator has set.
ensure_env() {
    _key="$1"
    _val="$2"
    if grep -qE "^${_key}=.+" .env 2>/dev/null; then
        return 0
    fi
    # Drop a present-but-empty assignment so we do not end up with two.
    if grep -qE "^${_key}=$" .env 2>/dev/null; then
        sed -i.bak "/^${_key}=$/d" .env && rm -f .env.bak
    fi
    printf '%s=%s\n' "$_key" "$_val" >> .env
    echo "  + added $_key"
    MIGRATED=1
}

if [ ! -f .env ]; then
    echo "Creating .env from .env.example with generated secrets..."
    MASTER_KEY="sk-$(openssl rand -hex 24)"
    SALT_KEY="$(openssl rand -hex 24)"
    UI_PW="$(openssl rand -hex 12)"
    DB_PW="$(openssl rand -hex 24)"
    # The WebUI starts on the master key so the stack comes up in one shot
    # once LiteLLM is enabled; swap it for a dedicated virtual key afterwards.
    sed \
      -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$SALT_KEY|" \
      -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UI_PW|" \
      -e "s|^LITELLM_WEBUI_KEY=.*|LITELLM_WEBUI_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_DB_PASSWORD=.*|LITELLM_DB_PASSWORD=$DB_PW|" \
      .env.example > .env
    chmod 600 .env
    echo ".env created. LiteLLM is optional (append :docker-compose.litellm.yml to COMPOSE_FILE)."
else
    echo ".env exists; checking for settings added since it was written..."
    MIGRATED=0

    # Reuse the existing master key where one is present, so a migrated .env
    # comes up without the operator having to mint a virtual key first.
    EXISTING_MASTER=$(sed -n 's|^LITELLM_MASTER_KEY=\(.\{1,\}\)$|\1|p' .env | head -1)
    [ -n "$EXISTING_MASTER" ] || EXISTING_MASTER="sk-$(openssl rand -hex 24)"

    ensure_env LITELLM_MASTER_KEY "$EXISTING_MASTER"
    ensure_env LITELLM_SALT_KEY   "$(openssl rand -hex 24)"
    ensure_env UI_USERNAME        "admin"
    ensure_env UI_PASSWORD        "$(openssl rand -hex 12)"
    ensure_env LITELLM_WEBUI_KEY  "$EXISTING_MASTER"

    # Deliberately the historical default, NOT a fresh random value: Postgres
    # only applies POSTGRES_PASSWORD when initdb runs on an empty volume, so
    # handing an existing postgres-data volume a new password would lock
    # LiteLLM out of its own database. Rotating it is a manual, documented
    # step (see README, "Rotating the bundled Postgres password").
    ensure_env LITELLM_DB_PASSWORD "litellm"

    if [ "$MIGRATED" -eq 1 ]; then
        chmod 600 .env
        echo ".env migrated. Review the appended values before starting LiteLLM."
    else
        echo ".env is already complete, leaving it alone."
    fi
fi

# Ownership and permissions come before model-list generation: the generator
# is only needed by the *optional* LiteLLM overlay and can legitimately fail
# (e.g. more GGUFs than routers), and under `set -e` that would otherwise abort
# the script with the private keys still world-readable.

# Set proper ownership (1000:1000). Needs root on the DGX.
echo "Setting proper ownership..."
if [ "$(id -u)" -eq 0 ]; then
    chown -R 1000:1000 var/
    chown -R 1000:1000 nginx/certs
    chown 1000:1000 .env
    echo "Ownership set successfully."
else
    echo "Not root; skipping chown 1000:1000. Run as root on the DGX so uid 1000 owns var/."
fi

# Restrict private key permissions (owner read/write only)
echo "Restricting private key permissions..."
chmod 600 nginx/certs/*.key
echo "Permissions restricted successfully."

# Generate the LiteLLM model list from whatever GGUFs are present. Harmless
# with an empty model store; required before enabling LiteLLM. Non-fatal: the
# default stack does not read this file, so a store the generator cannot pin
# (more standalone GGUFs than routers, or an unsupported filename) must not
# stop the default stack from being set up.
echo "Generating LiteLLM model list..."
GEN_OK=1
./litellm/gen-models.sh || GEN_OK=0
if [ "$GEN_OK" -eq 0 ]; then
    echo ""
    echo "WARNING: could not generate the LiteLLM model list (see the errors above)."
    echo "         The default stack is unaffected and is ready to start."
    echo "         Fix the model store and re-run ./litellm/gen-models.sh before"
    echo "         enabling docker-compose.litellm.yml."
fi

# Re-apply ownership to the file the generator just wrote (if it ran).
if [ "$(id -u)" -eq 0 ] && [ "$GEN_OK" -eq 1 ]; then
    chown -R 1000:1000 var/run/litellm
fi

echo ""
echo "Setup complete!"
echo ""
if [ "$REISSUED" -eq 1 ]; then
    echo "NOTE: the server certificate was reissued. Recreate the TLS consumers:"
    echo "  docker compose up -d --force-recreate nginx webui"
    echo ""
fi
echo "Next steps:"
echo "  1. Drop .gguf files into var/lib/llama/"
echo "  2. docker compose up --build -d"
echo ""
echo "Optional — LiteLLM gateway (auth, rate limits, one model per server):"
echo "  Needs at most one standalone .gguf per llama-server (2 by default)."
echo "  1. ./litellm/gen-models.sh"
echo "  2. COMPOSE_FILE=docker-compose.yml:docker-compose.litellm.yml in .env"
echo "  3. docker compose up -d"
echo "  4. Open https://localhost:11437/ui with UI_USERNAME / UI_PASSWORD"
echo ""

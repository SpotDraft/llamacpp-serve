#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

echo "Creating base stack directories..."
mkdir -p var/lib/llama
mkdir -p var/lib/llama-home
mkdir -p var/lib/webui
mkdir -p var/run/sockets
mkdir -p var/run/nginx
mkdir -p nginx/certs
echo "Base directories created."

# Read a setting from the environment first, then .env, so both work:
#   CERT_HOSTNAME=dgx.example.com scripts/setup-base-stack.sh
env_or_dotenv() {
    eval "_v=\${$1:-}"
    if [ -z "$_v" ] && [ -f .env ]; then
        _v=$(sed -n "s|^$1=\(.\{1,\}\)$|\1|p" .env | head -1)
    fi
    printf '%s' "$_v"
}

# TLS SANs. localhost / host.docker.internal / 127.0.0.1 are always present:
# WebUI and the health checks reach nginx by those names. Any OTHER name a
# client connects by -- a tailnet name, a LAN IP -- must be declared here, or
# that client fails hostname verification even after trusting our CA.
CERT_HOSTNAME=$(env_or_dotenv CERT_HOSTNAME)
CERT_EXTRA_SANS=$(env_or_dotenv CERT_EXTRA_SANS)

CERT_SANS="DNS:localhost, DNS:host.docker.internal, IP:127.0.0.1"
[ -n "$CERT_HOSTNAME" ] && CERT_SANS="$CERT_SANS, DNS:$CERT_HOSTNAME"
[ -n "$CERT_EXTRA_SANS" ] && CERT_SANS="$CERT_SANS, $CERT_EXTRA_SANS"
REISSUED=0
CA_NEW=0

# Stale = the live cert is missing any name in $CERT_SANS. Derived from
# CERT_SANS rather than hardcoding one name: a fixed probe reports "current"
# for a cert that predates a newly added SAN, so the new name never gets issued.
cert_is_stale() {
    [ -f nginx/certs/server.crt ] || return 0
    _live=$(openssl x509 -in nginx/certs/server.crt -noout -ext subjectAltName 2>/dev/null) || return 0
    # openssl prints "IP Address:1.2.3.4" where CERT_SANS says "IP:1.2.3.4".
    _live=$(printf '%s\n' "$_live" | sed 's/IP Address:/IP:/g' | tr ',' '\n' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -E '^(DNS|IP):')
    for _san in $(printf '%s\n' "$CERT_SANS" | tr ',' '\n' \
                  | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); do
        [ -n "$_san" ] || continue
        printf '%s\n' "$_live" | grep -qxF -- "$_san" || return 0
    done
    return 1
}

cert_ca_mismatch() {
    [ -f nginx/certs/server.crt ] && [ -f nginx/certs/ca.crt ] || return 1
    openssl verify -CAfile nginx/certs/ca.crt nginx/certs/server.crt >/dev/null 2>&1 && return 1
    return 0
}

cert_key_mismatch() {
    [ -f nginx/certs/server.crt ] || return 1
    [ -f nginx/certs/server.key ] || return 0
    _cert_pub=$(openssl x509 -in nginx/certs/server.crt -noout -pubkey 2>/dev/null) || return 0
    _key_pub=$(openssl pkey -in nginx/certs/server.key -pubout 2>/dev/null) || return 0
    [ -n "$_cert_pub" ] && [ -n "$_key_pub" ] && [ "$_cert_pub" = "$_key_pub" ] && return 1
    return 0
}

echo "Checking certificates..."
if [ ! -f nginx/certs/ca.key ] || [ ! -f nginx/certs/ca.crt ]; then
    echo "Generating CA certificate..."
    openssl req -x509 -newkey rsa:4096 -nodes -keyout nginx/certs/ca.key \
      -out nginx/certs/ca.crt -days 3650 -subj "/CN=llamacpp-serve CA" 2>/dev/null
    CA_NEW=1
    echo "CA generated."
else
    echo "CA already exists, keeping it (WebUI's baked-in copy must keep matching)."
fi

if [ ! -f nginx/certs/server.key ] || [ ! -f nginx/certs/server.crt ] \
   || cert_is_stale || [ "$CA_NEW" -eq 1 ] || cert_ca_mismatch \
   || cert_key_mismatch; then
    if [ -f nginx/certs/server.crt ]; then
        if cert_is_stale; then
            echo "Existing server.crt is missing one or more names in CERT_SANS."
        elif cert_key_mismatch; then
            echo "Existing server.key is invalid or does not match server.crt."
        else
            echo "Existing server.crt was signed by a different CA."
        fi
        echo "Reissuing it."
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
    echo "Server certificate is current."
fi

echo "Setting base stack ownership..."
if [ "$(id -u)" -eq 0 ]; then
    chown -R 1000:1000 var/lib/llama var/lib/llama-home var/lib/webui
    chown -R 1000:1000 var/run/sockets var/run/nginx nginx/certs
    echo "Ownership set to 1000:1000."
else
    echo "Not root; skipping chown 1000:1000. Run as root on the DGX."
fi

chmod 600 nginx/certs/*.key

echo ""
echo "Base stack setup complete."
if [ "$REISSUED" -eq 1 ] && [ "$CA_NEW" -eq 1 ]; then
    echo "A new CA was generated. Rebuild WebUI so its baked-in CA is current:"
    echo "  docker compose up -d --build --force-recreate nginx webui"
elif [ "$REISSUED" -eq 1 ]; then
    echo "The server certificate was reissued from the existing CA. Recreate TLS consumers:"
    echo "  docker compose up -d --force-recreate nginx webui"
fi
echo ""
echo "Next:"
echo "  1. Drop .gguf files into var/lib/llama/"
echo "  2. docker compose up --build -d"

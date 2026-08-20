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

# Generate local CA and server certificate only if they don't already exist
echo "Generating certificates..."
if [ ! -f nginx/certs/ca.key ] || [ ! -f nginx/certs/ca.crt ] || \
   [ ! -f nginx/certs/server.key ] || [ ! -f nginx/certs/server.crt ]; then
    echo "Generating CA certificate..."
    openssl req -x509 -newkey rsa:4096 -nodes -keyout nginx/certs/ca.key \
      -out nginx/certs/ca.crt -days 3650 -subj "/CN=llamacpp-serve CA" 2>/dev/null

    echo "Generating server key and CSR..."
    openssl req -newkey rsa:4096 -nodes -keyout nginx/certs/server.key \
      -out nginx/certs/server.csr -subj "/CN=localhost" 2>/dev/null

    echo "Generating and signing server certificate..."
    openssl x509 -req -in nginx/certs/server.csr \
      -CA nginx/certs/ca.crt -CAkey nginx/certs/ca.key \
      -CAcreateserial -out nginx/certs/server.crt -days 3650 \
      -extensions v3_req -extfile /dev/stdin <<EOF
[ v3_req ]
subjectAltName = DNS:localhost, DNS:host.docker.internal, IP:127.0.0.1, IP:172.31.0.1
EOF
    echo "Certificates generated successfully."
else
    echo "Certificates already exist, skipping generation."
fi

# Create .env with generated secrets if it does not exist yet. The default
# stack does not need it; it is ready for docker-compose.litellm.yml.
echo "Checking .env..."
if [ ! -f .env ]; then
    echo "Creating .env from .env.example with generated secrets..."
    MASTER_KEY="sk-$(openssl rand -hex 24)"
    SALT_KEY="$(openssl rand -hex 24)"
    UI_PW="$(openssl rand -hex 12)"
    # The WebUI starts on the master key so the stack comes up in one shot
    # once LiteLLM is enabled; swap it for a dedicated virtual key afterwards.
    sed \
      -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$SALT_KEY|" \
      -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UI_PW|" \
      -e "s|^LITELLM_WEBUI_KEY=.*|LITELLM_WEBUI_KEY=$MASTER_KEY|" \
      .env.example > .env
    chmod 600 .env
    echo ".env created. LiteLLM is optional (append :docker-compose.litellm.yml to COMPOSE_FILE)."
else
    echo ".env already exists, leaving it alone."
fi

# Generate the LiteLLM model list from whatever GGUFs are present. Harmless
# with an empty model store; required before enabling LiteLLM. Fails if more
# than two standalone GGUFs are in var/lib/llama (one per llama-server).
echo "Generating LiteLLM model list..."
./litellm/gen-models.sh

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

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Drop at most 2 .gguf files into var/lib/llama/"
echo "  2. docker compose up --build -d"
echo ""
echo "Optional — LiteLLM gateway (auth, rate limits, one model per server):"
echo "  1. ./litellm/gen-models.sh"
echo "  2. COMPOSE_FILE=docker-compose.yml:docker-compose.litellm.yml in .env"
echo "  3. docker compose up -d"
echo "  4. Open https://localhost:11437/ui with UI_USERNAME / UI_PASSWORD"
echo ""

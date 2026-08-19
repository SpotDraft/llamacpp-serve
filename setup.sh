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
subjectAltName = DNS:localhost, IP:127.0.0.1, IP:172.31.0.1
EOF
    echo "Certificates generated successfully."
else
    echo "Certificates already exist, skipping generation."
fi

# Create .env with generated secrets if it does not exist yet
echo "Checking .env..."
if [ ! -f .env ]; then
    echo "Creating .env from .env.example with generated secrets..."
    MASTER_KEY="sk-$(openssl rand -hex 24)"
    SALT_KEY="$(openssl rand -hex 24)"
    UI_PW="$(openssl rand -hex 12)"
    # The WebUI starts on the master key so the stack comes up in one shot;
    # swap it for a dedicated virtual key from the Admin UI afterwards.
    sed \
      -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$SALT_KEY|" \
      -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UI_PW|" \
      -e "s|^LITELLM_WEBUI_KEY=.*|LITELLM_WEBUI_KEY=$MASTER_KEY|" \
      .env.example > .env
    chmod 600 .env
    echo ".env created. You MUST still set DATABASE_URL to your remote Postgres."
else
    echo ".env already exists, leaving it alone."
fi

# Generate the LiteLLM model list from whatever GGUFs are present. Safe to run
# with an empty model store; re-run it after adding models.
echo "Generating LiteLLM model list..."
./litellm/gen-models.sh

# Set proper ownership (1000:1000)
echo "Setting proper ownership..."
chown -R 1000:1000 var/
chown -R 1000:1000 nginx/certs
# This script needs root for the chowns above, so .env would otherwise be left
# root-owned and mode 600 -- unreadable by the user running docker compose.
chown 1000:1000 .env
echo "Ownership set successfully."

# Restrict private key permissions (owner read/write only)
echo "Restricting private key permissions..."
chmod 600 nginx/certs/*.key
echo "Permissions restricted successfully."

echo ""
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Set DATABASE_URL in .env to your remote Postgres (LiteLLM needs DDL"
echo "     rights; it migrates its schema on startup)."
echo "  2. Review the OTEL_ENDPOINT in .env. If you do not run a collector,"
echo "     comment out the 'otel' callback in litellm/config.yaml."
echo "  3. Drop .gguf files into var/lib/llama/ and re-run ./litellm/gen-models.sh"
echo "  4. docker compose up --build -d"
echo ""
echo "Then open the LiteLLM Admin UI at https://localhost:11437/ui"
echo "(user: \$UI_USERNAME, password: \$UI_PASSWORD from .env) to create"
echo "per-client virtual keys with their own rate limits and budgets."

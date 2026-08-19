#!/bin/sh
set -eu

# Create var/ directory structure
echo "Creating var/ directory structure..."
mkdir -p var/lib/llama
mkdir -p var/lib/llama-home
mkdir -p var/lib/webui
mkdir -p var/run/sockets
mkdir -p var/run/nginx
echo "Directories created successfully."

# Seed .env from the template. Never overwrite an existing one — it is the
# only file holding local settings (and possibly a backend token).
echo "Checking .env..."
if [ ! -f .env ]; then
    cp .env.example .env
    echo ".env created from .env.example (all optional features off)."
else
    echo ".env already exists, leaving it alone."
fi

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

# Set proper ownership (1000:1000)
echo "Setting proper ownership..."
chown -R 1000:1000 var/
chown -R 1000:1000 nginx/certs
echo "Ownership set successfully."

# Restrict private key permissions (owner read/write only)
echo "Restricting private key permissions..."
chmod 600 nginx/certs/*.key
echo "Permissions restricted successfully."

echo "Setup complete! Run 'docker compose up --build -d' to start the stack."

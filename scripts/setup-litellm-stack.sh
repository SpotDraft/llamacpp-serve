#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/setup-base-stack.sh"

echo ""
echo "Creating LiteLLM runtime directories..."
mkdir -p var/run/litellm

postgres_volume_exists() {
    command -v docker >/dev/null 2>&1 || return 1
    project=$(sed -n 's|^name:[[:space:]]*\([A-Za-z0-9_.-]\{1,\}\).*|\1|p' docker-compose.yml | head -1)
    [ -n "$project" ] || project=$(basename "$REPO_ROOT")
    docker volume inspect "${project}_postgres-data" >/dev/null 2>&1
}

MIGRATED=0
ensure_env() {
    key="$1"
    value="$2"
    if grep -qE "^${key}=.+" .env 2>/dev/null; then
        return 0
    fi
    if grep -qE "^${key}=$" .env 2>/dev/null; then
        sed -i.bak "/^${key}=$/d" .env
        rm -f .env.bak
    fi
    printf '%s=%s\n' "$key" "$value" >> .env
    echo "  + added $key"
    MIGRATED=1
}

echo "Checking LiteLLM environment..."
if [ ! -f .env ]; then
    MASTER_KEY="sk-$(openssl rand -hex 24)"
    SALT_KEY="$(openssl rand -hex 24)"
    UI_PASSWORD="$(openssl rand -hex 12)"
    if postgres_volume_exists; then
        DB_PASSWORD="litellm"
        echo "Existing postgres-data volume found; using its historical default password."
        echo "See README.md before rotating it."
    else
        DB_PASSWORD="$(openssl rand -hex 24)"
    fi

    sed \
      -e "s|^LITELLM_MASTER_KEY=.*|LITELLM_MASTER_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_SALT_KEY=.*|LITELLM_SALT_KEY=$SALT_KEY|" \
      -e "s|^UI_PASSWORD=.*|UI_PASSWORD=$UI_PASSWORD|" \
      -e "s|^LITELLM_WEBUI_KEY=.*|LITELLM_WEBUI_KEY=$MASTER_KEY|" \
      -e "s|^LITELLM_DB_PASSWORD=.*|LITELLM_DB_PASSWORD=$DB_PASSWORD|" \
      .env.example > .env
    chmod 600 .env
    echo ".env created with generated LiteLLM secrets."
else
    echo ".env exists; checking required LiteLLM values..."
    EXISTING_MASTER=$(sed -n 's|^LITELLM_MASTER_KEY=\(.\{1,\}\)$|\1|p' .env | head -1)
    [ -n "$EXISTING_MASTER" ] || EXISTING_MASTER="sk-$(openssl rand -hex 24)"

    ensure_env LITELLM_MASTER_KEY "$EXISTING_MASTER"
    ensure_env LITELLM_SALT_KEY "$(openssl rand -hex 24)"
    ensure_env UI_USERNAME "admin"
    ensure_env UI_PASSWORD "$(openssl rand -hex 12)"
    ensure_env LITELLM_WEBUI_KEY "$EXISTING_MASTER"
    ensure_env STORE_MODEL_IN_DB "True"
    ensure_env LITELLM_DB_PASSWORD "litellm"
    chmod 600 .env

    if [ "$MIGRATED" -eq 1 ]; then
        echo ".env updated with missing values (mode 600)."
    else
        echo ".env already complete (mode 600)."
    fi
fi

DB_PASSWORD=$(sed -n 's|^LITELLM_DB_PASSWORD=\(.\{1,\}\)$|\1|p' .env | head -1)
case "$DB_PASSWORD" in
    ""|*[!A-Za-z0-9._~-]*)
        echo "error: LITELLM_DB_PASSWORD must contain only URL-safe characters" >&2
        echo "error: generate one with: openssl rand -hex 24" >&2
        exit 1
        ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    chown 1000:1000 .env
    chown -R 1000:1000 var/run/litellm
fi

echo ""
echo "Configuring model placement..."
"$REPO_ROOT/scripts/apply-model-routing.sh" --no-restart "$@"

if [ "$(id -u)" -eq 0 ]; then
    chown -R 1000:1000 var/run/litellm
    [ -f var/lib/llama/model-routing.tsv ] && chown 1000:1000 var/lib/llama/model-routing.tsv
fi

echo ""
echo "LiteLLM stack setup complete."
echo "Next:"
echo "  1. Set COMPOSE_FILE=docker-compose.yml:docker-compose.litellm.yml in .env"
echo "  2. docker compose up --build -d"
echo "  3. Open https://localhost:11437/ui with UI_USERNAME / UI_PASSWORD"

#!/bin/sh
set -eu

# Apply GGUF add/remove: regenerate the LiteLLM model list, then recreate
# the stack so llama-server rescans var/lib/llama and LiteLLM reloads pins.
#
#   cp ~/new-model.gguf var/lib/llama/
#   ./reload-models.sh
#
# At most two standalone .gguf files. Generation runs first so a third
# GGUF fails before the stack is taken down. Volumes (Postgres, models,
# WebUI data) are kept.

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_ROOT"

echo "Generating LiteLLM model list..."
./litellm/gen-models.sh

echo "Stopping stack..."
docker compose down --remove-orphans

echo "Starting stack..."
docker compose up -d

echo ""
echo "Models applied. Pin map is in var/run/litellm/models.generated.yaml"
echo "  https://localhost:11437/v1/models"
echo "  https://localhost:11438/"
echo ""

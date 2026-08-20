#!/bin/sh
set -eu

# Apply a GGUF add/remove: regenerate the LiteLLM model list, then restart the
# services that only read the model store at startup.
#
#   cp ~/new-model.gguf var/lib/llama/
#   ./reload-models.sh
#
# If you enable the LiteLLM overlay with explicit -f flags rather than
# COMPOSE_FILE, pass the same flags here so this script acts on the same stack:
#
#   ./reload-models.sh -f docker-compose.yml -f docker-compose.litellm.yml
#
# Restart, not down/up: llama-server rescans var/lib/llama and LiteLLM rereads
# its generated include at startup, and both files are bind mounts whose
# contents are already current in the container. An earlier version ran
# `docker compose down --remove-orphans` followed by a bare `docker compose
# up -d`, which -- when the overlay was selected with -f rather than
# COMPOSE_FILE -- reaped litellm and postgres as orphans and then brought back
# only the base stack.

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$REPO_ROOT"

# Collect -f/--file arguments and forward them to every compose invocation, so
# the stack this script inspects is the stack the operator is running.
COMPOSE_FILES=""
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)
      [ $# -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 1; }
      COMPOSE_FILES="$COMPOSE_FILES -f $2"
      shift 2
      ;;
    -f=*|--file=*)
      COMPOSE_FILES="$COMPOSE_FILES -f ${1#*=}"
      shift
      ;;
    -h|--help)
      echo "usage: $0 [-f COMPOSE_FILE]..." >&2
      exit 0
      ;;
    *)
      echo "usage: $0 [-f COMPOSE_FILE]..." >&2
      exit 1
      ;;
  esac
done

# shellcheck disable=SC2086 # word splitting of COMPOSE_FILES is intended
dc() { docker compose $COMPOSE_FILES "$@"; }

SERVICES=$(dc config --services 2>/dev/null || true)
[ -n "$SERVICES" ] || { echo "error: 'docker compose config --services' returned nothing; check your compose files and .env" >&2; exit 1; }

has_service() { printf '%s\n' "$SERVICES" | grep -qx "$1"; }

LITELLM_ON=0
has_service litellm && LITELLM_ON=1

echo "Generating LiteLLM model list..."
if [ "$LITELLM_ON" -eq 1 ]; then
  # LiteLLM is in the active stack, so it will mount this file. A store the
  # generator cannot pin must stop here, before anything is restarted.
  ./litellm/gen-models.sh
else
  # The default stack never reads models.generated.yaml -- the routers scan
  # /models themselves -- so a store the generator cannot pin is not a reason
  # to refuse the reload.
  if ! ./litellm/gen-models.sh; then
    echo ""
    echo "WARNING: model list not regenerated (see above). LiteLLM is not in the"
    echo "         active stack, so this does not affect the reload."
  fi
fi

# The routers discover models in /models at startup only.
ROUTERS=""
for r in llama-1 llama-2; do
  has_service "$r" && ROUTERS="$ROUTERS $r"
done
[ -n "$ROUTERS" ] || { echo "error: no llama-1/llama-2 service in the active stack" >&2; exit 1; }

echo "Restarting routers:$ROUTERS"
# shellcheck disable=SC2086
dc restart $ROUTERS

if [ "$LITELLM_ON" -eq 1 ]; then
  echo "Restarting LiteLLM..."
  dc restart litellm
fi

echo ""
echo "Models applied. Pin map is in var/run/litellm/models.generated.yaml"
if [ "$LITELLM_ON" -eq 1 ]; then
  echo "  https://localhost:11437/v1/models   (needs an Authorization: Bearer key)"
else
  echo "  https://localhost:11437/v1/models"
fi
echo "  https://localhost:11438/"
echo ""

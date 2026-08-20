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
#
# POSIX rotation rather than a string: consume each argument from the front of
# "$@" and append the normalised pair to the back, counting down the original
# argument count so the loop terminates. A space-delimited scalar expanded
# unquoted would split a compose path containing whitespace and silently point
# Compose at the wrong file; this script is /bin/sh, so a bash array is not an
# option. After the loop "$@" holds only the normalised -f pairs.
remaining=$#
while [ "$remaining" -gt 0 ]; do
  case "$1" in
    -f|--file)
      [ "$remaining" -ge 2 ] || { echo "error: $1 needs a value" >&2; exit 1; }
      set -- "$@" "-f" "$2"
      shift 2
      remaining=$((remaining - 2))
      ;;
    -f=*|--file=*)
      set -- "$@" "-f" "${1#*=}"
      shift
      remaining=$((remaining - 1))
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

SERVICES=$(docker compose "$@" config --services 2>/dev/null || true)
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
    echo "WARNING: model list not regenerated (see above). The previous pin map"
    echo "         was removed. LiteLLM is not in the active stack, so this"
    echo "         does not affect the reload."
  fi
fi

# The routers discover models in /models at startup only.
ROUTERS=""
for r in llama-1 llama-2; do
  has_service "$r" && ROUTERS="$ROUTERS $r"
done
[ -n "$ROUTERS" ] || { echo "error: no llama-1/llama-2 service in the active stack" >&2; exit 1; }

echo "Restarting routers:$ROUTERS"
# $ROUTERS is a space-separated list of compose service names, which cannot
# contain whitespace, so splitting it here is intended.
# shellcheck disable=SC2086
docker compose "$@" restart $ROUTERS

if [ "$LITELLM_ON" -eq 1 ]; then
  echo "Restarting LiteLLM..."
  docker compose "$@" restart litellm
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

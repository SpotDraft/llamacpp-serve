#!/bin/sh
set -eu

# Generate the LiteLLM model_list from the GGUFs in the shared model store.
#
# This Spark stack runs exactly two llama-server instances, each with
# LLAMA_ARG_MODELS_MAX=1. LiteLLM must therefore pin each GGUF to one
# api_base -- otherwise a hot model is load-balanced onto both servers.
#
# At most 2 standalone GGUFs are allowed (one per instance). Assignment is
# sorted filename order: 1st -> llama-1, 2nd -> llama-2. That is unique;
# hashing names modulo 2 can put both files on the same router.
#
# llama-server still scans var/lib/llama at startup; this file is what
# /v1/models and the Open WebUI dropdown see, and what attaches per-model
# limits. A wildcard `model_name: "*"` would make /v1/models return `*`.
#
# Usage:
#   ./litellm/gen-models.sh            # regenerate the model list
#   ./reload-models.sh                 # regenerate, then compose down/up
#   ./litellm/gen-models.sh --reload   # regenerate, then restart routers
#                                      # (and LiteLLM if that compose file is on)

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

MODELS_DIR="${MODELS_DIR:-$REPO_ROOT/var/lib/llama}"
OUT="${OUT:-$REPO_ROOT/var/run/litellm/models.generated.yaml}"

# A failed pin must not leave the previous map in place. setup.sh treats
# generator failure as non-fatal for the default stack, and the overlay
# bind-mounts this file with create_host_path: false -- deleting it makes
# `docker compose up` fail loudly instead of advertising removed models or
# routing to a stale api_base. Only the "this store cannot be pinned" exits
# discard it; a missing MODELS_DIR or a usage error must not.
die() {
  rm -f "${TMP:-}" "${NAMES:-}"
  exit 1
}

discard_pin_map() {
  if [ -f "$OUT" ]; then
    echo "error: removing stale pin map: $OUT" >&2
    rm -f "$OUT"
  fi
}

# Must match the service names in docker-compose.yml and their container port.
ROUTERS="${ROUTERS:-llama-1 llama-2}"
ROUTER_PORT="${ROUTER_PORT:-8080}"

# Cap in-flight requests per (model, router). Keep this equal to
# LLAMA_ARG_PARALLEL in docker-compose.yml: a loaded model has exactly that
# many slots, so anything beyond it only queues inside llama-server where
# LiteLLM can neither see it nor account for it.
MAX_PARALLEL="${MAX_PARALLEL:-2}"

RELOAD=0
case "${1:-}" in
  --reload) RELOAD=1 ;;
  '') ;;
  *) echo "usage: $0 [--reload]" >&2; exit 1 ;;
esac

[ -d "$MODELS_DIR" ] || { echo "error: model store not found: $MODELS_DIR (run ./setup.sh)" >&2; die; }

mkdir -p "$(dirname "$OUT")"
TMP="$OUT.tmp"
NAMES="$OUT.names.tmp"

n_routers=0
for _r in $ROUTERS; do
  n_routers=$((n_routers + 1))
done
[ "$n_routers" -gt 0 ] || { echo "error: ROUTERS is empty" >&2; die; }

# Sharded GGUFs (foo-00001-of-00003.gguf) are not standalone models: neither
# llama-server's --models-dir scan nor this script can serve them directly, so
# skip every shard rather than emit one bogus model per file. Use
# LLAMA_ARG_MODELS_PRESET for those (see README).
is_shard() {
  case "$1" in
    *-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# The basename is interpolated straight into double-quoted YAML scalars below
# and becomes the public model ID. A filename containing a quote, backslash,
# newline or `#` would emit a broken models.generated.yaml and LiteLLM would
# refuse to start with a parse error pointing at a generated file nobody
# edited. Reject up front with the offending name instead of escaping: a
# model ID is a user-facing API string, so it should be boring anyway.
#
# Allowed: letters, digits, dot, underscore, plus, hyphen.
is_safe_name() {
  case "$1" in
    '' | *[!A-Za-z0-9._+-]*) return 1 ;;
    # A leading hyphen would be read as a flag by anything consuming the ID.
    -*) return 1 ;;
    *) return 0 ;;
  esac
}

# Collect model IDs first so we can emit an explicit empty list when there are
# none -- a bare `model_list:` key parses as null and LiteLLM fails to start.
: > "$NAMES"
count=0
bad=0
for f in "$MODELS_DIR"/*.gguf; do
  [ -f "$f" ] || continue
  base=$(basename "$f" .gguf)
  if is_shard "$base"; then
    echo "skip (sharded GGUF, needs LLAMA_ARG_MODELS_PRESET): $(basename "$f")" >&2
    continue
  fi
  if ! is_safe_name "$base"; then
    echo "error: unsupported GGUF filename: $(basename "$f")" >&2
    bad=$((bad + 1))
    continue
  fi
  printf '%s\n' "$base" >> "$NAMES"
  count=$((count + 1))
done

if [ "$bad" -gt 0 ]; then
  echo "error: $bad GGUF filename(s) contain characters that cannot be a model ID" >&2
  echo "error: rename them to use only letters, digits, '.', '_', '+' and '-'" >&2
  echo "error: (the filename minus .gguf is the model ID clients send)" >&2
  discard_pin_map
  die
fi

if [ "$count" -gt "$n_routers" ]; then
  echo "error: $count GGUFs in $MODELS_DIR; this stack runs at most $n_routers models (one per llama-server)" >&2
  echo "error: keep 1 or 2 standalone .gguf files (plus optional shards, which are skipped)" >&2
  discard_pin_map
  die
fi

# Sorted unique pin: line N of the sorted names -> Nth router.
router_at() {
  idx="$1"
  i=0
  for r in $ROUTERS; do
    if [ "$i" -eq "$idx" ]; then
      printf '%s\n' "$r"
      return 0
    fi
    i=$((i + 1))
  done
}

emit_deployment() {
  base="$1"
  router="$2"
  echo "  - model_name: \"$base\""
  echo "    litellm_params:"
  # The openai/ prefix tells LiteLLM to speak the OpenAI wire protocol;
  # the model name after it is what llama-server receives and matches
  # against its discovered GGUFs.
  echo "      model: \"openai/$base\""
  echo "      api_base: \"http://$router:$ROUTER_PORT/v1\""
  # llama-server has no auth of its own, but the OpenAI SDK inside
  # LiteLLM requires a non-empty key.
  echo "      api_key: \"none\""
  echo "      max_parallel_requests: $MAX_PARALLEL"
  echo "    model_info:"
  # Stable per-deployment id, so spend logs and the Admin UI show which
  # router actually served a request.
  echo "      id: \"$base@$router\""
  # Local inference is free. Declaring every cost field as zero keeps
  # spend logs at 0.00 and silences LiteLLM's "not in built-in cost map"
  # startup warning, which it emits once per deployment.
  echo "      input_cost_per_token: 0"
  echo "      output_cost_per_token: 0"
  echo "      cache_creation_input_token_cost: 0"
  echo "      cache_read_input_token_cost: 0"
}

{
  echo "# Generated by litellm/gen-models.sh -- DO NOT EDIT."
  echo "# Source: $MODELS_DIR"
  echo "# Pin: 1 GGUF -> 1 router (sorted filename order). Max $n_routers models."
  echo "# Regenerate with: ./reload-models.sh"
  if [ "$count" -eq 0 ]; then
    echo "model_list: []"
  else
    echo "model_list:"
    idx=0
    # sort -u so a duplicate basename cannot emit two deployments.
    sort -u "$NAMES" | while IFS= read -r base; do
      [ -n "$base" ] || continue
      router=$(router_at "$idx")
      emit_deployment "$base" "$router"
      idx=$((idx + 1))
    done
  fi
} > "$TMP"

mv "$TMP" "$OUT"
echo "wrote $OUT ($count model(s) pinned 1:1 across $n_routers router(s))"
if [ "$count" -gt 0 ]; then
  idx=0
  sort -u "$NAMES" | while IFS= read -r base; do
    [ -n "$base" ] || continue
    echo "  $base -> $(router_at "$idx")"
    idx=$((idx + 1))
  done
fi
rm -f "$NAMES"

if [ "$count" -eq 0 ]; then
  echo "warning: no .gguf files in $MODELS_DIR -- LiteLLM will start with an empty model list" >&2
fi

if [ "$RELOAD" -eq 1 ]; then
  echo "restarting routers: $ROUTERS"
  # The routers rescan var/lib/llama only at startup, so they always restart.
  # LiteLLM is optional. `docker compose config --services` sees it when
  # COMPOSE_FILE includes docker-compose.litellm.yml (or you passed -f).
  (
    cd "$REPO_ROOT"
    # shellcheck disable=SC2086
    docker compose restart $ROUTERS
    if docker compose config --services 2>/dev/null | grep -qx litellm; then
      echo "restarting LiteLLM..."
      docker compose restart litellm
    fi
  )
fi

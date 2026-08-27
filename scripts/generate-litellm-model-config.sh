#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODELS_DIR="${MODELS_DIR:-$REPO_ROOT/var/lib/llama}"
ROUTING_FILE="${ROUTING_FILE:-$MODELS_DIR/model-routing.tsv}"
ROUTING_LABEL="${ROUTING_LABEL:-$ROUTING_FILE}"
OUT="${OUT:-$REPO_ROOT/var/run/litellm/models.generated.yaml}"
ROUTER_PORT="${ROUTER_PORT:-8080}"
# Default the per-deployment cap to the router's own slot count so the two
# cannot drift. This script is not run by docker compose, so .env is read
# directly; an explicit MAX_PARALLEL= still wins.
if [ -z "${MAX_PARALLEL:-}" ] && [ -z "${LLAMA_N_PARALLEL:-}" ] && [ -f "$REPO_ROOT/.env" ]; then
    LLAMA_N_PARALLEL=$(sed -n 's|^LLAMA_N_PARALLEL=\(.\{1,\}\)$|\1|p' "$REPO_ROOT/.env" | head -1)
fi
MAX_PARALLEL="${MAX_PARALLEL:-${LLAMA_N_PARALLEL:-2}}"
MAX_MODELS="${MAX_MODELS:-4}"
MAX_PER_ROUTER="${MAX_PER_ROUTER:-2}"

case "${1:-}" in
    "") ;;
    -h|--help)
        echo "usage: $0"
        echo "Environment: MODELS_DIR ROUTING_FILE OUT MAX_PARALLEL LLAMA_N_PARALLEL"
        exit 0
        ;;
    *)
        echo "usage: $0" >&2
        exit 1
        ;;
esac

[ -d "$MODELS_DIR" ] || {
    echo "error: model store not found: $MODELS_DIR" >&2
    echo "error: run scripts/setup-base-stack.sh first" >&2
    exit 1
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-model-config.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
MODELS_RAW="$TMP_DIR/models.raw"
MODELS="$TMP_DIR/models"
ROUTES="$TMP_DIR/routes"
SORTED_ROUTES="$TMP_DIR/routes.sorted"
GENERATED="$TMP_DIR/models.generated.yaml"
TAB=$(printf '\t')

: > "$MODELS_RAW"

is_shard() {
    case "$1" in
        *-[0-9][0-9][0-9][0-9][0-9]-of-[0-9][0-9][0-9][0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

is_safe_name() {
    case "$1" in
        ""|*[!A-Za-z0-9._+-]*|-*) return 1 ;;
        *) return 0 ;;
    esac
}

bad=0
for file in "$MODELS_DIR"/*.gguf; do
    [ -f "$file" ] || continue
    model=$(basename "$file" .gguf)
    if is_shard "$model"; then
        echo "skip (sharded GGUF needs LLAMA_ARG_MODELS_PRESET): $(basename "$file")" >&2
        continue
    fi
    if ! is_safe_name "$model"; then
        echo "error: unsupported GGUF filename: $(basename "$file")" >&2
        bad=$((bad + 1))
        continue
    fi
    printf '%s\n' "$model" >> "$MODELS_RAW"
done

[ "$bad" -eq 0 ] || {
    echo "error: model IDs may contain only letters, digits, '.', '_', '+' and '-'" >&2
    exit 1
}

sort -u "$MODELS_RAW" > "$MODELS"
model_count=$(wc -l < "$MODELS" | tr -d ' ')
[ "$model_count" -le "$MAX_MODELS" ] || {
    echo "error: found $model_count standalone GGUFs; LiteLLM supports at most $MAX_MODELS" >&2
    echo "error: each of llama-1 and llama-2 can own at most $MAX_PER_ROUTER models" >&2
    exit 1
}

if [ -f "$ROUTING_FILE" ]; then
    cp "$ROUTING_FILE" "$ROUTES"
else
    : > "$ROUTES"
    index=0
    while IFS= read -r model; do
        [ -n "$model" ] || continue
        if [ $((index % 2)) -eq 0 ]; then
            router=llama-1
        else
            router=llama-2
        fi
        printf '%s\t%s\n' "$model" "$router" >> "$ROUTES"
        index=$((index + 1))
    done < "$MODELS"
fi

if ! awk -F '\t' 'NF != 2 || $1 == "" || $2 == "" { exit 1 }' "$ROUTES"; then
    echo "error: malformed routing file: $ROUTING_FILE" >&2
    echo "error: expected one model<TAB>llama-N assignment per line" >&2
    exit 1
fi

route_count=$(wc -l < "$ROUTES" | tr -d ' ')
[ "$route_count" -eq "$model_count" ] || {
    echo "error: routing has $route_count assignment(s), but disk has $model_count model(s)" >&2
    echo "error: rerun scripts/apply-model-routing.sh to update placement" >&2
    exit 1
}

while IFS="$TAB" read -r model router; do
    case "$router" in
        llama-1|llama-2) ;;
        *)
            echo "error: unsupported instance '$router' for model '$model' (use llama-1 or llama-2)" >&2
            exit 1
            ;;
    esac

    grep -Fxq "$model" "$MODELS" || {
        echo "error: routing references model not present on disk: $model" >&2
        exit 1
    }

    occurrences=$(awk -F '\t' -v wanted="$model" '$1 == wanted { n++ } END { print n + 0 }' "$ROUTES")
    [ "$occurrences" -eq 1 ] || {
        echo "error: model '$model' is assigned $occurrences times; expected exactly once" >&2
        exit 1
    }
done < "$ROUTES"

while IFS= read -r model; do
    [ -n "$model" ] || continue
    occurrences=$(awk -F '\t' -v wanted="$model" '$1 == wanted { n++ } END { print n + 0 }' "$ROUTES")
    [ "$occurrences" -eq 1 ] || {
        echo "error: model '$model' has no unique routing assignment" >&2
        exit 1
    }
done < "$MODELS"

for router in llama-1 llama-2; do
    assigned=$(awk -F '\t' -v wanted="$router" '$2 == wanted { n++ } END { print n + 0 }' "$ROUTES")
    [ "$assigned" -le "$MAX_PER_ROUTER" ] || {
        echo "error: $router has $assigned models; maximum is $MAX_PER_ROUTER" >&2
        exit 1
    }
done

sort -t "$TAB" -k1,1 "$ROUTES" > "$SORTED_ROUTES"

emit_deployment() {
    model="$1"
    router="$2"
    echo "  - model_name: \"$model\""
    echo "    litellm_params:"
    echo "      model: \"openai/$model\""
    echo "      api_base: \"http://$router:$ROUTER_PORT/v1\""
    echo "      api_key: \"none\""
    echo "      max_parallel_requests: $MAX_PARALLEL"
    echo "      use_chat_completions_api: true"
    echo "      additional_drop_params: [\"previous_response_id\"]"
    echo "    model_info:"
    echo "      id: \"$model@$router\""
    echo "      input_cost_per_token: 0"
    echo "      output_cost_per_token: 0"
    echo "      cache_creation_input_token_cost: 0"
    echo "      cache_read_input_token_cost: 0"
}

{
    echo "# Generated by scripts/generate-litellm-model-config.sh -- DO NOT EDIT."
    echo "# Source: $MODELS_DIR"
    echo "# Routing: $ROUTING_LABEL"
    echo "# Capacity: up to $MAX_MODELS models, $MAX_PER_ROUTER per router."
    echo "# Reconfigure with: scripts/apply-model-routing.sh"
    if [ "$model_count" -eq 0 ]; then
        echo "model_list: []"
    else
        echo "model_list:"
        while IFS="$TAB" read -r model router; do
            emit_deployment "$model" "$router"
        done < "$SORTED_ROUTES"
    fi
} > "$GENERATED"

mkdir -p "$(dirname "$OUT")"
mv "$GENERATED" "$OUT"

echo "wrote $OUT ($model_count model(s))"
while IFS="$TAB" read -r model router; do
    [ -n "$model" ] || continue
    echo "  $model -> $router"
done < "$SORTED_ROUTES"

if [ "$model_count" -eq 0 ]; then
    echo "warning: no standalone .gguf files in $MODELS_DIR" >&2
fi

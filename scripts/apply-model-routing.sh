#!/bin/sh
set -eu

REPO_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$REPO_ROOT"

MODELS_DIR="${MODELS_DIR:-$REPO_ROOT/var/lib/llama}"
ROUTING_FILE="${ROUTING_FILE:-$MODELS_DIR/model-routing.tsv}"
OUT="${OUT:-$REPO_ROOT/var/run/litellm/models.generated.yaml}"
GENERATOR="$REPO_ROOT/scripts/generate-litellm-model-config.sh"

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/llamacpp-routing.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
ASSIGNMENTS="$TMP_DIR/assignments"
COMPOSE_FILES="$TMP_DIR/compose-files"
MODELS_RAW="$TMP_DIR/models.raw"
MODELS="$TMP_DIR/models"
MODEL_SIZES="$TMP_DIR/model-sizes"
CANDIDATE_ROUTING="$TMP_DIR/model-routing.tsv"
CANDIDATE_YAML="$TMP_DIR/models.generated.yaml"
TAB=$(printf '\t')

: > "$ASSIGNMENTS"
: > "$COMPOSE_FILES"
: > "$MODELS_RAW"
: > "$MODEL_SIZES"

AUTO=0
DRY_RUN=0
NO_RESTART=0
YES=0
INTERACTIVE=0
if [ -t 0 ]; then
    INTERACTIVE=1
    exec 3<&0
fi

usage() {
    cat <<EOF
usage: $0 [OPTIONS]

Interactively assign each standalone GGUF to llama-1 or llama-2.

Options:
  --assign MODEL=INSTANCE  Noninteractive assignment; repeat for every model
                           (INSTANCE may be 1, 2, llama-1, or llama-2)
  --auto                   Use filename-sorted round-robin placement
  --dry-run                Validate and print without writing or restarting
  --no-restart             Write routing/config but do not restart services
  --yes                    Skip the final interactive confirmation
  -f, --file FILE          Forward a Compose file to restart commands
  -h, --help               Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --assign)
            [ "$#" -ge 2 ] || { echo "error: --assign needs MODEL=INSTANCE" >&2; exit 1; }
            printf '%s\n' "$2" >> "$ASSIGNMENTS"
            shift 2
            ;;
        --assign=*)
            printf '%s\n' "${1#*=}" >> "$ASSIGNMENTS"
            shift
            ;;
        --auto)
            AUTO=1
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --no-restart)
            NO_RESTART=1
            shift
            ;;
        --yes)
            YES=1
            shift
            ;;
        -f|--file)
            [ "$#" -ge 2 ] || { echo "error: $1 needs a Compose file" >&2; exit 1; }
            printf '%s\n' "$2" >> "$COMPOSE_FILES"
            shift 2
            ;;
        -f=*|--file=*)
            printf '%s\n' "${1#*=}" >> "$COMPOSE_FILES"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

assignment_count=$(wc -l < "$ASSIGNMENTS" | tr -d ' ')
if [ "$AUTO" -eq 1 ] && [ "$assignment_count" -gt 0 ]; then
    echo "error: --auto and --assign are mutually exclusive" >&2
    exit 1
fi

[ -d "$MODELS_DIR" ] || {
    echo "error: model store not found: $MODELS_DIR" >&2
    echo "error: run scripts/setup-base-stack.sh first" >&2
    exit 1
}

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

for file in "$MODELS_DIR"/*.gguf; do
    [ -f "$file" ] || continue
    model=$(basename "$file" .gguf)
    if is_shard "$model"; then
        echo "skip (sharded GGUF needs LLAMA_ARG_MODELS_PRESET): $(basename "$file")" >&2
        continue
    fi
    is_safe_name "$model" || {
        echo "error: unsupported GGUF filename: $(basename "$file")" >&2
        exit 1
    }
    bytes=$(wc -c < "$file" | tr -d ' ')
    printf '%s\n' "$model" >> "$MODELS_RAW"
    printf '%s\t%s\n' "$model" "$bytes" >> "$MODEL_SIZES"
done

sort -u "$MODELS_RAW" > "$MODELS"
model_count=$(wc -l < "$MODELS" | tr -d ' ')
[ "$model_count" -le 4 ] || {
    echo "error: found $model_count standalone GGUFs; at most four can be pinned" >&2
    exit 1
}

human_size() {
    awk -v bytes="$1" 'BEGIN { printf "%.1f GiB", bytes / 1073741824 }'
}

size_for() {
    awk -F '\t' -v wanted="$1" '$1 == wanted { print $2; exit }' "$MODEL_SIZES"
}

normalise_router() {
    case "$1" in
        1|llama-1) echo "llama-1" ;;
        2|llama-2) echo "llama-2" ;;
        *) return 1 ;;
    esac
}

auto_routing() {
    : > "$CANDIDATE_ROUTING"
    index=0
    while IFS= read -r model; do
        [ -n "$model" ] || continue
        if [ $((index % 2)) -eq 0 ]; then
            router=llama-1
        else
            router=llama-2
        fi
        printf '%s\t%s\n' "$model" "$router" >> "$CANDIDATE_ROUTING"
        index=$((index + 1))
    done < "$MODELS"
}

if [ "$AUTO" -eq 1 ]; then
    auto_routing
elif [ "$assignment_count" -gt 0 ]; then
    : > "$CANDIDATE_ROUTING"
    while IFS= read -r assignment; do
        case "$assignment" in
            *=*)
                model=${assignment%%=*}
                requested=${assignment#*=}
                ;;
            *)
                echo "error: invalid assignment '$assignment' (expected MODEL=INSTANCE)" >&2
                exit 1
                ;;
        esac
        [ -n "$model" ] && [ -n "$requested" ] || {
            echo "error: invalid assignment '$assignment'" >&2
            exit 1
        }
        router=$(normalise_router "$requested") || {
            echo "error: invalid instance '$requested' for '$model' (use 1 or 2)" >&2
            exit 1
        }
        printf '%s\t%s\n' "$model" "$router" >> "$CANDIDATE_ROUTING"
    done < "$ASSIGNMENTS"
elif [ "$INTERACTIVE" -eq 1 ]; then
    echo "Found $model_count standalone model(s):"
    number=1
    while IFS= read -r model; do
        [ -n "$model" ] || continue
        bytes=$(size_for "$model")
        echo "  $number. $model ($(human_size "$bytes"))"
        number=$((number + 1))
    done < "$MODELS"
    echo ""

    : > "$CANDIDATE_ROUTING"
    count_1=0
    count_2=0
    while IFS= read -r model; do
        [ -n "$model" ] || continue
        current=""
        if [ -f "$ROUTING_FILE" ]; then
            current=$(awk -F '\t' -v wanted="$model" \
              '$1 == wanted && ($2 == "llama-1" || $2 == "llama-2") { print $2; exit }' \
              "$ROUTING_FILE")
        fi

        while :; do
            if [ -n "$current" ]; then
                default=${current#llama-}
                printf 'Instance for %s [1/2, current %s]: ' "$model" "$default"
            else
                printf 'Instance for %s [1/2]: ' "$model"
            fi
            IFS= read -r requested <&3 || {
                echo ""
                echo "error: input ended before routing was complete" >&2
                exit 1
            }
            requested=$(printf '%s' "$requested" | tr -d '\r')
            [ -n "$requested" ] || requested=${current#llama-}
            router=$(normalise_router "$requested") || {
                echo "Please enter 1 or 2."
                continue
            }

            if [ "$router" = "llama-1" ] && [ "$count_1" -ge 2 ]; then
                echo "llama-1 is full (2/2); choose instance 2."
                continue
            fi
            if [ "$router" = "llama-2" ] && [ "$count_2" -ge 2 ]; then
                echo "llama-2 is full (2/2); choose instance 1."
                continue
            fi
            break
        done

        printf '%s\t%s\n' "$model" "$router" >> "$CANDIDATE_ROUTING"
        if [ "$router" = "llama-1" ]; then
            count_1=$((count_1 + 1))
        else
            count_2=$((count_2 + 1))
        fi
        echo "  capacity: llama-1 $count_1/2, llama-2 $count_2/2"
    done < "$MODELS"
else
    if [ "$model_count" -eq 0 ]; then
        : > "$CANDIDATE_ROUTING"
    elif [ -f "$ROUTING_FILE" ]; then
        cp "$ROUTING_FILE" "$CANDIDATE_ROUTING"
    else
        echo "error: no terminal and no persisted routing exists" >&2
        echo "error: use --assign for every model or --auto" >&2
        exit 1
    fi
fi

if [ "$AUTO" -eq 1 ]; then
    ROUTING_LABEL_VALUE="automatic filename-sorted round-robin"
else
    ROUTING_LABEL_VALUE="$MODELS_DIR/model-routing.tsv"
fi

ROUTING_FILE="$CANDIDATE_ROUTING" \
ROUTING_LABEL="$ROUTING_LABEL_VALUE" \
OUT="$CANDIDATE_YAML" \
"$GENERATOR"

echo ""
echo "Proposed model placement:"
if [ "$model_count" -eq 0 ]; then
    echo "  (no standalone GGUFs)"
else
    sort -t "$TAB" -k2,2 -k1,1 "$CANDIDATE_ROUTING" | while IFS="$TAB" read -r model router; do
        bytes=$(size_for "$model")
        echo "  $router <- $model ($(human_size "$bytes"))"
    done
fi

if [ "$DRY_RUN" -eq 1 ]; then
    echo ""
    echo "Dry run complete; nothing was written or restarted."
    exit 0
fi

if [ "$YES" -ne 1 ] && [ "$INTERACTIVE" -eq 1 ]; then
    if [ "$NO_RESTART" -eq 1 ]; then
        printf 'Apply this routing? [y/N]: '
    else
        printf 'Apply this routing and restart the active stack? [y/N]: '
    fi
    IFS= read -r answer <&3 || answer=""
    answer=$(printf '%s' "$answer" | tr -d '\r')
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            echo "Cancelled; nothing was written or restarted."
            exit 0
            ;;
    esac
fi

set --
while IFS= read -r compose_file; do
    [ -n "$compose_file" ] || continue
    set -- "$@" -f "$compose_file"
done < "$COMPOSE_FILES"

SERVICES=""
if [ "$NO_RESTART" -ne 1 ]; then
    SERVICES=$(docker compose "$@" config --services 2>/dev/null || true)
    [ -n "$SERVICES" ] || {
        echo "error: Compose returned no services; check Compose files and .env" >&2
        exit 1
    }
fi

mkdir -p "$(dirname "$ROUTING_FILE")" "$(dirname "$OUT")"
if [ "$AUTO" -eq 1 ]; then
    rm -f "$ROUTING_FILE"
else
    route_tmp="$ROUTING_FILE.tmp.$$"
    cp "$CANDIDATE_ROUTING" "$route_tmp"
    mv "$route_tmp" "$ROUTING_FILE"
fi
yaml_tmp="$OUT.tmp.$$"
cp "$CANDIDATE_YAML" "$yaml_tmp"
mv "$yaml_tmp" "$OUT"

echo ""
echo "Routing saved; LiteLLM config written to $OUT."

if [ "$NO_RESTART" -eq 1 ]; then
    echo "Services were not restarted."
    exit 0
fi

ROUTERS=""
for router in llama-1 llama-2; do
    if printf '%s\n' "$SERVICES" | grep -qx "$router"; then
        ROUTERS="$ROUTERS $router"
    fi
done
[ -n "$ROUTERS" ] || {
    echo "error: active Compose stack has no llama routers" >&2
    exit 1
}

echo "Restarting routers:$ROUTERS"
# Router service names cannot contain whitespace; intentional word splitting.
# shellcheck disable=SC2086
docker compose "$@" restart $ROUTERS

if printf '%s\n' "$SERVICES" | grep -qx litellm; then
    echo "Restarting LiteLLM..."
    docker compose "$@" restart litellm
fi

echo ""
echo "Models applied."
echo "  API: https://localhost:11437/v1/models"
echo "  UI:  https://localhost:11438/"

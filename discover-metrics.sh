#!/usr/bin/env bash
set -u

DUMP_DIR="${DUMP_DIR:-metrics_dump}"
CONTEXT=""
NAMESPACE=""
SELECTOR=""
NAME=""
NAME_CONTAINS=""

usage() {
    cat <<'EOF'
Usage: discover-metrics.sh [OPTIONS]

Discover running Kubernetes pods exposing a port whose name contains
"metric" or "prom", port-forward each matching port, and save Prometheus
HELP and TYPE lines under metrics_dump/.

Options:
  -c, --context NAME       Kubernetes context to use
  -n, --namespace NAME     Limit discovery to a namespace
  -l, --selector SELECTOR  Kubernetes label selector
      --name NAME          Match this exact pod name
      --name-contains TEXT Match pods whose names contain TEXT
  -o, --output DIR         Output directory (default: metrics_dump)
  -h, --help               Show this help
EOF
}

error() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || error "required command not found: $1"
}

sanitize_filename() {
    printf '%s' "$1" | tr '/[:space:]' '__' | tr -cd '[:alnum:]_.-'
}

while (($# > 0)); do
    case "$1" in
        -c|--context)
            (($# >= 2)) || error "$1 requires a value"
            CONTEXT=$2
            shift 2
            ;;
        -n|--namespace)
            (($# >= 2)) || error "$1 requires a value"
            NAMESPACE=$2
            shift 2
            ;;
        -l|--selector)
            (($# >= 2)) || error "$1 requires a value"
            SELECTOR=$2
            shift 2
            ;;
        --name)
            (($# >= 2)) || error "$1 requires a value"
            NAME=$2
            shift 2
            ;;
        --name-contains)
            (($# >= 2)) || error "$1 requires a value"
            NAME_CONTAINS=$2
            shift 2
            ;;
        -o|--output)
            (($# >= 2)) || error "$1 requires a value"
            DUMP_DIR=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            error "unknown option: $1 (use --help for usage)"
            ;;
    esac
done

require_command kubectl
require_command curl
require_command awk
require_command grep
require_command mktemp

mkdir -p "$DUMP_DIR" || error "unable to create output directory: $DUMP_DIR"

KUBECTL_ARGS=()
if [[ -n "$CONTEXT" ]]; then
    KUBECTL_ARGS+=(--context "$CONTEXT")
fi

POD_ARGS=(get pods)
if [[ -n "$NAMESPACE" ]]; then
    POD_ARGS+=(-n "$NAMESPACE")
else
    POD_ARGS+=(-A)
fi
if [[ -n "$SELECTOR" ]]; then
    POD_ARGS+=(--selector "$SELECTOR")
fi
FIELD_SELECTOR="status.phase=Running"
if [[ -n "$NAME" ]]; then
    FIELD_SELECTOR+=",metadata.name=$NAME"
fi
POD_ARGS+=(--field-selector="$FIELD_SELECTOR" -o=custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name --no-headers)

PODS=$(kubectl "${KUBECTL_ARGS[@]}" "${POD_ARGS[@]}") || error "unable to list running pods"
if [[ -z "$PODS" ]]; then
    printf 'No running pods found matching the criteria.\n'
    exit 0
fi

printf 'Starting Kubernetes metrics discovery...\n'
printf 'Results will be saved to: %s/\n' "$DUMP_DIR"
printf '%s\n' '------------------------------------------------------------'

FOUND_METRICS=0
MATCHED_PODS=0
TEMP_DIR=$(mktemp -d) || error "unable to create temporary directory"
cleanup() {
    if [[ -n "${PF_PID:-}" ]]; then
        kill "$PF_PID" 2>/dev/null || true
        wait "$PF_PID" 2>/dev/null || true
    fi
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

while read -r POD_NAMESPACE POD; do
    [[ -n "$POD_NAMESPACE" && -n "$POD" ]] || continue
    if [[ -n "$NAME_CONTAINS" && "$POD" != *"$NAME_CONTAINS"* ]]; then
        continue
    fi
    MATCHED_PODS=1

    CONTAINERS_PORTS=$(kubectl "${KUBECTL_ARGS[@]}" get pod "$POD" -n "$POD_NAMESPACE" \
        -o=jsonpath='{range .spec.containers[*]}{.name}{"|"}{range .ports[*]}{.name}{":"}{.containerPort}{" "}{end}{"\n"}{end}') ||
        printf 'Warning: unable to inspect %s/%s; skipping.\n' "$POD_NAMESPACE" "$POD" >&2

    while IFS= read -r LINE; do
        [[ "$LINE" == *"|"*":"* ]] || continue

        CONTAINER_NAME=${LINE%%|*}
        PORTS_STRING=${LINE#*|}
        for PORT_INFO in $PORTS_STRING; do
            PORT_NAME=${PORT_INFO%%:*}
            PORT_NUM=${PORT_INFO#*:}
            [[ "$PORT_NAME" == *metric* || "$PORT_NAME" == *prom* ]] || continue
            [[ "$PORT_NUM" =~ ^[0-9]+$ ]] || continue

            FOUND_METRICS=1
            printf '\n%s/%s - %s (%s)\n' "$POD_NAMESPACE" "$POD" "$PORT_NUM" "$PORT_NAME"

            LOCAL_PORT=0
            for _ in {1..10}; do
                CANDIDATE=$((10000 + RANDOM % 10000))
                if ! (echo >/dev/tcp/127.0.0.1/"$CANDIDATE") 2>/dev/null; then
                    LOCAL_PORT=$CANDIDATE
                    break
                fi
            done
            ((LOCAL_PORT > 0)) || {
                printf 'Warning: unable to allocate a local port; skipping.\n' >&2
                continue
            }

            PF_LOG="$TEMP_DIR/port-forward.log"
            kubectl "${KUBECTL_ARGS[@]}" port-forward -n "$POD_NAMESPACE" \
                "pod/$POD" "$LOCAL_PORT:$PORT_NUM" >"$PF_LOG" 2>&1 &
            PF_PID=$!

            READY=0
            for _ in {1..20}; do
                if curl -sS -m 1 "http://127.0.0.1:$LOCAL_PORT/metrics" >/dev/null 2>&1 ||
                    curl -k -sS -m 1 "https://127.0.0.1:$LOCAL_PORT/metrics" >/dev/null 2>&1; then
                    READY=1
                    break
                fi
                sleep 0.25
            done

            OUTPUT_FILE="$DUMP_DIR/$(sanitize_filename "$POD_NAMESPACE")_$(sanitize_filename "$CONTAINER_NAME")_$(sanitize_filename "$PORT_NAME").txt"
            if ((READY)); then
                if curl -sS -f -m 5 "http://127.0.0.1:$LOCAL_PORT/metrics" |
                    grep -E '^# (HELP|TYPE)' >"$OUTPUT_FILE" ||
                    curl -k -sS -f -m 5 "https://127.0.0.1:$LOCAL_PORT/metrics" |
                    grep -E '^# (HELP|TYPE)' >"$OUTPUT_FILE"; then
                    printf 'Metrics saved to %s\n' "$OUTPUT_FILE"
                else
                    rm -f "$OUTPUT_FILE"
                    printf 'Warning: endpoint did not return Prometheus metrics.\n' >&2
                fi
            else
                printf 'Warning: port-forward did not become ready.\n' >&2
                rm -f "$OUTPUT_FILE"
            fi

            kill "$PF_PID" 2>/dev/null || true
            wait "$PF_PID" 2>/dev/null || true
            unset PF_PID
        done
    done <<<"$CONTAINERS_PORTS"
done <<<"$PODS"

if ((MATCHED_PODS == 0)); then
    printf '\nNo pods matched the name filter.\n'
elif ((FOUND_METRICS == 0)); then
    printf '\nNo metric ports found.\n'
else
    printf '\nDiscovery complete. Check %s/ for results.\n' "$DUMP_DIR"
fi

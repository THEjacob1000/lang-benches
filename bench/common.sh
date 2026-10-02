#!/usr/bin/env bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUN=$(mise which bun)
NODE=$(mise which node)
PORT=${PORT:-3100}
VARIANTS=${VARIANTS:-"go go-4 bun elysia node bun-1"}
SCENARIOS=${SCENARIOS:-"health feed post mixed"}
JWT_SECRET=${JWT_SECRET:-gbb-dev-secret-change-me}
GO_GOGC=${GO_GOGC:-off}
GO_GOMEMLIMIT=${GO_GOMEMLIMIT:-1536MiB}
NODE_TUNING=${NODE_TUNING:---max-semi-space-size=64}

tuning_for() {
  TUNING=()
  case "$1" in
    go|go-4) TUNING=("GOGC=$GO_GOGC" "GOMEMLIMIT=$GO_GOMEMLIMIT") ;;
    node) TUNING=("NODE_OPTIONS=$NODE_TUNING") ;;
  esac
}

cpu_count() {
  local part first last total=0
  local -a parts
  IFS=, read -r -a parts <<< "$1"
  for part in "${parts[@]}"; do
    first=${part%-*}; last=${part#*-}
    total=$((total + last - first + 1))
  done
  printf '%s\n' "$total"
}

command_for() {
  VARIANT_GOMAXPROCS=${N:-2}
  case "$1" in
    go) CMD=("$ROOT/bin/go-server") ;;
    go-4) CMD=("$ROOT/bin/go-server"); VARIANT_GOMAXPROCS=4 ;;
    bun) CMD=("$BUN" "$ROOT/servers/bun/cluster.ts" "$ROOT/servers/bun/raw.ts") ;;
    elysia) CMD=("$BUN" "$ROOT/servers/bun/cluster.ts" "$ROOT/servers/bun/elysia.ts") ;;
    node) CMD=("$NODE" "$ROOT/servers/node/cluster.ts") ;;
    bun-1) CMD=("$BUN" "$ROOT/servers/bun/raw.ts") ;;
    *) echo "Unknown variant: $1" >&2; exit 1 ;;
  esac
}

wait_ready() {
  local deadline=$((SECONDS + 15))
  while ((SECONDS < deadline)); do
    if curl --fail --silent --max-time 0.5 "http://127.0.0.1:$PORT/health" >/dev/null; then return; fi
    sleep 0.1
  done
  echo "Server did not become ready on port $PORT within 15s" >&2
  return 1
}

#!/usr/bin/env bash
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
BUN=$(mise which bun)
NODE=$(mise which node)
PORT=${PORT:-3100}
VARIANTS=${VARIANTS:-"go bun elysia node bun-1"}

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
  case "$1" in
    go) CMD=("$ROOT/bin/go-server") ;;
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

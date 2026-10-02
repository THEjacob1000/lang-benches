#!/usr/bin/env bash
# Host-side helpers; keep them bash 3.2 compatible for macOS.
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=lang-benches
DATA_VOLUME=lang-benches-data
PORT=${PORT:-3100}
VARIANTS=${VARIANTS:-"go go-4 rust bun elysia node bun-1"}
SCENARIOS=${SCENARIOS:-"health feed post mixed"}
JWT_SECRET=${JWT_SECRET:-gbb-dev-secret-change-me}
GO_GOGC=${GO_GOGC:-off}
GO_GOMEMLIMIT=${GO_GOMEMLIMIT:-1536MiB}
NODE_TUNING=${NODE_TUNING:---max-semi-space-size=64}
export SERVER_MEM=${SERVER_MEM:-16G}

compose() { docker compose --progress quiet -f "$ROOT/compose.yaml" "$@"; }
tools() { compose exec -T tools "$@"; }
build_image() { docker build -t "$IMAGE" "$ROOT"; }

start_tools() {
  # Picks up checkout edits; a no-op from the layer cache when nothing changed.
  docker build --quiet -t "$IMAGE" "$ROOT" >/dev/null
  if [[ -z ${SERVER_CPUS:-} && -z ${LOAD_CPUS:-} ]]; then
    read -r SERVER_CPUS LOAD_CPUS < <(docker run --rm "$IMAGE" bench/cpusets.sh)
  elif [[ -z ${SERVER_CPUS:-} || -z ${LOAD_CPUS:-} ]]; then
    echo "Set both SERVER_CPUS and LOAD_CPUS, or neither" >&2
    exit 1
  fi
  export SERVER_CPUS LOAD_CPUS
  if [[ -n $(compose ps -aq) ]]; then
    echo "lang-benches containers already exist; finish the other benchmark or run: docker compose -p lang-benches down" >&2
    exit 1
  fi
  trap 'compose down --timeout 5 >/dev/null 2>&1' EXIT
  compose up -d tools
}

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
    go) CMD=(bin/go-server) ;;
    go-4) CMD=(bin/go-server); VARIANT_GOMAXPROCS=4 ;;
    rust) CMD=(bin/rust-server) ;;
    bun) CMD=(bun servers/bun/cluster.ts servers/bun/raw.ts) ;;
    elysia) CMD=(bun servers/bun/cluster.ts servers/bun/elysia.ts) ;;
    node) CMD=(node servers/node/cluster.ts) ;;
    bun-1) CMD=(bun servers/bun/raw.ts) ;;
    *) echo "Unknown variant: $1" >&2; exit 1 ;;
  esac
}

reset_db() { tools bash -c 'rm -f /scratch/db.sqlite /scratch/db.sqlite-wal /scratch/db.sqlite-shm && cp data/seed.db /scratch/db.sqlite'; }

# Runs CMD in a fresh server container; arguments are extra NAME=value environment settings.
start_server() {
  local server_cmd
  printf -v server_cmd '%q ' env NODE_ENV=production DB_PATH=/scratch/db.sqlite "PORT=$PORT" "JWT_SECRET=$JWT_SECRET" "$@" "${CMD[@]}"
  SERVER_CMD=$server_cmd compose up -d --no-deps --force-recreate server
  if ! tools bash -c 'deadline=$((SECONDS + 15)); until curl --fail --silent --max-time 0.5 "http://127.0.0.1:$1/health" >/dev/null; do ((SECONDS < deadline)) || exit 1; sleep 0.1; done' _ "$PORT"; then
    echo "Server did not become ready on port $PORT within 15s" >&2
    compose logs --no-log-prefix --tail 60 server >&2
    exit 1
  fi
  # The first worker answering /health doesn't mean every cluster worker is listening yet.
  sleep 1
}

stop_server() { compose stop --timeout 10 server; }

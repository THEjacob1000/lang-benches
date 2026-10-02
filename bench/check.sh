#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
start_tools
tools bash -c 'rm -rf /scratch/check && mkdir /scratch/check'
read -r -a requested <<< "$VARIANTS"
variants=(go)
for variant in "${requested[@]}"; do if [[ $variant != go ]]; then variants+=("$variant"); fi; done
for variant in "${variants[@]}"; do
  command_for "$variant"
  reset_db
  start_server WORKERS=2 "GOMAXPROCS=$VARIANT_GOMAXPROCS" TOKIO_WORKER_THREADS=2
  tools env "PORT=$PORT" "JWT_SECRET=$JWT_SECRET" bench/conformance.sh "$variant"
  server=$(compose ps -q server)
  stop_server
  # Docker sends SIGKILL (exit 137) when the server ignores SIGTERM for the whole stop timeout.
  if [[ $(docker inspect -f '{{.State.ExitCode}}' "$server") == 137 ]]; then
    echo "$variant did not shut down within 10s of SIGTERM" >&2; exit 1
  fi
  printf '%s: conformance passed\n' "$variant"
done

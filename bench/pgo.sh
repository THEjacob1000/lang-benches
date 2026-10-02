#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
CONNS=${CONNS:-64}
PPROF_ADDR=${PPROF_ADDR:-127.0.0.1:6060}
PGO_TARGETS=${PGO_TARGETS:-"go rust"}
start_tools
N=$(cpu_count "$SERVER_CPUS")
LOAD_THREADS=$(cpu_count "$LOAD_CPUS")
mixed_load() {
  tools env SCENARIO=mixed "WRK_JSON=/scratch/$1.json" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d"$2" -s bench/load.lua "http://127.0.0.1:$PORT" >/dev/null
}
for target in $PGO_TARGETS; do
case "$target" in
go)
tools bash -c 'cd servers/go && CGO_ENABLED=1 go build -pgo=off -tags pprof -trimpath -o /scratch/go-server ./'
reset_db
CMD=(/scratch/go-server)
start_server "GOMAXPROCS=$N" "GOGC=$GO_GOGC" "GOMEMLIMIT=$GO_GOMEMLIMIT" "PPROF_ADDR=$PPROF_ADDR"
mixed_load warmup 5s
mixed_load profile 35s & load_pid=$!
tools curl --fail --silent --show-error --max-time 40 "http://$PPROF_ADDR/debug/pprof/profile?seconds=30" -o /scratch/default.pgo
wait "$load_pid"
tools test -s /scratch/default.pgo
stop_server
compose cp tools:/scratch/default.pgo servers/go/default.pgo
echo 'Collected servers/go/default.pgo'
;;
rust)
tools bash -c 'rm -rf /scratch/rust-profraw && mkdir /scratch/rust-profraw && cd servers/rust \
  && CARGO_TARGET_DIR=/tmp/rust-pgo-target CARGO_ENCODED_RUSTFLAGS=-Cprofile-generate=/scratch/rust-profraw cargo build --release \
  && cp /tmp/rust-pgo-target/release/rust-server /scratch/rust-server'
reset_db
CMD=(/scratch/rust-server)
start_server "TOKIO_WORKER_THREADS=$N" "LLVM_PROFILE_FILE=/scratch/rust-profraw/%m-%p.profraw"
mixed_load rust-warmup 5s
mixed_load rust-profile 30s
stop_server
tools bash -c '"$(cd servers/rust && rustc --print target-libdir)/../bin/llvm-profdata" merge --sparse -o /scratch/merged.profdata /scratch/rust-profraw/*.profraw'
mkdir -p servers/rust/pgo
compose cp tools:/scratch/merged.profdata servers/rust/pgo/merged.profdata
echo 'Collected servers/rust/pgo/merged.profdata'
;;
*) echo "Unknown PGO target: $target" >&2; exit 1 ;;
esac
done
build_image
echo "Rebuilt the $IMAGE image with the new profiles"

#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
SERVER_CPUS=${SERVER_CPUS:-0-3,8-11}
LOAD_CPUS=${LOAD_CPUS:-4-7,12-15}
SERVER_MEM=${SERVER_MEM:-16G}
DB_DIR=${DB_DIR:-/dev/shm}
CONNS=${CONNS:-64}
PPROF_ADDR=${PPROF_ADDR:-127.0.0.1:6060}
PGO_TARGETS=${PGO_TARGETS:-"go rust"}
N=$(cpu_count "$SERVER_CPUS")
LOAD_THREADS=$(cpu_count "$LOAD_CPUS")
TMP=$(mktemp -d "$DB_DIR/gbb-pgo-XXXXXX")
unit="gbb-pgo-$$"
load_pid=''
cleanup() {
  if [[ -n $load_pid ]]; then kill "$load_pid" 2>/dev/null || true; wait "$load_pid" 2>/dev/null || true; fi
  systemctl --user stop "$unit" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
controllers=$(cat "/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.controllers")
[[ " $controllers " == *" cpuset "* ]] || { echo 'User manager has no delegated cpuset controller' >&2; exit 1; }
if curl --fail --silent --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null; then echo "Port $PORT is already occupied" >&2; exit 1; fi
for target in $PGO_TARGETS; do
case "$target" in
go)
if curl --silent --max-time 1 "http://$PPROF_ADDR/debug/pprof/" >/dev/null; then echo "Profiler address $PPROF_ADDR is already occupied" >&2; exit 1; fi
(cd servers/go && CGO_ENABLED=1 mise exec -- go build -pgo=off -tags pprof -trimpath -o "$TMP/go-server" ./)
cp data/seed.db "$TMP/db.sqlite"
systemd-run --user --unit="$unit" --collect --quiet \
  -p "AllowedCPUs=$SERVER_CPUS" -p "MemoryMax=$SERVER_MEM" -p MemorySwapMax=0 \
  -p "WorkingDirectory=$ROOT" -E "DB_PATH=$TMP/db.sqlite" -E "JWT_SECRET=$JWT_SECRET" \
  -E "PORT=$PORT" -E "GOMAXPROCS=$N" -E "GOGC=$GO_GOGC" -E "GOMEMLIMIT=$GO_GOMEMLIMIT" \
  -E "PPROF_ADDR=$PPROF_ADDR" "$TMP/go-server"
if ! wait_ready; then journalctl --user -u "$unit" -n 60 --no-pager >&2; exit 1; fi
SCENARIO=mixed WRK_JSON="$TMP/warmup.json" taskset -c "$LOAD_CPUS" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d5s -s bench/load.lua "http://127.0.0.1:$PORT" >/dev/null
SCENARIO=mixed WRK_JSON="$TMP/profile.json" taskset -c "$LOAD_CPUS" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d35s -s bench/load.lua "http://127.0.0.1:$PORT" > "$TMP/wrk.txt" & load_pid=$!
curl --fail --silent --show-error --max-time 40 "http://$PPROF_ADDR/debug/pprof/profile?seconds=30" -o "$TMP/default.pgo"
wait "$load_pid"; load_pid=''
[[ -s $TMP/default.pgo ]]
systemctl --user stop "$unit"
mv "$TMP/default.pgo" servers/go/default.pgo
(cd servers/go && CGO_ENABLED=1 mise exec -- go build -pgo=auto -trimpath -o "$ROOT/bin/go-server" ./)
echo 'Collected servers/go/default.pgo and rebuilt bin/go-server'
;;
rust)
llvm_profdata="$(cd servers/rust && rustc --print target-libdir)/../bin/llvm-profdata"
[[ -x $llvm_profdata ]] || { echo 'Install LLVM tools for the pinned toolchain: cd servers/rust && rustup component add llvm-tools-preview' >&2; exit 1; }
mkdir -p "$TMP/rust-profraw"
encoded_flags=${CARGO_ENCODED_RUSTFLAGS-}
if [[ ! ${CARGO_ENCODED_RUSTFLAGS+x} ]]; then
  read -r -a flags <<< "${RUSTFLAGS:-}"
  printf -v encoded_flags '%s\x1f' "${flags[@]}"
  encoded_flags=${encoded_flags%$'\x1f'}
fi
(cd servers/rust && CARGO_TARGET_DIR="$TMP/rust-target" CARGO_ENCODED_RUSTFLAGS="${encoded_flags:+$encoded_flags$'\x1f'}-Cprofile-generate=$TMP/rust-profraw" \
  cargo build --release --manifest-path Cargo.toml)
cp data/seed.db "$TMP/rust-db.sqlite"
systemd-run --user --unit="$unit" --collect --quiet \
  -p "AllowedCPUs=$SERVER_CPUS" -p "MemoryMax=$SERVER_MEM" -p MemorySwapMax=0 \
  -p "WorkingDirectory=$ROOT" -p KillSignal=SIGTERM -p KillMode=mixed \
  -E "DB_PATH=$TMP/rust-db.sqlite" -E "JWT_SECRET=$JWT_SECRET" \
  -E "PORT=$PORT" -E "TOKIO_WORKER_THREADS=$N" \
  -E "LLVM_PROFILE_FILE=$TMP/rust-profraw/%m-%p.profraw" "$TMP/rust-target/release/rust-server"
if ! wait_ready; then journalctl --user -u "$unit" -n 60 --no-pager >&2; exit 1; fi
SCENARIO=mixed WRK_JSON="$TMP/rust-warmup.json" taskset -c "$LOAD_CPUS" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d5s -s bench/load.lua "http://127.0.0.1:$PORT" >/dev/null
SCENARIO=mixed WRK_JSON="$TMP/rust-profile.json" taskset -c "$LOAD_CPUS" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d30s -s bench/load.lua "http://127.0.0.1:$PORT" > "$TMP/rust-wrk.txt"
systemctl --user stop "$unit"
mkdir -p servers/rust/pgo
"$llvm_profdata" merge --sparse -o "$ROOT/servers/rust/pgo/merged.profdata" "$TMP/rust-profraw/"*.profraw
servers/rust/build.sh
echo 'Collected servers/rust/pgo/merged.profdata and rebuilt bin/rust-server'
;;
*) echo "Unknown PGO target: $target" >&2; exit 1 ;;
esac
done

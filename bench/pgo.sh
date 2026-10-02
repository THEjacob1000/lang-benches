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

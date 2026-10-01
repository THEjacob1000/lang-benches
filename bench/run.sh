#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
SCENARIOS=${SCENARIOS:-"health user posts write mixed"}
REPS=${REPS:-3}
DURATION=${DURATION:-20}
WARMUP=${WARMUP:-5}
CONNS=${CONNS:-64}
SERVER_CPUS=${SERVER_CPUS:-0-3,8-11}
LOAD_CPUS=${LOAD_CPUS:-4-7,12-15}
SERVER_MEM=${SERVER_MEM:-16G}
DB_DIR=${DB_DIR:-/dev/shm}
peak_anon() {
  local max=0 key value
  trap 'printf "%s\n" "$max"; exit' TERM
  while :; do
    while read -r key value; do
      if [[ $key == anon ]]; then if ((value > max)); then max=$value; fi; break; fi
    done < "$1/memory.stat"
    sleep 0.2
  done
}
N=$(cpu_count "$SERVER_CPUS")
LOAD_THREADS=$(cpu_count "$LOAD_CPUS")
WRK="$ROOT/tools/wrk/wrk"
RESULTS="$ROOT/results/$(date -u +%Y%m%dT%H%M%S.%N)"
mkdir -p "$RESULTS/runs"
unit=""
DB="$DB_DIR/gbb-$$/db.sqlite"
mkdir -p "${DB%/*}"
cleanup() { if [[ -n $unit ]]; then systemctl --user stop "$unit"; fi; rm -rf "${DB%/*}"; }
trap cleanup EXIT
controllers=$(cat "/sys/fs/cgroup/user.slice/user-$UID.slice/user@$UID.service/cgroup.controllers")
if [[ " $controllers " != *" cpuset "* ]]; then echo "User manager has no delegated cpuset controller" >&2; exit 1; fi
if curl --fail --silent --max-time 1 "http://127.0.0.1:$PORT/health" >/dev/null; then
  echo "Port $PORT already serves a health endpoint; refusing to measure another server" >&2; exit 1
fi
read -r -a variants <<< "$VARIANTS"
read -r -a scenarios <<< "$SCENARIOS"
sequence=0
start() {
  local variant=$1 db=$2
  command_for "$variant"
  sequence=$((sequence + 1))
  unit="gbb-$variant-$$-$sequence"
  systemd-run --user --unit="$unit" --collect --quiet \
    -p "AllowedCPUs=$SERVER_CPUS" -p "MemoryMax=$SERVER_MEM" -p MemorySwapMax=0 \
    -p "WorkingDirectory=$ROOT" -E "NODE_ENV=production" -E "DB_PATH=$db" \
    -E "PORT=$PORT" -E "WORKERS=$N" -E "GOMAXPROCS=$N" "${CMD[@]}"
  if ! wait_ready; then journalctl --user -u "$unit" -n 60 --no-pager >&2; exit 1; fi
  # The first worker answering /health doesn't mean every cluster worker is listening yet.
  sleep 1
}
stop() { systemctl --user stop "$unit"; unit=""; }
cpu_usage() {
  local key value
  while read -r key value; do if [[ $key == usage_usec ]]; then printf '%s\n' "$value"; return; fi; done < "$1/cpu.stat"
  return 1
}
cpu_model=$(LC_ALL=C lscpu -J | jq -r '.lscpu[] | select(.field == "Model name:") | .data')
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)
wrk_version=$("$WRK" --version 2>&1 || true)
wrk_version=${wrk_version%%$'\n'*}
jq -n --arg cpu "$cpu_model" --arg kernel "$(uname -r)" --arg governor "$governor" \
  --arg go "$(mise exec -- go version)" --arg bun "$("$BUN" --version)" \
  --arg elysia "$(jq -r .version servers/bun/node_modules/elysia/package.json)" \
  --arg node "$("$NODE" --version)" \
  --arg express "$(jq -r .version servers/node/node_modules/express/package.json)" \
  --arg better_sqlite3 "$(jq -r .version servers/node/node_modules/better-sqlite3/package.json)" \
  --arg wrk "$wrk_version" --arg variants "$VARIANTS" --arg scenarios "$SCENARIOS" \
  --arg server_cpus "$SERVER_CPUS" --arg load_cpus "$LOAD_CPUS" --arg memory "$SERVER_MEM" \
  --argjson reps "$REPS" --argjson duration "$DURATION" --argjson warmup "$WARMUP" \
  --argjson conns "$CONNS" --argjson workers "$N" --argjson port "$PORT" \
  '{cpu:$cpu,kernel:$kernel,governor:$governor,go:$go,bun:$bun,elysia:$elysia,node:$node,express:$express,better_sqlite3:$better_sqlite3,wrk:$wrk,settings:{variants:$variants,scenarios:$scenarios,reps:$reps,duration_s:$duration,warmup_s:$warmup,connections:$conns,server_cpus:$server_cpus,load_cpus:$load_cpus,memory:$memory,workers:$workers,port:$port},meta:{}}' > "$RESULTS/env.json"
for variant in "${variants[@]}"; do
  dir="$RESULTS/runs/meta-$variant"; mkdir -p "$dir"; cp data/seed.db "$DB"
  start "$variant" "$DB"
  curl --fail --silent "http://127.0.0.1:$PORT/meta" > "$dir/meta.json"
  jq --arg variant "$variant" --slurpfile meta "$dir/meta.json" '.meta[$variant]=$meta[0]' "$RESULTS/env.json" > "$RESULTS/env.tmp"
  mv "$RESULTS/env.tmp" "$RESULTS/env.json"
  stop
  rm -f "$DB" "$DB-wal" "$DB-shm"
  sleep 2
done
for ((rep=0; rep<REPS; rep++)); do
  for scenario in "${scenarios[@]}"; do
    for ((offset=0; offset<${#variants[@]}; offset++)); do
      variant=${variants[$(((rep + offset) % ${#variants[@]}))]}
      dir="$RESULTS/runs/$rep-$scenario-$variant"; mkdir -p "$dir"; cp data/seed.db "$DB"
      start "$variant" "$DB"
      cgroup="/sys/fs/cgroup$(systemctl --user show -P ControlGroup "$unit")"
      SCENARIO="$scenario" WRK_JSON="$dir/warmup.json" taskset -c "$LOAD_CPUS" "$WRK" -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d"${WARMUP}s" -s bench/load.lua "http://127.0.0.1:$PORT" >/dev/null
      reset=true
      # Use pwrite so the per-fd reset leaves the shared read offset at zero.
      if exec {peak_fd}<>"$cgroup/memory.peak"; then
        if ! "$BUN" -e 'import { writeSync } from "node:fs"; writeSync(3, "0\n", 0, "utf8");' 3>&"$peak_fd"; then reset=false; fi
      else
        exec {peak_fd}<"$cgroup/memory.peak"
        reset=false
      fi
      if [[ $reset == false ]]; then echo "Cannot reset memory.peak for $unit; recording lifetime peak" >&2; fi
      before=$(cpu_usage "$cgroup")
      peak_anon "$cgroup" > "$dir/anon" &
      sampler=$!
      SCENARIO="$scenario" WRK_JSON="$dir/wrk.json" /usr/bin/time -f '%U %S' -o "$dir/wrk.time" \
        taskset -c "$LOAD_CPUS" "$WRK" -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d"${DURATION}s" -s bench/load.lua "http://127.0.0.1:$PORT" > "$dir/wrk.txt"
      after=$(cpu_usage "$cgroup")
      kill -TERM "$sampler"
      wait "$sampler" || true
      anon=$(<"$dir/anon")
      read -r wrk_user wrk_sys < "$dir/wrk.time"
      read -r peak <&"$peak_fd"
      exec {peak_fd}>&-
      jq --arg variant "$variant" --arg scenario "$scenario" --argjson rep "$rep" \
        --argjson before "$before" --argjson after "$after" --argjson peak "$peak" --argjson anon "$anon" --argjson reset "$reset" \
        --argjson wrk_cpu "$(jq -n "$wrk_user + $wrk_sys")" --argjson load_threads "$LOAD_THREADS" \
        '. + {cpu_seconds:(($after-$before)/1000000),peak_mem_bytes:$peak,peak_anon_bytes:$anon,memory_peak_reset:$reset,wrk_cpu_util:($wrk_cpu/(.duration_us/1000000)/$load_threads),variant:$variant,scenario:$scenario,rep:$rep}' "$dir/wrk.json" > "$dir/metrics.json"
      stop
      rm -f "$DB" "$DB-wal" "$DB-shm" "$dir/warmup.json"
      sleep 2
    done
  done
done
"$ROOT/bench/report.sh" "$RESULTS"

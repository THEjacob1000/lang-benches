#!/usr/bin/env bash
# Measures one run into /scratch/out: bench/measure.sh SERVER_CONTAINER_ID VARIANT REP,
# with SCENARIO, PORT, CONNS, WARMUP, DURATION and LOAD_THREADS in the environment.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
id=$1 variant=$2 rep=$3
out=/scratch/out
rm -rf "$out"; mkdir -p "$out"
cgroup=$(find /sys/fs/cgroup -maxdepth 3 -type d -name "*$id*" -print -quit)
if [[ -z $cgroup ]]; then echo "No cgroup found for server container $id" >&2; exit 1; fi
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
cpu_usage() {
  local key value
  while read -r key value; do if [[ $key == usage_usec ]]; then printf '%s\n' "$value"; return; fi; done < "$1/cpu.stat"
  return 1
}
WRK_JSON="$out/warmup.json" tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d"${WARMUP}s" -s bench/load.lua "http://127.0.0.1:$PORT" >/dev/null
reset=true
# Use pwrite so the per-fd reset leaves the shared read offset at zero.
if exec {peak_fd}<>"$cgroup/memory.peak"; then
  if ! bun -e 'import { writeSync } from "node:fs"; writeSync(3, "0\n", 0, "utf8");' 3>&"$peak_fd"; then reset=false; fi
else
  exec {peak_fd}<"$cgroup/memory.peak"
  reset=false
fi
if [[ $reset == false ]]; then echo "Cannot reset memory.peak for $id; recording lifetime peak" >&2; fi
before=$(cpu_usage "$cgroup")
peak_anon "$cgroup" > "$out/anon" &
sampler=$!
WRK_JSON="$out/wrk.json" /usr/bin/time -f '%U %S' -o "$out/wrk.time" \
  tools/wrk/wrk -t"$LOAD_THREADS" -c"$CONNS" --timeout 10s -d"${DURATION}s" -s bench/load.lua "http://127.0.0.1:$PORT" > "$out/wrk.txt"
after=$(cpu_usage "$cgroup")
kill -TERM "$sampler"
wait "$sampler" || true
anon=$(<"$out/anon")
read -r wrk_user wrk_sys < "$out/wrk.time"
read -r peak <&"$peak_fd"
exec {peak_fd}>&-
jq --arg variant "$variant" --arg scenario "$SCENARIO" --argjson rep "$rep" \
  --argjson before "$before" --argjson after "$after" --argjson peak "$peak" --argjson anon "$anon" --argjson reset "$reset" \
  --argjson wrk_cpu "$(jq -n "$wrk_user + $wrk_sys")" --argjson load_threads "$LOAD_THREADS" \
  '. + {cpu_seconds:(($after-$before)/1000000),peak_mem_bytes:$peak,peak_anon_bytes:$anon,memory_peak_reset:$reset,wrk_cpu_util:($wrk_cpu/(.duration_us/1000000)/$load_threads),variant:$variant,scenario:$scenario,rep:$rep}' "$out/wrk.json" > "$out/metrics.json"
rm "$out/warmup.json"

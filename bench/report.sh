#!/usr/bin/env bash
set -euo pipefail
RESULTS=${1:?Usage: bench/report.sh RESULTS_DIR}
{
  printf '# Go vs Bun vs Node benchmark\n\n'
  jq -r '"CPU: \(.cpu)  \nKernel: \(.kernel)  \nGovernor: \(.governor)  \nGo: \(.go)  \nBun: \(.bun)  \nElysia: \(.elysia)  \nNode: \(.node)  \nExpress: \(.express)  \nbetter-sqlite3: \(.better_sqlite3)  \nwrk: \(.wrk)\n\n## Settings\n\n```json\n\(.settings | tojson)\n```\n\n## Server metadata\n\n```json\n\(.meta | tojson)\n```\n"' "$RESULTS/env.json"
  jq -s -r '
    def median: sort | length as $n | if $n % 2 == 1 then .[($n/2 | floor)] else (.[($n/2)-1] + .[$n/2])/2 end;
    def fixed: (. * 100 | round) as $n | ($n / 100 | floor | tostring) + "." + ("00" + ($n % 100 | tostring))[-2:];
    def ok_rps: (.requests - .errors.status - .errors.timeout) / (.duration_us / 1000000);
    sort_by(.scenario,.variant) | group_by(.scenario)[] |
    "## \(.[0].scenario)\n\n| Variant | OK RPS | p50 ms | p99 ms | p99.9 ms | Errors (median) | CPU s / 10k requests | Peak anon MiB (max) | Peak cgroup MiB (max) | wrk CPU % (max) |\n|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    (group_by(.variant) | sort_by(map(ok_rps) | median) | reverse[] |
      "| \(.[0].variant) | \(map(ok_rps) | median | fixed) | \(map(.latency_us.p50/1000) | median | fixed) | \(map(.latency_us.p99/1000) | median | fixed) | \(map(.latency_us.p999/1000) | median | fixed) | \(map(.errors | [.[]] | add) | median) | \(map(if .requests > 0 then .cpu_seconds*10000/.requests else error("zero requests in measured run") end) | median | fixed) | \(map(.peak_anon_bytes/1048576) | max | fixed) | \(map(.peak_mem_bytes/1048576) | max | fixed) | \(map(.wrk_cpu_util*100) | max | fixed) |"), ""
  ' "$RESULTS"/runs/*/metrics.json
  printf 'Rows are sorted by OK RPS: requests per second excluding non-2xx/3xx responses and timeouts. Numeric columns are medians across repetitions except memory and wrk CPU (maximum). Peak anon is the largest anonymous (heap/stack) memory of the whole cgroup, sampled every 200 ms during measurement. Peak cgroup is memory.peak and also counts page cache, which for write workloads is mostly the growing SQLite WAL. wrk CPU %% near 100 means the load generator, not the server, capped throughput. If memory_peak_reset is false in a run, its cgroup peak includes startup and warmup.\n'
} > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"

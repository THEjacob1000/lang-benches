#!/usr/bin/env bash
set -euo pipefail
RESULTS=${1:?Usage: bench/report.sh RESULTS_DIR}
{
  printf '# Go vs Rust vs Bun vs Node benchmark\n\n'
  jq -r '"CPU: \(.cpu)  \nKernel: \(.kernel)  \nGovernor: \(.governor)  \nDocker: \(.docker // "n/a")  \nGo: \(.go)  \nRust: \(.rust // "n/a")  \nBun: \(.bun)  \nElysia: \(.elysia)  \nNode: \(.node)  \nExpress: \(.express)  \nbetter-sqlite3: \(.better_sqlite3)  \nwrk: \(.wrk)\n\n## Settings\n\n```json\n\(.settings | tojson)\n```\n\n## Server metadata\n\n```json\n\(.meta | tojson)\n```\n"' "$RESULTS/env.json"
  jq -s -r --slurpfile env "$RESULTS/env.json" '
    def median:
      sort | length as $n |
      if $n == 0 then error("missing measured runs")
      elif $n % 2 == 1 then .[($n/2 | floor)]
      else (.[($n/2)-1] + .[$n/2])/2 end;
    def fixed($digits):
      pow(10; $digits) as $scale | (. * $scale | round) as $n |
      ($n / $scale | floor | tostring) +
      if $digits == 0 then ""
      else "." + (("0" * $digits) + ($n % $scale | tostring))[-$digits:] end;
    def names: if type == "array" then . else [scan("\\S+")] end;
    def variant_label($workers):
      if . == "node" then "Node/Express"
      elif . == "go" then "Go"
      elif . == "go-4" then "Go (4 threads)"
      elif . == "rust" then "Rust"
      elif . == "bun" then "Bun (\($workers) procs)"
      elif . == "elysia" then "Elysia (\($workers) procs)"
      elif . == "bun-1" then "Bun (1 proc)"
      else . end;
    def ok_rps: (.requests - .errors.status - .errors.timeout) / (.duration_us / 1000000);
    def format_metric($metric):
      if $metric == "rps" then
        if . >= 1000000 then (. / 1000000 | fixed(2)) + "M"
        else (. / 1000 | fixed(0)) + "k" end
      elif $metric == "p99" then
        if . < 10 then fixed(2) elif . < 100 then fixed(1) else fixed(0) end
      elif $metric == "cpu" then
        if . < 100 then fixed(1) else fixed(0) end
      else fixed(0) end;
    . as $runs | $env[0].settings as $settings |
    ($settings.variants | names |
      if index("node") != null then ["node"] + map(select(. != "node")) else . end) as $variants |
    ($settings.scenarios | names) as $scenarios |
    [
      {key:"rps", label:"RPS"},
      {key:"p99", label:"p99 ms"},
      {key:"cpu", label:"CPU µs/req"},
      {key:"memory", label:"Memory MiB"}
    ] as $metrics |
    "| Scenario | Metric | \($variants | map(variant_label($settings.workers)) | join(" | ")) |",
    "|---|---|\($variants | map("---:") | join("|"))|",
    ($scenarios[] as $scenario |
      [$variants[] as $variant |
        [$runs[] | select(.scenario == $scenario and .variant == $variant)] |
        {
          variant:$variant,
          rps:(map(ok_rps) | median),
          p99:(map(.latency_us.p99 / 1000) | median),
          cpu:(map(if .requests > 0 then .cpu_seconds * 1000000 / .requests
                   else error("zero requests in measured run") end) | median),
          memory:(map(.peak_anon_bytes / 1048576) | max)
        }
      ] as $values |
      ($values | map(select(.variant == "node")) | .[0].rps) as $node_rps |
      $metrics[] as $metric |
      ($values | map(.[$metric.key]) |
        if $metric.key == "rps" then max else min end) as $best |
      "| \(if $metric.key == "rps" then $scenario else "" end) | \($metric.label) | \(
        $values | map(
          .[$metric.key] as $value |
          ($value | format_metric($metric.key)) +
          (if $metric.key == "rps" and ($variants | index("node")) != null
           then " (\($value / $node_rps | fixed(2))×)" else "" end) |
          if $value == $best then "**\(.)**" else . end
        ) | join(" | ")
      ) |"),
    "",
    "Medians of \($settings.reps) × \($settings.duration_s)s runs, \($settings.workers) server threads, \($settings.connections) connections. CPU is µs per request across all workers; memory is peak heap/stack across all workers (maximum across repetitions).",
    "",
    ($runs | group_by([.variant, .scenario]) |
      map(select((map(.errors | [.[]] | add) | add) > 0) |
          "\(.[0].variant)/\(.[0].scenario)")) as $errors |
    "Errors: \(if $errors | length == 0 then "none" else $errors | join(", ") end)",
    ($runs | map(select(.wrk_cpu_util > 0.90) | "\(.variant)/\(.scenario)") | unique) as $load_limited |
    if $load_limited | length > 0 then
      "WARNING: load generator CPU >90% in at least one run: \($load_limited | join(", ")). Throughput may be load-generator limited."
    else empty end
  ' "$RESULTS"/runs/*/metrics.json
} > "$RESULTS/summary.md"
cat "$RESULTS/summary.md"

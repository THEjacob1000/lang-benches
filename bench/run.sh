#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
REPS=${REPS:-3}
DURATION=${DURATION:-20}
WARMUP=${WARMUP:-5}
CONNS=${CONNS:-64}
start_tools
N=$(cpu_count "$SERVER_CPUS")
LOAD_THREADS=$(cpu_count "$LOAD_CPUS")
RESULTS="$ROOT/results/$(date -u +%Y%m%dT%H%M%S)"
mkdir -p "$RESULTS/runs"
read -r -a variants <<< "$VARIANTS"
read -r -a scenarios <<< "$SCENARIOS"
start() {
  command_for "$1"
  tuning_for "$1"
  reset_db
  start_server "WORKERS=$N" "GOMAXPROCS=$VARIANT_GOMAXPROCS" "TOKIO_WORKER_THREADS=$N" ${TUNING[@]+"${TUNING[@]}"}
}
tools bench/env.sh | jq --arg docker "$(docker info --format '{{.ServerVersion}} on {{.OperatingSystem}}')" --arg image "$(docker image inspect -f '{{.Id}}' "$IMAGE")" \
  --arg variants "$VARIANTS" --arg scenarios "$SCENARIOS" \
  --arg server_cpus "$SERVER_CPUS" --arg load_cpus "$LOAD_CPUS" --arg memory "$SERVER_MEM" \
  --argjson reps "$REPS" --argjson duration "$DURATION" --argjson warmup "$WARMUP" \
  --argjson conns "$CONNS" --argjson workers "$N" --argjson port "$PORT" \
  --arg gogc "$GO_GOGC" --arg gomemlimit "$GO_GOMEMLIMIT" --arg node_options "$NODE_TUNING" \
  '. + {docker:$docker,image:$image,settings:{variants:$variants,scenarios:$scenarios,reps:$reps,duration_s:$duration,warmup_s:$warmup,connections:$conns,server_cpus:$server_cpus,load_cpus:$load_cpus,memory:$memory,workers:$workers,port:$port,gomaxprocs:{go:$workers,"go-4":4},tokio_worker_threads:{rust:$workers},tuning:{go:{GOGC:$gogc,GOMEMLIMIT:$gomemlimit},"go-4":{GOGC:$gogc,GOMEMLIMIT:$gomemlimit},rust:{allocator:"mimalloc"},node:{NODE_OPTIONS:$node_options},bun:{}}},meta:{}}' > "$RESULTS/env.json"
for variant in "${variants[@]}"; do
  dir="$RESULTS/runs/meta-$variant"; mkdir -p "$dir"
  start "$variant"
  tools curl --fail --silent "http://127.0.0.1:$PORT/meta" > "$dir/meta.json"
  jq --arg variant "$variant" --slurpfile meta "$dir/meta.json" '.meta[$variant]=$meta[0]' "$RESULTS/env.json" > "$RESULTS/env.tmp"
  mv "$RESULTS/env.tmp" "$RESULTS/env.json"
  stop_server
  sleep 2
done
for ((rep=0; rep<REPS; rep++)); do
  for scenario in "${scenarios[@]}"; do
    for ((offset=0; offset<${#variants[@]}; offset++)); do
      variant=${variants[$(((rep + offset) % ${#variants[@]}))]}
      dir="$RESULTS/runs/$rep-$scenario-$variant"; mkdir -p "$dir"
      start "$variant"
      tools env "SCENARIO=$scenario" "PORT=$PORT" "CONNS=$CONNS" "WARMUP=$WARMUP" "DURATION=$DURATION" "LOAD_THREADS=$LOAD_THREADS" \
        bench/measure.sh "$(compose ps -q server)" "$variant" "$rep"
      compose cp tools:/scratch/out/. "$dir"
      stop_server
      sleep 2
    done
  done
done
"$ROOT/bench/report.sh" "$RESULTS"

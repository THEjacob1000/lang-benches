#!/usr/bin/env bash
# Prints default server and load CPU sets: half the Docker host's physical cores each, with their SMT siblings.
set -euo pipefail
IFS=, read -r -a ranges < /sys/devices/system/cpu/online
declare -A seen=()
cores=()
for range in "${ranges[@]}"; do
  for ((cpu = ${range%-*}; cpu <= ${range#*-}; cpu++)); do
    siblings=$(< "/sys/devices/system/cpu/cpu$cpu/topology/thread_siblings_list")
    if [[ -z ${seen[$siblings]:-} ]]; then seen[$siblings]=1; cores+=("$siblings"); fi
  done
done
half=$((${#cores[@]} / 2))
if ((half == 0)); then echo "Need at least two physical cores" >&2; exit 1; fi
server=$(IFS=,; echo "${cores[*]:0:half}")
load=$(IFS=,; echo "${cores[*]:half}")
printf '%s %s\n' "$server" "$load"

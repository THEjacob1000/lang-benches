#!/usr/bin/env bash
# Prints the Docker host's CPU facts and the image's toolchain versions as JSON.
set -euo pipefail
cd "$(dirname -- "${BASH_SOURCE[0]}")/.."
sha256() { if [[ -f $1 ]]; then sha256sum "$1" | cut -d' ' -f1; fi; }
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)
wrk_version=$(tools/wrk/wrk --version 2>&1 || true)
jq -n --arg cpu "$(LC_ALL=C lscpu -J | jq -r '.lscpu[] | select(.field == "Model name:") | .data')" \
  --arg kernel "$(uname -r)" --arg governor "$governor" \
  --arg go "$(go version)" --arg go_build "$(go version -m bin/go-server)" --arg pgo_sha256 "$(sha256 servers/go/default.pgo)" \
  --arg rust "$(cd servers/rust && rustc --version)" --arg rust_pgo_sha256 "$(sha256 servers/rust/pgo/merged.profdata)" \
  --arg bun "$(bun --version)" --arg elysia "$(jq -r .version servers/bun/node_modules/elysia/package.json)" \
  --arg node "$(node --version)" \
  --arg express "$(jq -r .version servers/node/node_modules/express/package.json)" \
  --arg better_sqlite3 "$(jq -r .version servers/node/node_modules/better-sqlite3/package.json)" \
  --arg wrk "${wrk_version%%$'\n'*}" \
  '{cpu:$cpu,kernel:$kernel,governor:$governor,go:$go,go_build:$go_build,pgo_sha256:$pgo_sha256,rust:$rust,rust_pgo_sha256:$rust_pgo_sha256,bun:$bun,elysia:$elysia,node:$node,express:$express,better_sqlite3:$better_sqlite3,wrk:$wrk}'

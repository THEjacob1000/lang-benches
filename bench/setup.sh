#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT"
mkdir -p tools bin
if [[ ! -x tools/wrk/wrk ]]; then
  if [[ ! -d tools/wrk ]]; then
    git clone --depth 1 --branch 4.2.0 https://github.com/wg/wrk tools/wrk
  fi
  make -C tools/wrk -j"$(nproc)"
fi
(cd servers/bun && mise exec -- bun install --frozen-lockfile)
(cd servers/go && CGO_ENABLED=1 mise exec -- go build -pgo=auto -trimpath -o "$ROOT/bin/go-server" ./)
(cd servers/node && mise exec -- npm ci)
if [[ ! -f data/seed.db || ! -f data/tokens.txt ]]; then mise exec -- bun bench/seed.ts; fi

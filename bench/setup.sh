#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
cd "$ROOT"
build_image
docker run --rm -e "JWT_SECRET=$JWT_SECRET" -v "$DATA_VOLUME:/bench/data" "$IMAGE" \
  bash -c 'if [[ ! -f data/seed.db || ! -f data/tokens.txt ]]; then bun bench/seed.ts; fi'
if [[ ! -s servers/rust/pgo/merged.profdata ]]; then PGO_TARGETS=rust bench/pgo.sh; fi

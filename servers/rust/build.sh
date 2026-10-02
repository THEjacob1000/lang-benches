#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT"
mkdir -p bin
profile="$ROOT/servers/rust/pgo/merged.profdata"
if [[ -s $profile ]]; then
  encoded_flags=${CARGO_ENCODED_RUSTFLAGS-}
  if [[ ! ${CARGO_ENCODED_RUSTFLAGS+x} ]]; then
    read -r -a flags <<< "${RUSTFLAGS:-}"
    printf -v encoded_flags '%s\x1f' "${flags[@]}"
    encoded_flags=${encoded_flags%$'\x1f'}
  fi
  export CARGO_ENCODED_RUSTFLAGS="${encoded_flags:+$encoded_flags$'\x1f'}-Cprofile-use=$profile"
fi
(cd servers/rust && CARGO_TARGET_DIR="$ROOT/servers/rust/target" cargo build --release --manifest-path Cargo.toml)
cp servers/rust/target/release/rust-server bin/rust-server

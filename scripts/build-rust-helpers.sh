#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required.' >&2; exit 1; }
command -v cargo >/dev/null && command -v rustc >/dev/null || {
    echo 'Cargo and rustc are required to build the Rust helpers.' >&2; exit 1;
}

export MACOSX_DEPLOYMENT_TARGET=27.0
# Panic messages from dependencies can include absolute source paths.
rust_flags=${CARGO_ENCODED_RUSTFLAGS-}
separator=$'\x1f'
if [ -z "${CARGO_ENCODED_RUSTFLAGS+x}" ] && [ -n "${RUSTFLAGS-}" ]; then
    read -r -a user_flags <<< "$RUSTFLAGS"
    rust_flags=$(IFS="$separator"; printf '%s' "${user_flags[*]}")
fi
export CARGO_ENCODED_RUSTFLAGS="${rust_flags:+$rust_flags$separator}--remap-path-prefix=$PWD=/Termvia${separator}--remap-path-prefix=${CARGO_HOME:-$HOME/.cargo}=/cargo"
cargo build --locked --release --target aarch64-apple-darwin \
    --target-dir .build/rust --manifest-path RustHelpers/Cargo.toml

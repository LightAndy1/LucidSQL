#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CORE_DIR="$ROOT_DIR/Core"
OUT_DIR="$ROOT_DIR/App/Bridge/Generated"
FFI_DIR="$ROOT_DIR/App/Bridge/lucidsql_coreFFI"

# Ensure PATH includes standard brew / cargo locations
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

mkdir -p "$OUT_DIR"
mkdir -p "$FFI_DIR/include"

cd "$CORE_DIR"
cargo build --release

# Generate Swift bindings using uniffi-bindgen from the compiled cdylib
cargo run --bin uniffi-bindgen generate target/release/liblucidsql_core.dylib --library --language swift --out-dir "$OUT_DIR"

# Provide header and modulemap to the C target lucidsql_coreFFI for SPM
cp "$OUT_DIR/lucidsql_coreFFI.h" "$FFI_DIR/include/"
cp "$OUT_DIR/lucidsql_coreFFI.modulemap" "$FFI_DIR/include/module.modulemap"

echo "UniFFI bindings successfully generated in $OUT_DIR"

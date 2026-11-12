#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

echo "=== 1. Building Rust Core and Generating Bridge ==="
"$ROOT_DIR/scripts/build-rust-bridge.sh"

echo "=== 2. Verifying Artifacts ==="
test -f "$ROOT_DIR/Core/target/release/liblucidsql_core.a"
test -f "$ROOT_DIR/App/Bridge/Generated/lucidsql_core.swift"
test -f "$ROOT_DIR/App/Bridge/Generated/lucidsql_coreFFI.h"

echo "=== 3. Running Cargo Tests ==="
cd "$ROOT_DIR/Core"
cargo test

echo "=== 4. Running Swift Tests ==="
cd "$ROOT_DIR/App"
swift test

echo "=== Bridge Smoke Test Passed! ==="

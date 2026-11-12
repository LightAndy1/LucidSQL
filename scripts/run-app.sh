#!/usr/bin/env bash
set -euo pipefail

# LucidSQL Launch and Packaging Script
# Builds the Rust core, generates Swift bridge bindings, builds the Swift product,
# packages a proper macOS .app bundle via scripts/package-app.sh, signs it ad-hoc, and launches it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUNDLE_DIR="${ROOT_DIR}/App/.build/LucidSQL.app"

"${SCRIPT_DIR}/package-app.sh" --configuration debug --signing-mode adhoc

if [[ "${1:-}" == "--no-launch" ]]; then
    echo "Build and packaging complete (--no-launch specified)."
    exit 0
fi

echo "=== Launching LucidSQL ==="
open "${BUNDLE_DIR}"
echo "LucidSQL launched successfully."

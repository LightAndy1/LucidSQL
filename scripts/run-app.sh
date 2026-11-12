#!/usr/bin/env bash
set -euo pipefail

# LucidSQL Launch and Packaging Script
# Builds the Rust core, generates Swift bridge bindings, builds the Swift product,
# packages a proper macOS .app bundle, signs it ad-hoc, and launches it.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/App"
BUILD_DIR="${APP_DIR}/.build"
BUNDLE_DIR="${BUILD_DIR}/LucidSQL.app"

echo "=== 1. Building Rust Core & Generating Bridge ==="
"${SCRIPT_DIR}/build-rust-bridge.sh"

echo "=== 2. Building Swift Application ==="
(cd "${APP_DIR}" && swift build --product LucidSQLApp)

echo "=== 3. Packaging macOS Application Bundle ==="
BIN_DIR="$(cd "${APP_DIR}" && swift build --show-bin-path)"
BIN_PATH="${BIN_DIR}/LucidSQLApp"

if [ ! -f "${BIN_PATH}" ]; then
    echo "Error: LucidSQLApp executable not found at ${BIN_PATH}"
    exit 1
fi

DYLIB_PATH="${ROOT_DIR}/Core/target/release/liblucidsql_core.dylib"
if [ ! -f "${DYLIB_PATH}" ]; then
    echo "Error: liblucidsql_core.dylib not found at ${DYLIB_PATH}"
    exit 1
fi

mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp -f "${BIN_PATH}" "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
cp -f "${DYLIB_PATH}" "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib"

# Set up rpath so the bundle is self-contained
install_name_tool -id "@rpath/liblucidsql_core.dylib" "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib" 2>/dev/null || true
install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp" 2>/dev/null || true

# Write Info.plist
cat << 'EOF' > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>LucidSQLApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.lucidsql.LucidSQL</string>
    <key>CFBundleName</key>
    <string>LucidSQL</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Ad-hoc code sign required by Apple Silicon after install_name_tool modifications
codesign --force --deep --sign - "${BUNDLE_DIR}"

echo "=== 4. Application Ready ==="
echo "App bundle: ${BUNDLE_DIR}"

if [[ "${1:-}" == "--no-launch" ]]; then
    echo "Build and packaging complete (--no-launch specified)."
    exit 0
fi

echo "=== 5. Launching LucidSQL ==="
open "${BUNDLE_DIR}"
echo "LucidSQL launched successfully."

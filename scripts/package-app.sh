#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/App"

VERSION="0.1.0"
BUILD_NUMBER="1"
CONFIGURATION="debug"
SIGNING_MODE="adhoc"
NOTARIZE="false"
CREATE_ZIP="false"
SKIP_BRIDGE_BUILD="false"
OUTPUT_DIR="${APP_DIR}/.build"
ARCHIVE_NAME=""

usage() {
    cat <<'EOF'
Usage: scripts/package-app.sh [options]

Options:
  --version <ver>            Marketing version (e.g. 0.1.0 or v0.1.0). Default: 0.1.0
  --build-number <num>       Bundle build number (CFBundleVersion). Default: 1
  --configuration <cfg>      Swift build configuration: debug | release. Default: debug
  --signing-mode <mode>      Signing mode: adhoc | developer-id. Default: adhoc
  --notarize                 Submit to Apple notary service, staple, and validate (requires developer-id)
  --zip                      Create distributable .zip (with ditto) and .zip.sha256
  --archive-name <name>      Base name for .zip output (without .zip)
  --output-dir <path>        Directory for .app and .zip outputs. Default: App/.build
  --skip-bridge-build        Reuse existing Core/target/release/liblucidsql_core.dylib and UniFFI bindings
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --build-number)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --configuration)
            CONFIGURATION="${2:-}"
            shift 2
            ;;
        --signing-mode)
            SIGNING_MODE="${2:-}"
            shift 2
            ;;
        --notarize)
            NOTARIZE="true"
            shift
            ;;
        --zip)
            CREATE_ZIP="true"
            shift
            ;;
        --archive-name)
            ARCHIVE_NAME="${2:-}"
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="${2:-}"
            shift 2
            ;;
        --skip-bridge-build)
            SKIP_BRIDGE_BUILD="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$PATH"

VERSION="${VERSION#v}"
# CFBundleShortVersionString must start with numeric dot-separated components for Apple tooling.
BUNDLE_SHORT_VERSION="${VERSION%%-*}"
if [[ ! "${BUNDLE_SHORT_VERSION}" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    BUNDLE_SHORT_VERSION="0.1.0"
fi

if [[ "${CONFIGURATION}" != "debug" && "${CONFIGURATION}" != "release" ]]; then
    echo "Error: --configuration must be 'debug' or 'release' (got '${CONFIGURATION}')." >&2
    exit 1
fi

if [[ "${SIGNING_MODE}" != "adhoc" && "${SIGNING_MODE}" != "developer-id" ]]; then
    echo "Error: --signing-mode must be 'adhoc' or 'developer-id' (got '${SIGNING_MODE}')." >&2
    exit 1
fi

if [[ "${NOTARIZE}" == "true" && "${SIGNING_MODE}" != "developer-id" ]]; then
    echo "Error: --notarize requires --signing-mode developer-id." >&2
    exit 1
fi

HOST_ARCH="$(uname -m)"
if [[ -z "${ARCHIVE_NAME}" ]]; then
    if [[ "${SIGNING_MODE}" == "developer-id" && "${NOTARIZE}" == "true" ]]; then
        ARCHIVE_NAME="LucidSQL-${VERSION}-macos-${HOST_ARCH}"
    else
        ARCHIVE_NAME="LucidSQL-${VERSION}-adhoc-unsigned-macos-${HOST_ARCH}"
    fi
fi

mkdir -p "${OUTPUT_DIR}"
BUNDLE_DIR="${OUTPUT_DIR}/LucidSQL.app"

if [[ "${SKIP_BRIDGE_BUILD}" != "true" ]]; then
    echo "=== 1. Building Rust Core & Generating Bridge ==="
    "${SCRIPT_DIR}/build-rust-bridge.sh"
else
    echo "=== 1. Reusing Existing Rust Core & Bridge ==="
fi

DYLIB_PATH="${ROOT_DIR}/Core/target/release/liblucidsql_core.dylib"
if [[ ! -f "${DYLIB_PATH}" ]]; then
    echo "Error: liblucidsql_core.dylib not found at ${DYLIB_PATH}" >&2
    exit 1
fi

echo "=== 2. Building Swift Application (${CONFIGURATION}, ${HOST_ARCH}) ==="
(cd "${APP_DIR}" && swift build -c "${CONFIGURATION}" --product LucidSQLApp)

BIN_DIR="$(cd "${APP_DIR}" && swift build -c "${CONFIGURATION}" --show-bin-path)"
BIN_PATH="${BIN_DIR}/LucidSQLApp"
if [[ ! -f "${BIN_PATH}" ]]; then
    echo "Error: LucidSQLApp executable not found at ${BIN_PATH}" >&2
    exit 1
fi

echo "=== 3. Assembling macOS Application Bundle ==="
rm -rf "${BUNDLE_DIR}"
mkdir -p "${BUNDLE_DIR}/Contents/MacOS"
mkdir -p "${BUNDLE_DIR}/Contents/Frameworks"
mkdir -p "${BUNDLE_DIR}/Contents/Resources"

cp -f "${BIN_PATH}" "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
cp -f "${DYLIB_PATH}" "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib"
chmod +x "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"

install_name_tool -id "@rpath/liblucidsql_core.dylib" "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib" 2>/dev/null || true
if ! otool -l "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
fi

cat <<EOF > "${BUNDLE_DIR}/Contents/Info.plist"
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
    <string>${BUNDLE_SHORT_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

# Strip extended attributes before signing so Apple code sealing succeeds cleanly.
xattr -cr "${BUNDLE_DIR}"

echo "=== 4. Signing Application Bundle (${SIGNING_MODE}, inside-out) ==="
if [[ "${SIGNING_MODE}" == "adhoc" ]]; then
    codesign --force --sign - "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib"
    codesign --force --sign - "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
    codesign --force --sign - "${BUNDLE_DIR}"
    codesign --verify --deep --strict "${BUNDLE_DIR}"
    echo "Signed ad-hoc (for local/development testing only; not notarized)."
else
    DEVELOPER_ID_IDENTITY="${APPLE_DEVELOPER_ID_APPLICATION:-}"
    if [[ -z "${DEVELOPER_ID_IDENTITY}" ]]; then
        echo "Error: APPLE_DEVELOPER_ID_APPLICATION must be set for developer-id signing." >&2
        exit 1
    fi
    KEYCHAIN_ARGS=()
    if [[ -n "${APPLE_KEYCHAIN_PATH:-}" ]]; then
        KEYCHAIN_ARGS=(--keychain "${APPLE_KEYCHAIN_PATH}")
    fi

    codesign --force --options runtime --timestamp "${KEYCHAIN_ARGS[@]}" --sign "${DEVELOPER_ID_IDENTITY}" \
        "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib"
    codesign --force --options runtime --timestamp "${KEYCHAIN_ARGS[@]}" --sign "${DEVELOPER_ID_IDENTITY}" \
        "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
    codesign --force --options runtime --timestamp "${KEYCHAIN_ARGS[@]}" --sign "${DEVELOPER_ID_IDENTITY}" \
        "${BUNDLE_DIR}"
    codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"
fi

if [[ "${NOTARIZE}" == "true" ]]; then
    echo "=== 5. Submitting for Apple Notarization & Stapling ==="
    if [[ -z "${APPLE_NOTARY_KEY_ID:-}" || -z "${APPLE_NOTARY_ISSUER_ID:-}" || -z "${APPLE_NOTARY_PRIVATE_KEY_PATH:-}" ]]; then
        echo "Error: APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER_ID, and APPLE_NOTARY_PRIVATE_KEY_PATH are required for notarization." >&2
        exit 1
    fi
    if [[ ! -f "${APPLE_NOTARY_PRIVATE_KEY_PATH}" ]]; then
        echo "Error: APPLE_NOTARY_PRIVATE_KEY_PATH file does not exist." >&2
        exit 1
    fi

    NOTARY_SUBMIT_ZIP="${OUTPUT_DIR}/LucidSQL-notary-submit.zip"
    rm -f "${NOTARY_SUBMIT_ZIP}"
    ditto -c -k --keepParent "${BUNDLE_DIR}" "${NOTARY_SUBMIT_ZIP}"

    xcrun notarytool submit "${NOTARY_SUBMIT_ZIP}" \
        --key "${APPLE_NOTARY_PRIVATE_KEY_PATH}" \
        --key-id "${APPLE_NOTARY_KEY_ID}" \
        --issuer "${APPLE_NOTARY_ISSUER_ID}" \
        --wait

    rm -f "${NOTARY_SUBMIT_ZIP}"

    xcrun stapler staple "${BUNDLE_DIR}"
    xcrun stapler validate "${BUNDLE_DIR}"
    spctl --assess --type execute --verbose=4 "${BUNDLE_DIR}"
fi

echo "=== Application Bundle Ready ==="
echo "Bundle path: ${BUNDLE_DIR}"
echo "Binary architectures (LucidSQLApp): $(lipo -archs "${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp")"
echo "Bridge architectures (liblucidsql_core.dylib): $(lipo -archs "${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib")"

if [[ "${CREATE_ZIP}" == "true" ]]; then
    ZIP_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}.zip"
    rm -f "${ZIP_PATH}" "${ZIP_PATH}.sha256"
    ditto -c -k --keepParent "${BUNDLE_DIR}" "${ZIP_PATH}"
    (cd "${OUTPUT_DIR}" && shasum -a 256 "${ARCHIVE_NAME}.zip" > "${ARCHIVE_NAME}.zip.sha256")
    echo "ZIP archive: ${ZIP_PATH}"
    echo "SHA-256 checksum: ${ZIP_PATH}.sha256"
    cat "${ZIP_PATH}.sha256"
fi

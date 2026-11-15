#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="${ROOT_DIR}/App"

# shellcheck source=scripts/lib/bundle-verify.sh
source "${SCRIPT_DIR}/lib/bundle-verify.sh"

VERSION="0.1.0"
VERSION_EXPLICIT="false"
BUILD_NUMBER=""
GIT_COMMIT=""
CONFIGURATION="debug"
SIGNING_MODE="adhoc"
CREATE_DMG="false"
SKIP_BRIDGE_BUILD="false"
REQUIRE_LIQUID_GLASS="false"
REQUIRE_NATIVE_ICON="false"
OUTPUT_DIR="${APP_DIR}/.build"
ARCHIVE_NAME=""

usage() {
    cat <<'EOF'
Usage: scripts/package-app.sh [options]

Options:
  --version <ver>            Marketing version (e.g. 0.1.0 or v0.1.0). Default: 0.1.0
  --build-number <num>       Bundle build number (CFBundleVersion). Default: git commit count or 1
  --commit <sha>             Short commit SHA embedded in Info.plist. Default: git rev-parse --short=7 HEAD
  --configuration <cfg>      Swift build configuration: debug | release. Default: debug
  --signing-mode <mode>      Signing mode: adhoc (intended distribution mode). Default: adhoc
  --dmg                      Create distributable .dmg (with Applications shortcut) and .dmg.sha256
  --archive-name <name>      Base name for .dmg output (without .dmg)
  --output-dir <path>        Directory for .app and .dmg outputs. Default: App/.build
  --skip-bridge-build        Reuse existing Core/target/release/liblucidsql_core.dylib and UniFFI bindings
  --require-liquid-glass     Verify SDK >= 26 and compiled Liquid Glass symbols in LucidSQLApp
  --require-native-icon      Require xcrun actool to compile Assets/AppIcon/LucidSQL.icon into Assets.car
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            VERSION_EXPLICIT="true"
            shift 2
            ;;
        --build-number)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --commit)
            GIT_COMMIT="${2:-}"
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
        --dmg)
            CREATE_DMG="true"
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
        --require-liquid-glass)
            REQUIRE_LIQUID_GLASS="true"
            shift
            ;;
        --require-native-icon)
            REQUIRE_NATIVE_ICON="true"
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

if [[ "${SIGNING_MODE}" != "adhoc" ]]; then
    echo "Error: Unsupported --signing-mode '${SIGNING_MODE}'. LucidSQL distributes ad-hoc-signed builds only ('adhoc')." >&2
    exit 1
fi

HOST_ARCH="$(uname -m)"
if [[ "${HOST_ARCH}" != "arm64" ]]; then
    echo "Error: LucidSQL targets Apple Silicon (arm64) only; current host architecture is '${HOST_ARCH}'." >&2
    exit 1
fi

SDK_VERSION="$(xcrun --show-sdk-version)"
SDK_MAJOR="${SDK_VERSION%%.*}"
echo "Active macOS SDK: ${SDK_VERSION} ($(xcrun --show-sdk-path))"
echo "Active Swift: $(swift --version | head -n 1)"
if [[ "${REQUIRE_LIQUID_GLASS}" == "true" ]]; then
    if [[ ! "${SDK_MAJOR}" =~ ^[0-9]+$ ]] || [[ "${SDK_MAJOR}" -lt 26 ]]; then
        echo "Error: --require-liquid-glass requires macOS 26+ SDK (found SDK '${SDK_VERSION}')." >&2
        exit 1
    fi
fi

if [[ -z "${GIT_COMMIT}" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-parse --short=7 HEAD >/dev/null 2>&1; then
        GIT_COMMIT="$(git -C "${ROOT_DIR}" rev-parse --short=7 HEAD)"
    else
        GIT_COMMIT="unknown"
    fi
fi

if [[ -z "${BUILD_NUMBER}" ]]; then
    if command -v git >/dev/null 2>&1 && git -C "${ROOT_DIR}" rev-list --count HEAD >/dev/null 2>&1; then
        BUILD_NUMBER="$(git -C "${ROOT_DIR}" rev-list --count HEAD)"
    else
        BUILD_NUMBER="1"
    fi
fi

if [[ -z "${ARCHIVE_NAME}" ]]; then
    if [[ "${VERSION_EXPLICIT}" == "true" ]]; then
        ARCHIVE_NAME="LucidSQL-${VERSION}-macos-${HOST_ARCH}"
    else
        ARCHIVE_NAME="LucidSQL-${BUNDLE_SHORT_VERSION}-dev.${GIT_COMMIT}-macos-${HOST_ARCH}"
    fi
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd -P)"
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

BUNDLE_EXEC="${BUNDLE_DIR}/Contents/MacOS/LucidSQLApp"
BUNDLE_DYLIB="${BUNDLE_DIR}/Contents/Frameworks/liblucidsql_core.dylib"

cp -f "${BIN_PATH}" "${BUNDLE_EXEC}"
cp -f "${DYLIB_PATH}" "${BUNDLE_DYLIB}"
chmod 755 "${BUNDLE_EXEC}" "${BUNDLE_DYLIB}"

ICON_SOURCE_DIR="${ROOT_DIR}/Assets/AppIcon/LucidSQL.icon"
FALLBACK_ICNS_PATH="${ROOT_DIR}/Assets/AppIcon/AppIcon.icns"
if [[ ! -f "${FALLBACK_ICNS_PATH}" ]]; then
    echo "Error: fallback app icon not found at ${FALLBACK_ICNS_PATH}" >&2
    exit 1
fi
cp -f "${FALLBACK_ICNS_PATH}" "${BUNDLE_DIR}/Contents/Resources/LucidSQL.icns"

ACTOOL_BIN=""
if ACTOOL_BIN="$(xcrun --find actool 2>/dev/null)" && [[ -x "${ACTOOL_BIN}" ]]; then
    if [[ ! -d "${ICON_SOURCE_DIR}" ]]; then
        echo "Error: native icon source not found at ${ICON_SOURCE_DIR}" >&2
        exit 1
    fi
    echo "Compiling native layered app icon with actool (${ACTOOL_BIN})..."
    PARTIAL_ICON_PLIST="$(mktemp -t lucidsql-icon-plist)"
    if "${ACTOOL_BIN}" "${ICON_SOURCE_DIR}" \
        --compile "${BUNDLE_DIR}/Contents/Resources" \
        --app-icon LucidSQL \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --output-partial-info-plist "${PARTIAL_ICON_PLIST}"; then
        rm -f "${PARTIAL_ICON_PLIST}"
        if [[ ! -f "${BUNDLE_DIR}/Contents/Resources/Assets.car" ]]; then
            echo "Error: actool completed without producing Contents/Resources/Assets.car" >&2
            exit 1
        fi
        # Always keep full 16px-1024px custom fallback .icns alongside Assets.car (actool emits <=256px .icns).
        cp -f "${FALLBACK_ICNS_PATH}" "${BUNDLE_DIR}/Contents/Resources/LucidSQL.icns"
    else
        rm -f "${PARTIAL_ICON_PLIST}"
        if [[ "${REQUIRE_NATIVE_ICON}" == "true" ]]; then
            echo "Error: actool failed to compile ${ICON_SOURCE_DIR}" >&2
            exit 1
        fi
        echo "Warning: actool failed; keeping fallback LucidSQL.icns without Assets.car." >&2
    fi
else
    if [[ "${REQUIRE_NATIVE_ICON}" == "true" ]]; then
        echo "Error: --require-native-icon requested, but xcrun actool was not found (Xcode required)." >&2
        exit 1
    fi
    echo "Warning: xcrun actool not found (CommandLineTools only); using fallback LucidSQL.icns without Assets.car." >&2
fi

echo "=== 4. Rewriting Mach-O Install Names & RPATHs (Pre-Sign) ==="
install_name_tool -id "@rpath/liblucidsql_core.dylib" "${BUNDLE_DYLIB}"

# Rewrite any absolute/build-machine reference to liblucidsql_core.dylib in LucidSQLApp.
while IFS= read -r dep; do
    [[ -z "${dep}" ]] && continue
    if [[ "${dep}" != "@rpath/liblucidsql_core.dylib" ]]; then
        echo "Rewriting dependency in LucidSQLApp: ${dep} -> @rpath/liblucidsql_core.dylib"
        install_name_tool -change "${dep}" "@rpath/liblucidsql_core.dylib" "${BUNDLE_EXEC}"
    fi
done < <(extract_macho_deps "${BUNDLE_EXEC}" | grep -E '(^|/)liblucidsql_core\.dylib$' || true)

# Remove build-machine / toolchain / Homebrew rpaths from all bundled Mach-O binaries.
while IFS= read -r macho; do
    while IFS= read -r rp; do
        [[ -z "${rp}" ]] && continue
        if ! is_allowed_rpath "${rp}"; then
            echo "Removing non-relocatable rpath from $(basename "${macho}"): ${rp}"
            install_name_tool -delete_rpath "${rp}" "${macho}"
        fi
    done < <(extract_macho_rpaths "${macho}")
done < <(find "${BUNDLE_DIR}" -type f | while IFS= read -r f; do file -b "${f}" | grep -q "Mach-O" && echo "${f}"; done)

if [[ $'\n'"$(extract_macho_rpaths "${BUNDLE_EXEC}")"$'\n' != *$'\n@executable_path/../Frameworks\n'* ]]; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "${BUNDLE_EXEC}"
fi

cat <<EOF > "${BUNDLE_DIR}/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>LucidSQL</string>
    <key>CFBundleExecutable</key>
    <string>LucidSQLApp</string>
    <key>CFBundleIconFile</key>
    <string>LucidSQL</string>
    <key>CFBundleIconName</key>
    <string>LucidSQL</string>
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
    <key>LucidSQLGitCommit</key>
    <string>${GIT_COMMIT}</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
EOF

echo "=== 5. Verifying Relocatable Mach-O Linkage & Styling ==="
verify_bundle_macho "${BUNDLE_DIR}"
if [[ "${REQUIRE_LIQUID_GLASS}" == "true" ]]; then
    verify_liquid_glass_symbols "${BUNDLE_EXEC}"
fi

# Strip extended attributes before signing so Apple code sealing succeeds cleanly.
xattr -cr "${BUNDLE_DIR}"

echo "=== 6. Ad-Hoc Signing Application Bundle (Inside-Out) ==="
while IFS= read -r fw_macho; do
    codesign --force --sign - "${fw_macho}"
done < <(find "${BUNDLE_DIR}/Contents/Frameworks" -type f | sort | while IFS= read -r f; do file -b "${f}" | grep -q "Mach-O" && echo "${f}"; done)

codesign --force --sign - "${BUNDLE_EXEC}"
codesign --force --sign - "${BUNDLE_DIR}"
codesign --verify --deep --strict --verbose=2 "${BUNDLE_DIR}"
echo "Signed ad-hoc (not notarized; intended distribution mode)."

echo "=== Application Bundle Ready ==="
echo "Bundle path: ${BUNDLE_DIR}"
echo "Version / Build / Commit: ${BUNDLE_SHORT_VERSION} (${BUILD_NUMBER}) @ ${GIT_COMMIT}"
echo "Binary architectures (LucidSQLApp): $(lipo -archs "${BUNDLE_EXEC}")"
echo "Bridge architectures (liblucidsql_core.dylib): $(lipo -archs "${BUNDLE_DYLIB}")"
echo "Executable UUID: $(dwarfdump --uuid "${BUNDLE_EXEC}" | head -n 1)"
echo "Executable SHA-256: $(shasum -a 256 "${BUNDLE_EXEC}" | awk '{print $1}')"
echo "Dylib UUID: $(dwarfdump --uuid "${BUNDLE_DYLIB}" | head -n 1)"
echo "Dylib SHA-256: $(shasum -a 256 "${BUNDLE_DYLIB}" | awk '{print $1}')"

if [[ "${CREATE_DMG}" == "true" ]]; then
    echo "=== 7. Creating Versioned arm64 DMG & SHA-256 Checksum ==="
    DMG_PATH="${OUTPUT_DIR}/${ARCHIVE_NAME}.dmg"
    DMG_STAGING="${OUTPUT_DIR}/.dmg-staging-${ARCHIVE_NAME}"
    DMG_RW_PATH="${OUTPUT_DIR}/.${ARCHIVE_NAME}-rw.dmg"
    DMG_RW_MOUNT="$(mktemp -d "${TMPDIR:-/tmp}/lucidsql-dmg-mount.XXXXXX")"
    DMG_BG_SRC="${ROOT_DIR}/Assets/DMG/dmg-background@2x.png"
    DMG_VOLICON_SRC="${ROOT_DIR}/Assets/AppIcon/AppIcon.icns"

    if [[ ! -f "${DMG_BG_SRC}" ]]; then
        echo "Error: DMG background artwork not found at ${DMG_BG_SRC}" >&2
        exit 1
    fi
    if [[ ! -f "${DMG_VOLICON_SRC}" ]]; then
        echo "Error: DMG volume icon not found at ${DMG_VOLICON_SRC}" >&2
        exit 1
    fi

    cleanup_dmg_build() {
        if [[ -n "${DMG_RW_MOUNT:-}" ]] && mount | grep -q " on ${DMG_RW_MOUNT} "; then
            hdiutil detach "${DMG_RW_MOUNT}" -force >/dev/null 2>&1 || true
        fi
        rm -rf "${DMG_STAGING:-}" "${DMG_RW_PATH:-}" "${DMG_RW_MOUNT:-}"
    }
    trap cleanup_dmg_build EXIT

    rm -rf "${DMG_STAGING}" "${DMG_RW_PATH}" "${DMG_PATH}" "${DMG_PATH}.sha256"
    mkdir -p "${DMG_STAGING}/.background"

    ditto "${BUNDLE_DIR}" "${DMG_STAGING}/LucidSQL.app"
    ln -s /Applications "${DMG_STAGING}/Applications"
    cp -f "${DMG_BG_SRC}" "${DMG_STAGING}/.background/bg.png"
    cp -f "${DMG_VOLICON_SRC}" "${DMG_STAGING}/.VolumeIcon.icns"

    python3 "${SCRIPT_DIR}/lib/generate_dmg_ds_store.py" \
        --output "${DMG_STAGING}/.DS_Store" \
        --volume-name "LucidSQL" \
        --background-rel ".background/bg.png"

    HDIUTIL_OK="false"
    for attempt in 1 2 3; do
        if hdiutil create \
            -volname "LucidSQL" \
            -srcfolder "${DMG_STAGING}" \
            -fs HFS+ \
            -ov \
            -format UDRW \
            "${DMG_RW_PATH}"; then
            HDIUTIL_OK="true"
            break
        fi
        echo "hdiutil create (UDRW) attempt ${attempt} failed; retrying..." >&2
        rm -f "${DMG_RW_PATH}"
        sleep 2
    done

    if [[ "${HDIUTIL_OK}" != "true" ]]; then
        echo "Error: Failed to create read-write staging DMG at ${DMG_RW_PATH}" >&2
        exit 1
    fi

    # Apply Finder custom volume icon bit and invisible flags on the mounted HFS+ root.
    if hdiutil attach "${DMG_RW_PATH}" -nobrowse -noverify -mountpoint "${DMG_RW_MOUNT}"; then
        if command -v SetFile >/dev/null 2>&1; then
            SetFile -a C "${DMG_RW_MOUNT}"
            SetFile -a V "${DMG_RW_MOUNT}/.background" "${DMG_RW_MOUNT}/.background/bg.png" "${DMG_RW_MOUNT}/.VolumeIcon.icns" || true
        else
            echo "Warning: SetFile not found; custom volume icon attribute was not set." >&2
        fi
        sync
        hdiutil detach "${DMG_RW_MOUNT}" -quiet || hdiutil detach "${DMG_RW_MOUNT}" -force
    else
        echo "Error: Failed to mount ${DMG_RW_PATH} to configure Finder volume attributes." >&2
        exit 1
    fi

    HDIUTIL_CONVERT_OK="false"
    for attempt in 1 2 3; do
        if hdiutil convert "${DMG_RW_PATH}" \
            -format UDZO \
            -imagekey zlib-level=9 \
            -ov \
            -o "${DMG_PATH}"; then
            HDIUTIL_CONVERT_OK="true"
            break
        fi
        echo "hdiutil convert (UDZO) attempt ${attempt} failed; retrying..." >&2
        rm -f "${DMG_PATH}"
        sleep 2
    done

    cleanup_dmg_build
    trap - EXIT
    if [[ "${HDIUTIL_CONVERT_OK}" != "true" ]]; then
        echo "Error: Failed to compress DMG at ${DMG_PATH}" >&2
        exit 1
    fi

    hdiutil verify "${DMG_PATH}"
    (cd "${OUTPUT_DIR}" && shasum -a 256 "${ARCHIVE_NAME}.dmg" > "${ARCHIVE_NAME}.dmg.sha256")
    (cd "${OUTPUT_DIR}" && shasum -a 256 -c "${ARCHIVE_NAME}.dmg.sha256")
    echo "DMG archive: ${DMG_PATH}"
    echo "SHA-256 checksum: ${DMG_PATH}.sha256"
    cat "${DMG_PATH}.sha256"
fi

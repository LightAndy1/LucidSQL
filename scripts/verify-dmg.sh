#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=scripts/lib/bundle-verify.sh
source "${SCRIPT_DIR}/lib/bundle-verify.sh"

REQUIRE_LIQUID_GLASS="false"
ISOLATE_BUILD_DIRS="false"
SKIP_LAUNCH="false"
DMG_PATH=""

usage() {
    cat <<'EOF'
Usage: scripts/verify-dmg.sh [options] <path-to-dmg>

Mounts the DMG, copies LucidSQL.app to an isolated directory outside the repo,
verifies Mach-O dependencies, code signature, Liquid Glass symbols (optional),
and launches the relocated copy with build directories isolated and DYLD_* unset.

Options:
  --require-liquid-glass     Verify compiled Liquid Glass symbols inside the copied .app
  --isolate-repo-build-dirs  Temporarily hide Core/target and App/.build during launch test
  --skip-launch              Skip launching the relocated app (Mach-O + codesign checks only)
  -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --require-liquid-glass)
            REQUIRE_LIQUID_GLASS="true"
            shift
            ;;
        --isolate-repo-build-dirs)
            ISOLATE_BUILD_DIRS="true"
            shift
            ;;
        --skip-launch)
            SKIP_LAUNCH="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            if [[ -n "${DMG_PATH}" ]]; then
                echo "Error: Unexpected extra argument '$1'" >&2
                exit 1
            fi
            DMG_PATH="$1"
            shift
            ;;
    esac
done

if [[ -z "${DMG_PATH}" || ! -f "${DMG_PATH}" ]]; then
    echo "Error: DMG file not found: '${DMG_PATH}'" >&2
    exit 1
fi

DMG_DIR="$(cd "$(dirname "${DMG_PATH}")" && pwd -P)"
DMG_BASE="$(basename "${DMG_PATH}")"
DMG_ABS="${DMG_DIR}/${DMG_BASE}"
DMG_SHA256="$(shasum -a 256 "${DMG_ABS}" | awk '{print $1}')"

if [[ -f "${DMG_ABS}.sha256" ]]; then
    echo "=== 1. Verifying DMG Checksum ==="
    (cd "${DMG_DIR}" && shasum -a 256 -c "${DMG_BASE}.sha256")
fi
echo "DMG path: ${DMG_ABS}"
echo "DMG SHA-256: ${DMG_SHA256}"

echo "=== 2. Verifying DMG Integrity ==="
hdiutil verify "${DMG_ABS}"

BASE_TMP="${TMPDIR:-/tmp}"
BASE_TMP="${BASE_TMP%/}"
WORK_DIR="$(mktemp -d "${BASE_TMP}/lucidsql-dmg-verify.XXXXXX")"
WORK_DIR="$(cd "${WORK_DIR}" && pwd -P)"
MOUNT_DIR="${WORK_DIR}/mnt"
RELOCATED_DIR="${WORK_DIR}/relocated"
mkdir -p "${MOUNT_DIR}" "${RELOCATED_DIR}"

HIDDEN_CORE_TARGET=""
HIDDEN_APP_BUILD=""
APP_PID=""

cleanup() {
    set +e
    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
        kill "${APP_PID}" 2>/dev/null || true
        sleep 1
        kill -9 "${APP_PID}" 2>/dev/null || true
    fi
    if [[ -n "${APP_PID}" ]]; then
        wait "${APP_PID}" 2>/dev/null || true
    fi
    if [[ -n "${HIDDEN_CORE_TARGET}" && -d "${HIDDEN_CORE_TARGET}" && ! -e "${ROOT_DIR}/Core/target" ]]; then
        mv "${HIDDEN_CORE_TARGET}" "${ROOT_DIR}/Core/target"
    fi
    if [[ -n "${HIDDEN_APP_BUILD}" && -d "${HIDDEN_APP_BUILD}" && ! -e "${ROOT_DIR}/App/.build" ]]; then
        mv "${HIDDEN_APP_BUILD}" "${ROOT_DIR}/App/.build"
    fi
    if mount | grep -F "on ${MOUNT_DIR} " >/dev/null 2>&1; then
        hdiutil detach "${MOUNT_DIR}" -quiet || hdiutil detach "${MOUNT_DIR}" -force -quiet || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

echo "=== 3. Mounting DMG & Inspecting Layout ==="
hdiutil attach "${DMG_ABS}" -readonly -nobrowse -mountpoint "${MOUNT_DIR}"

if [[ ! -d "${MOUNT_DIR}/LucidSQL.app" ]]; then
    echo "Error: LucidSQL.app not found inside mounted DMG." >&2
    exit 1
fi
if [[ ! -L "${MOUNT_DIR}/Applications" ]]; then
    echo "Error: Applications symlink not found inside mounted DMG." >&2
    exit 1
fi
APPS_TARGET="$(readlink "${MOUNT_DIR}/Applications")"
if [[ "${APPS_TARGET}" != "/Applications" ]]; then
    echo "Error: Applications symlink points to '${APPS_TARGET}' instead of '/Applications'." >&2
    exit 1
fi
if [[ -n "$(find "${MOUNT_DIR}" -maxdepth 2 -name "*.zip")" ]]; then
    echo "Error: Unexpected nested .zip found inside DMG." >&2
    exit 1
fi

echo "=== 4. Copying LucidSQL.app to Fresh Relocated Directory ==="
RELOCATED_APP="${RELOCATED_DIR}/LucidSQL.app"
ditto "${MOUNT_DIR}/LucidSQL.app" "${RELOCATED_APP}"
hdiutil detach "${MOUNT_DIR}" -quiet

echo "=== 5. Verifying Relocated Bundle Signature, Provenance & Mach-O Linkage ==="
RELOCATED_EXEC="${RELOCATED_APP}/Contents/MacOS/LucidSQLApp"
RELOCATED_DYLIB="${RELOCATED_APP}/Contents/Frameworks/liblucidsql_core.dylib"
PLIST_PATH="${RELOCATED_APP}/Contents/Info.plist"

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${PLIST_PATH}" 2>/dev/null || echo 'unknown')"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${PLIST_PATH}" 2>/dev/null || echo 'unknown')"
APP_COMMIT="$(/usr/libexec/PlistBuddy -c 'Print :LucidSQLGitCommit' "${PLIST_PATH}" 2>/dev/null || echo 'unknown')"
EXEC_UUID="$(dwarfdump --uuid "${RELOCATED_EXEC}" | awk '{print $2; exit}')"
EXEC_SHA256="$(shasum -a 256 "${RELOCATED_EXEC}" | awk '{print $1}')"
DYLIB_UUID="$(dwarfdump --uuid "${RELOCATED_DYLIB}" | awk '{print $2; exit}')"
DYLIB_SHA256="$(shasum -a 256 "${RELOCATED_DYLIB}" | awk '{print $1}')"

echo "Provenance: version=${APP_VERSION} build=${APP_BUILD} commit=${APP_COMMIT}"
echo "Executable UUID=${EXEC_UUID} SHA-256=${EXEC_SHA256}"
echo "Dylib UUID=${DYLIB_UUID} SHA-256=${DYLIB_SHA256}"

codesign --verify --deep --strict --verbose=2 "${RELOCATED_APP}"
verify_bundle_macho "${RELOCATED_APP}"
if [[ "${REQUIRE_LIQUID_GLASS}" == "true" ]]; then
    verify_liquid_glass_symbols "${RELOCATED_EXEC}"
fi

if [[ "${SKIP_LAUNCH}" == "true" ]]; then
    echo "DMG verification passed (--skip-launch specified)."
    exit 0
fi

if [[ "${ISOLATE_BUILD_DIRS}" == "true" ]]; then
    echo "=== 6. Isolating Repo Build Directories ==="
    if [[ -d "${ROOT_DIR}/Core/target" ]]; then
        HIDDEN_CORE_TARGET="${ROOT_DIR}/Core/.target.verify-hidden.$$"
        mv "${ROOT_DIR}/Core/target" "${HIDDEN_CORE_TARGET}"
    fi
    if [[ -d "${ROOT_DIR}/App/.build" ]]; then
        HIDDEN_APP_BUILD="${ROOT_DIR}/App/.build.verify-hidden.$$"
        mv "${ROOT_DIR}/App/.build" "${HIDDEN_APP_BUILD}"
    fi
fi

echo "=== 7. Launching Relocated Executable Explicitly (DYLD_* Unset) ==="
LAUNCH_LOG="${WORK_DIR}/launch.log"

# Launch the relocated Mach-O executable directly (not via bundle ID or `open`)
# so LaunchServices cannot route execution to any older installed/Downloads bundle.
env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES \
    "${RELOCATED_EXEC}" >"${LAUNCH_LOG}" 2>&1 &
APP_PID=$!

PROC_PATH_ACTUAL="$(swift -e "
import Darwin
let pid = Int32(${APP_PID})
var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
let len = proc_pidpath(pid, &buf, UInt32(buf.count))
if len > 0 {
    print(String(cString: buf))
} else {
    exit(1)
}
" 2>/dev/null || true)"

if [[ -n "${PROC_PATH_ACTUAL}" && "${PROC_PATH_ACTUAL}" != "${RELOCATED_EXEC}" ]]; then
    echo "Error: Launched PID ${APP_PID} resolved to unexpected executable '${PROC_PATH_ACTUAL}' (expected '${RELOCATED_EXEC}')." >&2
    exit 1
fi

# Wait up to 12 seconds for the actual main workspace window (>= 900x600) to appear.
WINDOW_INFO=""
for _ in $(seq 1 24); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
        echo "Error: Relocated LucidSQLApp (PID ${APP_PID}) exited prematurely!" >&2
        cat "${LAUNCH_LOG}" >&2 || true
        exit 1
    fi

    WINDOW_INFO="$(swift -e "
import CoreGraphics
let pid = Int32(${APP_PID})
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    let layer = w[kCGWindowLayer as String] as? Int ?? -1
    let name = w[kCGWindowName as String] as? String
    let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    let width = bounds[\"Width\"] as? Double ?? 0
    let height = bounds[\"Height\"] as? Double ?? 0
    if layer == 0 && width >= 900 && height >= 600 && (name == nil || name == \"LucidSQL\") {
        print(\"WORKSPACE_WINDOW: name=\\(name ?? \"<hidden>\") width=\\(Int(width)) height=\\(Int(height)) x=\\(Int(bounds[\"X\"] as? Double ?? 0)) y=\\(Int(bounds[\"Y\"] as? Double ?? 0))\")
        exit(0)
    }
}
exit(1)
" 2>/dev/null || true)"
    if [[ -n "${WINDOW_INFO}" ]]; then
        break
    fi
    sleep 0.5
done

if ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "Error: Relocated LucidSQLApp failed to stay alive (PID ${APP_PID})." >&2
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

if [[ -z "${WINDOW_INFO}" ]]; then
    echo "Error: Main workspace window (layer 0, >= 900x600) did not appear for PID ${APP_PID}. Windows observed:" >&2
    swift -e "
import CoreGraphics
let pid = Int32(${APP_PID})
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
    print(\"  window:\", \"layer=\", w[kCGWindowLayer as String] ?? -1, \"name=\", w[kCGWindowName as String] ?? \"nil\", \"bounds=\", w[kCGWindowBounds as String] ?? [:])
}
" >&2 || true
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

# Confirm the process remains alive for an additional 2 seconds after workspace appearance.
sleep 2
if ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "Error: Relocated LucidSQLApp (PID ${APP_PID}) crashed shortly after startup!" >&2
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

PROC_PATH_ACTUAL="$(swift -e "
import Darwin
let pid = Int32(${APP_PID})
var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
let len = proc_pidpath(pid, &buf, UInt32(buf.count))
if len > 0 {
    print(String(cString: buf))
} else {
    exit(1)
}
")"
if [[ "${PROC_PATH_ACTUAL}" != "${RELOCATED_EXEC}" ]]; then
    echo "Error: Running PID ${APP_PID} executable '${PROC_PATH_ACTUAL}' does not match '${RELOCATED_EXEC}'." >&2
    exit 1
fi

LOADED_DYLIB_PATHS="$(lsof -Fn -p "${APP_PID}" 2>/dev/null | sed -n 's/^n//p' | grep 'liblucidsql_core\.dylib$' | sort -u || true)"
if [[ "${LOADED_DYLIB_PATHS}" != "${RELOCATED_DYLIB}" ]]; then
    echo "Error: Loaded liblucidsql_core.dylib mismatch for PID ${APP_PID}!" >&2
    echo "  Expected: ${RELOCATED_DYLIB}" >&2
    echo "  Actual:   ${LOADED_DYLIB_PATHS:-<none>}" >&2
    exit 1
fi

echo "=== Verification Provenance Summary ==="
echo "Commit:               ${APP_COMMIT}"
echo "Version / Build:      ${APP_VERSION} (${APP_BUILD})"
echo "DMG SHA-256:          ${DMG_SHA256}"
echo "Executable UUID:      ${EXEC_UUID}"
echo "Executable SHA-256:   ${EXEC_SHA256}"
echo "Dylib UUID:           ${DYLIB_UUID}"
echo "Dylib SHA-256:        ${DYLIB_SHA256}"
echo "Launched Executable:  ${PROC_PATH_ACTUAL} (PID ${APP_PID})"
echo "Loaded Rust Dylib:    ${LOADED_DYLIB_PATHS}"
echo "${WINDOW_INFO}"
echo "=== DMG Verification Passed! Relocated app stayed alive with main workspace window. ==="

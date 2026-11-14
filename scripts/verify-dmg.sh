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

if [[ -f "${DMG_ABS}.sha256" ]]; then
    echo "=== 1. Verifying DMG Checksum ==="
    (cd "${DMG_DIR}" && shasum -a 256 -c "${DMG_BASE}.sha256")
fi

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
OPEN_PID=""

cleanup() {
    set +e
    if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
        kill "${APP_PID}" 2>/dev/null || true
        sleep 1
        kill -9 "${APP_PID}" 2>/dev/null || true
    fi
    if [[ -n "${OPEN_PID}" ]] && kill -0 "${OPEN_PID}" 2>/dev/null; then
        kill "${OPEN_PID}" 2>/dev/null || true
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

echo "=== 5. Verifying Relocated Bundle Signature & Mach-O Linkage ==="
codesign --verify --deep --strict --verbose=2 "${RELOCATED_APP}"
verify_bundle_macho "${RELOCATED_APP}"
if [[ "${REQUIRE_LIQUID_GLASS}" == "true" ]]; then
    verify_liquid_glass_symbols "${RELOCATED_APP}/Contents/MacOS/LucidSQLApp"
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

echo "=== 7. Launching Relocated LucidSQL.app via LaunchServices (DYLD_* Unset) ==="
LAUNCH_LOG="${WORK_DIR}/launch.log"
RELOCATED_EXEC="${RELOCATED_APP}/Contents/MacOS/LucidSQLApp"

env -u DYLD_LIBRARY_PATH -u DYLD_FRAMEWORK_PATH -u DYLD_FALLBACK_LIBRARY_PATH -u DYLD_INSERT_LIBRARIES \
    open -n -W --stdout "${LAUNCH_LOG}" --stderr "${LAUNCH_LOG}" "${RELOCATED_APP}" &
OPEN_PID=$!

# Wait up to 10 seconds for the process to launch and present an on-screen window.
WINDOW_FOUND="false"
for _ in $(seq 1 20); do
    if [[ -z "${APP_PID}" ]]; then
        APP_PID="$(pgrep -f "${RELOCATED_EXEC}" | head -n 1 || true)"
    fi

    if [[ -n "${APP_PID}" ]]; then
        if ! kill -0 "${APP_PID}" 2>/dev/null; then
            echo "Error: Relocated LucidSQLApp (PID ${APP_PID}) exited prematurely!" >&2
            cat "${LAUNCH_LOG}" >&2 || true
            exit 1
        fi

        if swift -e "
import CoreGraphics
let pid = Int32(${APP_PID})
let list = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
let match = list.first {
    (\$0[kCGWindowOwnerPID as String] as? Int32) == pid &&
    (\$0[kCGWindowLayer as String] as? Int) == 0 &&
    ((\$0[kCGWindowBounds as String] as? [String: Any])?[\"Width\"] as? Double ?? 0) > 0
}
if let match {
    print(\"WINDOW_DETECTED:\", match[kCGWindowBounds as String] ?? \"ok\")
    exit(0)
}
exit(1)
" 2>/dev/null; then
            WINDOW_FOUND="true"
            break
        fi
    elif ! kill -0 "${OPEN_PID}" 2>/dev/null; then
        echo "Error: 'open -n -W' exited before LucidSQLApp became active!" >&2
        cat "${LAUNCH_LOG}" >&2 || true
        wait "${OPEN_PID}" || true
        exit 1
    fi
    sleep 0.5
done

if [[ -z "${APP_PID}" ]] || ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "Error: Relocated LucidSQLApp failed to start or stay alive." >&2
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

# Confirm the process remains alive for an additional 2 seconds after launch.
sleep 2
if ! kill -0 "${APP_PID}" 2>/dev/null; then
    echo "Error: Relocated LucidSQLApp (PID ${APP_PID}) crashed shortly after startup!" >&2
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

echo "Process stayed alive (PID ${APP_PID}). Checking loaded dylib path:"
if command -v lsof >/dev/null 2>&1; then
    lsof -p "${APP_PID}" 2>/dev/null | grep "liblucidsql_core.dylib" || true
fi

if [[ "${WINDOW_FOUND}" != "true" ]]; then
    echo "Error: Relocated LucidSQLApp stayed alive (PID ${APP_PID}) but no layer-0 on-screen window was detected." >&2
    cat "${LAUNCH_LOG}" >&2 || true
    exit 1
fi

echo "=== DMG Verification Passed! Relocated app stayed alive with an active window. ==="

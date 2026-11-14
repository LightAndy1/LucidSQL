#!/usr/bin/env bash
# Shared Mach-O dependency, rpath, and Liquid Glass verification helpers for LucidSQL.app.

extract_macho_deps() {
    local macho="$1"
    otool -l "${macho}" | awk '
        /cmd (LC_LOAD_DYLIB|LC_LOAD_WEAK_DYLIB|LC_REEXPORT_DYLIB|LC_LAZY_LOAD_DYLIB)$/ { in_dep = 1; next }
        /cmd / { in_dep = 0 }
        in_dep && /^[[:space:]]*name / {
            sub(/^[[:space:]]*name /, "")
            sub(/ \(offset [0-9]+\)$/, "")
            print
            in_dep = 0
        }
    '
}

extract_macho_rpaths() {
    local macho="$1"
    otool -l "${macho}" | awk '
        /cmd LC_RPATH$/ { in_rpath = 1; next }
        /cmd / { in_rpath = 0 }
        in_rpath && /^[[:space:]]*path / {
            sub(/^[[:space:]]*path /, "")
            sub(/ \(offset [0-9]+\)$/, "")
            print
            in_rpath = 0
        }
    '
}

canonicalize_existing_path() {
    local target="$1"
    local dir base
    dir="$(cd "$(dirname "${target}")" 2>/dev/null && pwd -P)" || return 1
    base="$(basename "${target}")"
    printf '%s/%s\n' "${dir}" "${base}"
}

is_allowed_system_dylib() {
    local dep="$1"
    case "${dep}" in
        /System/Library/Frameworks/*|/System/Library/PrivateFrameworks/*)
            return 0
            ;;
        /usr/lib/local/*)
            return 1
            ;;
        /usr/lib/*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

is_allowed_rpath() {
    local rp="$1"
    case "${rp}" in
        @executable_path/*|@loader_path|@loader_path/*|/usr/lib/swift)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

resolve_rpath_entry() {
    local rp="$1"
    local loader="$2"
    local bundle_exec_dir="$3"
    local loader_dir
    loader_dir="$(dirname "${loader}")"

    case "${rp}" in
        @executable_path)
            printf '%s\n' "${bundle_exec_dir}"
            ;;
        @executable_path/*)
            printf '%s/%s\n' "${bundle_exec_dir}" "${rp#@executable_path/}"
            ;;
        @loader_path)
            printf '%s\n' "${loader_dir}"
            ;;
        @loader_path/*)
            printf '%s/%s\n' "${loader_dir}" "${rp#@loader_path/}"
            ;;
        *)
            printf '%s\n' "${rp}"
            ;;
    esac
}

resolve_in_bundle_dep() {
    local dep="$1"
    local loader="$2"
    local bundle_dir="$3"
    local bundle_exec="$4"
    local bundle_exec_dir
    bundle_exec_dir="$(dirname "${bundle_exec}")"

    local candidate=""
    case "${dep}" in
        @executable_path/*)
            candidate="${bundle_exec_dir}/${dep#@executable_path/}"
            if [[ -f "${candidate}" ]]; then
                canonicalize_existing_path "${candidate}"
                return 0
            fi
            return 1
            ;;
        @loader_path/*)
            candidate="$(dirname "${loader}")/${dep#@loader_path/}"
            if [[ -f "${candidate}" ]]; then
                canonicalize_existing_path "${candidate}"
                return 0
            fi
            return 1
            ;;
        @rpath/*)
            local rel="${dep#@rpath/}"
            local rp resolved_rp
            local rpaths=()
            while IFS= read -r rp; do
                [[ -n "${rp}" ]] && rpaths+=("${rp}")
            done < <(extract_macho_rpaths "${loader}")
            if [[ "${loader}" != "${bundle_exec}" ]]; then
                while IFS= read -r rp; do
                    [[ -n "${rp}" ]] && rpaths+=("${rp}")
                done < <(extract_macho_rpaths "${bundle_exec}")
            fi
            for rp in "${rpaths[@]:-}"; do
                [[ -z "${rp}" ]] && continue
                resolved_rp="$(resolve_rpath_entry "${rp}" "${loader}" "${bundle_exec_dir}")"
                candidate="${resolved_rp}/${rel}"
                if [[ -f "${candidate}" ]]; then
                    local canon
                    canon="$(canonicalize_existing_path "${candidate}")" || continue
                    if [[ "${canon}" == "${bundle_dir}/"* ]]; then
                        printf '%s\n' "${canon}"
                        return 0
                    fi
                fi
            done
            return 1
            ;;
        *)
            return 1
            ;;
    esac
}

verify_bundle_macho() {
    local raw_bundle_dir="$1"
    if [[ ! -d "${raw_bundle_dir}" ]]; then
        echo "Error: Bundle directory does not exist: ${raw_bundle_dir}" >&2
        return 1
    fi

    local bundle_dir
    bundle_dir="$(cd "${raw_bundle_dir}" && pwd -P)"
    local bundle_exec="${bundle_dir}/Contents/MacOS/LucidSQLApp"
    local bundle_dylib="${bundle_dir}/Contents/Frameworks/liblucidsql_core.dylib"

    if [[ ! -f "${bundle_exec}" ]]; then
        echo "Error: Missing executable in bundle: ${bundle_exec}" >&2
        return 1
    fi
    if [[ ! -f "${bundle_dylib}" ]]; then
        echo "Error: Missing embedded Rust dylib in bundle: ${bundle_dylib}" >&2
        return 1
    fi

    local dylib_id
    dylib_id="$(otool -D "${bundle_dylib}" | tail -n +2 | tr -d '[:space:]')"
    if [[ "${dylib_id}" != "@rpath/liblucidsql_core.dylib" ]]; then
        echo "Error: Unexpected LC_ID_DYLIB on ${bundle_dylib}: '${dylib_id}' (expected '@rpath/liblucidsql_core.dylib')" >&2
        return 1
    fi

    local exec_has_core="false"
    while IFS= read -r dep; do
        if [[ "${dep}" == "@rpath/liblucidsql_core.dylib" ]]; then
            exec_has_core="true"
        fi
    done < <(extract_macho_deps "${bundle_exec}")
    if [[ "${exec_has_core}" != "true" ]]; then
        echo "Error: ${bundle_exec} does not reference @rpath/liblucidsql_core.dylib" >&2
        return 1
    fi

    local exec_has_fw_rpath="false"
    while IFS= read -r rp; do
        if [[ "${rp}" == "@executable_path/../Frameworks" ]]; then
            exec_has_fw_rpath="true"
        fi
    done < <(extract_macho_rpaths "${bundle_exec}")
    if [[ "${exec_has_fw_rpath}" != "true" ]]; then
        echo "Error: ${bundle_exec} is missing LC_RPATH '@executable_path/../Frameworks'" >&2
        return 1
    fi

    local queue=()
    local visited=()
    local f
    while IFS= read -r f; do
        if file -b "${f}" | grep -q "Mach-O"; then
            queue+=("$(canonicalize_existing_path "${f}")")
        fi
    done < <(find "${bundle_dir}" -type f | sort)

    if [[ ${#queue[@]} -eq 0 ]]; then
        echo "Error: No Mach-O binaries found inside ${bundle_dir}" >&2
        return 1
    fi

    local idx=0
    while [[ ${idx} -lt ${#queue[@]} ]]; do
        local current="${queue[${idx}]}"
        idx=$((idx + 1))

        local already="false"
        for v in "${visited[@]:-}"; do
            if [[ "${v}" == "${current}" ]]; then
                already="true"
                break
            fi
        done
        if [[ "${already}" == "true" ]]; then
            continue
        fi
        visited+=("${current}")

        local archs
        archs="$(lipo -archs "${current}")"
        if [[ "${archs}" != "arm64" ]]; then
            echo "Error: Expected arm64-only Mach-O for ${current}, got '${archs}'" >&2
            return 1
        fi

        if file -b "${current}" | grep -q "dynamically linked shared library"; then
            local id_line
            id_line="$(otool -D "${current}" | tail -n +2)"
            if [[ "${id_line}" != @rpath/* && "${id_line}" != @executable_path/* && "${id_line}" != @loader_path/* ]]; then
                echo "Error: Non-relocatable LC_ID_DYLIB '${id_line}' on ${current}" >&2
                return 1
            fi
        fi

        local rp
        while IFS= read -r rp; do
            [[ -z "${rp}" ]] && continue
            if ! is_allowed_rpath "${rp}"; then
                echo "Error: Disallowed LC_RPATH '${rp}' on ${current}" >&2
                return 1
            fi
        done < <(extract_macho_rpaths "${current}")

        local dep
        while IFS= read -r dep; do
            [[ -z "${dep}" ]] && continue
            if is_allowed_system_dylib "${dep}"; then
                continue
            fi
            if [[ "${dep}" == @rpath/* || "${dep}" == @executable_path/* || "${dep}" == @loader_path/* ]]; then
                local resolved
                if ! resolved="$(resolve_in_bundle_dep "${dep}" "${current}" "${bundle_dir}" "${bundle_exec}")"; then
                    echo "Error: Unresolved in-bundle dependency '${dep}' referenced from ${current}" >&2
                    return 1
                fi
                queue+=("${resolved}")
            else
                echo "Error: Disallowed non-system / build-machine dependency '${dep}' referenced from ${current}" >&2
                return 1
            fi
        done < <(extract_macho_deps "${current}")
    done

    echo "Mach-O verification passed (${#visited[@]} bundled Mach-O binaries inspected recursively)."
}

verify_liquid_glass_symbols() {
    local exec_path="$1"
    if [[ ! -f "${exec_path}" ]]; then
        echo "Error: Executable not found for Liquid Glass verification: ${exec_path}" >&2
        return 1
    fi

    local undef_syms
    undef_syms="$(nm -u "${exec_path}")"

    if ! printf '%s\n' "${undef_syms}" | grep -q '_OBJC_CLASS_\$_NSGlassEffectView'; then
        echo "Error: Liquid Glass _OBJC_CLASS_\$_NSGlassEffectView symbol missing from ${exec_path}. Built with an older SDK/compiler?" >&2
        return 1
    fi

    if ! printf '%s\n' "${undef_syms}" | grep -q 'GlassButtonStyle'; then
        echo "Error: Liquid Glass SwiftUI GlassButtonStyle symbol missing from ${exec_path}." >&2
        return 1
    fi

    if ! printf '%s\n' "${undef_syms}" | grep -q 'GlassProminentButtonStyle'; then
        echo "Error: Liquid Glass SwiftUI GlassProminentButtonStyle symbol missing from ${exec_path}." >&2
        return 1
    fi

    if ! printf '%s\n' "${undef_syms}" | grep -q 'glassEffect'; then
        echo "Error: Liquid Glass SwiftUI glassEffect symbol missing from ${exec_path}." >&2
        return 1
    fi

    echo "Liquid Glass symbol check passed (NSGlassEffectView, GlassButtonStyle, GlassProminentButtonStyle, glassEffect present)."
}

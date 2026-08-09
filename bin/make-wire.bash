#!/usr/bin/env bash

# dia:begin wire/make-wire.bash

#!/usr/bin/env bash
# ---
# description: >-
#   Unified wire: reads config/wire.ini from the target repo (sidecar).
#   Each [mount.<strategy>] or [mount.<strategy>.<label>] has
#   from/root/mode/require[/depth/skip]; strategy is the first dotted segment
#   (lib|libexec|home|rootfs|tex|bin|sbin). require=exists skips missing from=;
#   ${WIRE_HOST} defaults to hostname -s (per-device overlays).
#   depth=N (bin/sbin): package name is the Nth path segment under from=;
#   leaf dir is the strategy (…/<pkg>/bin). skip=comma-list of package names.
#   mount.bin / mount.sbin install PATH stubs (WIRE_* + libexec prepend + exec).
#   In-tree: direnv .envrc sets the same WIRE_* vars (see WIRING.md / templates/envrc).
# ---
#
# Usage: make-wire.bash [mount_name] [repo_dir]
# Env:   WIRE_MODE overrides ini mode for all selected mounts.
#        WIRE_HOST selects device overlay paths in from=.

# ---

set -o errexit
set -o nounset
set -o pipefail

mount_filter="${1:-}"
repo_dir="${2:-}"

if [ -n "${mount_filter}" ] && [ -d "${mount_filter}" ] && [ -z "${repo_dir}" ]; then
    # make-wire.bash /path/to/repo
    repo_dir="${mount_filter}"
    mount_filter=""
fi

if [ -z "${repo_dir}" ]; then
    repo_dir="$(git rev-parse --show-toplevel 2> /dev/null || true)"
fi
if [ -z "${repo_dir}" ] || [ ! -d "${repo_dir}" ]; then
    printf 'Not inside a git repo (pass repo_dir)\n' >&2
    exit 1
fi
repo_dir="$(realpath "${repo_dir}")"
pkg="$(basename "${repo_dir}")"

wire_ini="${repo_dir}/config/wire.ini"
if [ ! -f "${wire_ini}" ]; then
    printf 'Missing %s — add config/wire.ini to this repo\n' "${wire_ini}" >&2
    exit 1
fi

local_home="${MY_LOCAL_HOME:-${HOME}/.local}"

# Defaults must be set in the main shell: expand_vars runs in $(…), so
# exports inside it would not stick for later mounts / messages.
ensure_wire_defaults() {
    if [ -z "${TEXMFHOME:-}" ] && command -v kpsewhich > /dev/null 2>&1; then
        TEXMFHOME="$(kpsewhich -var-value=TEXMFHOME 2> /dev/null || true)"
        export TEXMFHOME
    fi
    if [ -z "${MY_LOCAL_HOME:-}" ]; then
        MY_LOCAL_HOME="${HOME}/.local"
        export MY_LOCAL_HOME
    fi
    if [ -z "${WIRE_HOST:-}" ]; then
        WIRE_HOST="$(hostname -s 2> /dev/null || hostname 2> /dev/null || printf 'localhost')"
        export WIRE_HOST
    fi
    local_home="${MY_LOCAL_HOME}"
}

expand_vars() {
    local s="${1}"
    while [[ "${s}" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^\}]*))?\} ]]; do
        local name="${BASH_REMATCH[1]}"
        local def="${BASH_REMATCH[3]}"
        local val="${!name-}"
        if [ -z "${val}" ]; then
            val="${def}"
        fi
        s="${s/\$\{${BASH_REMATCH[1]}${BASH_REMATCH[2]}\}/${val}}"
    done
    while [[ "${s}" =~ \$([A-Za-z_][A-Za-z0-9_]*) ]]; do
        local name="${BASH_REMATCH[1]}"
        local val="${!name-}"
        s="${s/\$${name}/${val}}"
    done
    printf '%s' "${s}"
}

# Resolve a wire.ini value shell-like: strip one pair of matching outer
# quotes; '…' stays literal (no ${…} expansion), "…" and bare expand.
# Writers always brace named parameters (${NAME}); bare $NAME is still
# expanded here only for compatibility with older wire.ini files.
resolve_wire_value() {
    local val="${1}"
    local expand=1
    case "${val}" in
        \"*\")
            val="${val#\"}"
            val="${val%\"}"
            ;;
        \'*\')
            val="${val#\'}"
            val="${val%\'}"
            expand=0
            ;;
    esac
    if [ "${expand}" -eq 1 ]; then
        expand_vars "${val}"
    else
        printf '%s' "${val}"
    fi
}

decode_hash_name() {
    sed -e 's:^_:.:' -e 's:##: :g' -e 's:#:/:g' -e 's:_\..*$::'
}

materialise() {
    local src="${1}"
    local dest="${2}"
    local mode="${3}"
    local require="${4:-}"
    mkdir -p "$(dirname "${dest}")"
    case "${mode}" in
        symlink)
            # Replace prior wire stubs (generated wrappers) and symlinks.
            if [ -L "${dest}" ] || [ -f "${dest}" ]; then
                rm -f -- "${dest}"
            elif [ -e "${dest}" ]; then
                printf 'Path already occupied: %s\n' "${dest}" >&2
                exit 1
            fi
            ln -sfn "${src}" "${dest}"
            printf 'symlinked %s -> %s\n' "${dest}" "${src}"
            ;;
        copy)
            if [ -e "${dest}" ] || [ -L "${dest}" ]; then
                rm -rf -- "${dest}"
            fi
            cp -R "${src}" "${dest}"
            if [ "${require}" = "root" ]; then
                chown -R root:wheel "${dest}" 2> /dev/null || chown -R root:root "${dest}"
            fi
            printf 'copied %s <- %s\n' "${dest}" "${src}"
            ;;
        *)
            printf 'mode must be symlink or copy (got %s)\n' "${mode}" >&2
            exit 1
            ;;
    esac
}

write_bin_wrapper() {
    # Thin PATH stub: export package roots for sourced libs, prepend libexec
    # (package + optional shared logging), then exec the real script.
    local src_abs dest libexec_dir lib_dir wire_root shared_libexec path_prefix
    src_abs="$(realpath "${1}")"
    dest="${2}"
    libexec_dir="${3}"
    lib_dir="${4}"
    wire_root="${5}"
    shared_libexec="${6:-}"
    mkdir -p "$(dirname "${dest}")"
    if [ -L "${dest}" ] || [ -f "${dest}" ]; then
        rm -f -- "${dest}"
    elif [ -e "${dest}" ]; then
        printf 'Path already occupied: %s\n' "${dest}" >&2
        exit 1
    fi
    path_prefix="\${WIRE_LIBEXEC}"
    if [ -n "${shared_libexec}" ]; then
        path_prefix="\${WIRE_LIBEXEC}:\${WIRE_LIBEXEC_SHARED}"
    fi
    cat > "${dest}" <<EOF
#!/bin/sh
# Generated by make-wire — do not edit.
WIRE_ROOT="${wire_root}"
WIRE_LIB="${lib_dir}"
WIRE_LIBEXEC="${libexec_dir}"
EOF
    if [ -n "${shared_libexec}" ]; then
        cat >> "${dest}" <<EOF
WIRE_LIBEXEC_SHARED="${shared_libexec}"
PATH="${path_prefix}:\${PATH}"
export WIRE_ROOT WIRE_LIB WIRE_LIBEXEC WIRE_LIBEXEC_SHARED PATH
EOF
    else
        cat >> "${dest}" <<EOF
PATH="${path_prefix}:\${PATH}"
export WIRE_ROOT WIRE_LIB WIRE_LIBEXEC PATH
EOF
    fi
    cat >> "${dest}" <<EOF
exec "${src_abs}" "\$@"
EOF
    chmod a+x "${dest}"
    if [ -n "${shared_libexec}" ]; then
        printf 'wrapped %s -> %s (lib %s libexec %s shared %s)\n' \
            "${dest}" "${src_abs}" "${lib_dir}" "${libexec_dir}" "${shared_libexec}"
    else
        printf 'wrapped %s -> %s (lib %s libexec %s)\n' \
            "${dest}" "${src_abs}" "${lib_dir}" "${libexec_dir}"
    fi
}

wire_resolve_shared_libexec() {
    # Repo-wide helpers (e.g. log-*): src/wire/logging/libexec → …/libexec/logging
    # Multi-tool repos use this once — never copy into every capsule.
    if [ -d "${repo_dir}/src/wire/logging/libexec" ]; then
        printf '%s\n' "${local_home}/libexec/logging"
        return 0
    fi
    return 1
}

# Resolve helper PATH dir for a package label (repo basename or mount.bin.<label>).
# Capsules: src/wire/<label>/libexec → ~/.local/libexec/<label>
wire_ini_libexec_root() {
    # Declared [mount.libexec.<label>] root= wins. mounts_tmp is filled before
    # any mount runs, so order of bin vs libexec is irrelevant.
    local label="${1}" name from root mode require depth skip
    [ -n "${label}" ] || return 1
    [ -f "${mounts_tmp:-}" ] || return 1
    while IFS=$'\x1f' read -r name from root mode require depth skip; do
        [ "${name}" = "libexec.${label}" ] || continue
        [ -n "${root}" ] || return 1
        ensure_wire_defaults
        printf '%s\n' "$(resolve_wire_value "${root}")"
        return 0
    done < "${mounts_tmp}"
    return 1
}

wire_resolve_libexec() {
    # 1) Explicit mount.libexec.<label> root=
    # 2) Capsule src/wire/<label>/libexec → flat ~/.local/libexec/<label>
    # 3) Leftover hash src/wire/<label>/_local#libexec#…
    # 4) Flat ${MY_LOCAL_HOME}/libexec/<label>
    local label="${1}"
    local capsule node dest declared
    if declared="$(wire_ini_libexec_root "${label}")"; then
        printf '%s\n' "${declared}"
        return 0
    fi
    capsule="${repo_dir}/src/wire/${label}"
    if [ -d "${capsule}/libexec" ]; then
        printf '%s\n' "${local_home}/libexec/${label}"
        return 0
    fi
    if [ -d "${capsule}" ]; then
        for node in "${capsule}"/_local#libexec#*; do
            [ -e "${node}" ] || continue
            dest="${HOME}/$(printf '%s' "$(basename "${node}")" | decode_hash_name)"
            printf '%s\n' "${dest}"
            return 0
        done
    fi
    printf '%s\n' "${local_home}/libexec/${label}"
}

# --- strategies (use mount_* globals) ---

wire_bin_publish() {
    # Publish files from one directory as PATH stubs for wire_pkg.
    local src_dir="${1}"
    local wire_pkg="${2}"
    local src base name dest libexec_dir lib_dir target_src shared_libexec
    mkdir -p "${root_path}"
    lib_dir="${local_home}/lib/${wire_pkg}"
    libexec_dir="$(wire_resolve_libexec "${wire_pkg}")"
    shared_libexec=""
    shared_libexec="$(wire_resolve_shared_libexec)" || shared_libexec=""

    if [ -f "${src_dir}" ]; then
        set -- "${src_dir}"
    elif [ -d "${src_dir}" ]; then
        set -- "${src_dir}"/*
    else
        return 0
    fi

    for src in "$@"; do
        [ -e "${src}" ] || continue
        [ -f "${src}" ] || continue
        base="$(basename "${src}")"
        case "${base}" in
            make-* | .* | *.awk | *.md | *.txt) continue ;;
        esac
        chmod a+x "${src}" 2> /dev/null || true
        name="${base%.*}"
        [ -n "${name}" ] || continue
        dest="${root_path}/${name}"
        target_src="${src}"
        if [ "${mount_mode}" = "copy" ]; then
            target_src="${root_path}/.wire-src/${name}${base#"${name}"}"
            mkdir -p "$(dirname "${target_src}")"
            cp -f "${src}" "${target_src}"
            chmod a+x "${target_src}"
        fi
        write_bin_wrapper "${target_src}" "${dest}" "${libexec_dir}" \
            "${lib_dir}" "${repo_dir}" "${shared_libexec}"
    done
}

wire_pkg_skipped() {
    # True if package name is listed in mount_skip (comma-separated).
    local wire_pkg="${1}"
    local item
    [ -n "${mount_skip:-}" ] || return 1
    local IFS=','
    # shellcheck disable=SC2086
    for item in ${mount_skip}; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [ "${item}" = "${wire_pkg}" ] && return 0
    done
    return 1
}

wire_bin() {
    # Public CLIs → root/ as stem without extension (PATH stubs).
    # depth=0 (default): files directly under from=.
    # depth=N: each …/<pkg>/bin under from (pkg at depth N); skip= hosts,root,…
    # Labeled mounts (mount.bin.gnupg) set mount_label and usually depth=0.
    local wire_pkg depth leaf_depth leaf_dir
    depth="${mount_depth:-0}"
    case "${depth}" in
        '' | *[!0-9]*) depth=0 ;;
    esac

    if [ "${depth}" -eq 0 ]; then
        wire_pkg="${pkg}"
        if [ -n "${mount_label:-}" ]; then
            wire_pkg="${mount_label}"
        fi
        if [ ! -e "${from_path}" ]; then
            printf 'Missing %s\n' "${from_path}" >&2
            exit 1
        fi
        wire_bin_publish "${from_path}" "${wire_pkg}"
        return 0
    fi

    leaf_depth=$((depth + 1))
    while IFS= read -r -d '' leaf_dir; do
        wire_pkg="$(basename "$(dirname "${leaf_dir}")")"
        if [ "${depth}" -gt 1 ]; then
            # Package name = path component at depth under from_path.
            wire_pkg="$(printf '%s' "${leaf_dir#"${from_path}"/}" | cut -d/ -f"${depth}")"
        fi
        wire_pkg_skipped "${wire_pkg}" && continue
        wire_bin_publish "${leaf_dir}" "${wire_pkg}"
    done < <(find -L "${from_path}" -mindepth "${leaf_depth}" \
        -maxdepth "${leaf_depth}" -type d -name bin -print0 2> /dev/null)
}

wire_sbin() {
    # Same as wire_bin, but leaf directory name is sbin when depth>=1.
    local wire_pkg depth leaf_depth leaf_dir
    depth="${mount_depth:-0}"
    case "${depth}" in
        '' | *[!0-9]*) depth=0 ;;
    esac

    if [ "${depth}" -eq 0 ]; then
        wire_pkg="${pkg}"
        if [ -n "${mount_label:-}" ]; then
            wire_pkg="${mount_label}"
        fi
        if [ ! -e "${from_path}" ]; then
            printf 'Missing %s\n' "${from_path}" >&2
            exit 1
        fi
        wire_bin_publish "${from_path}" "${wire_pkg}"
        return 0
    fi

    leaf_depth=$((depth + 1))
    while IFS= read -r -d '' leaf_dir; do
        wire_pkg="$(basename "$(dirname "${leaf_dir}")")"
        if [ "${depth}" -gt 1 ]; then
            wire_pkg="$(printf '%s' "${leaf_dir#"${from_path}"/}" | cut -d/ -f"${depth}")"
        fi
        wire_pkg_skipped "${wire_pkg}" && continue
        wire_bin_publish "${leaf_dir}" "${wire_pkg}"
    done < <(find -L "${from_path}" -mindepth "${leaf_depth}" \
        -maxdepth "${leaf_depth}" -type d -name sbin -print0 2> /dev/null)
}

wire_lib() {
    # Sourced libraries only (bootstrap, prelude, wire-path, importable modules).
    # Flat: from/<file> → root/<stem>. Also hash nodes _local#lib#* (dotfiles).
    # Not for executables — those belong in mount.libexec.
    local DST_PARENT="${root_path}"
    local src_root="${from_path}"
    local WIRE_MODE="${mount_mode}"

    decode_local_node() {
        local f="${1}"
        f="${f/#_/.}"
        f="${f//##/ }"
        f="${f//#//}"
        f="${f%%_.*}"
        printf '%s/%s\n' "${DST_PARENT}" "${f}"
    }

    stem_name() {
        local base
        base="$(basename "${1}")"
        case "${base}" in
            *.*) printf '%s\n' "${base%.*}" ;;
            *) printf '%s\n' "${base}" ;;
        esac
    }

    public_name_for() {
        # Keep basename (incl. extension): sourced files collide if both
        # prelude.sh and prelude.bash were stemmed to "prelude".
        local src="${1}"
        if [[ "${src}" == */main.* ]]; then
            basename "$(dirname "${src}")"
        else
            basename "${src}"
        fi
    }

    install_stem_link() {
        local src="${1}"
        local dest="${2}"
        mkdir -p "$(dirname "${dest}")"
        if [ -L "${dest}" ] || [ -f "${dest}" ]; then
            rm -f -- "${dest}"
        elif [ -e "${dest}" ]; then
            printf 'Path already occupied: %s\n' "${dest}" >&2
            exit 1
        fi
        case "${WIRE_MODE}" in
            symlink)
                ln -sfn "${src}" "${dest}"
                printf 'symlinked %s -> %s\n' "${dest}" "${src}"
                ;;
            copy)
                cp -f "${src}" "${dest}"
                chmod 644 "${dest}" 2> /dev/null || true
                printf 'copied %s <- %s\n' "${dest}" "${src}"
                ;;
        esac
    }

    [ -d "${src_root}" ] || {
        printf 'Missing %s\n' "${src_root}" >&2
        exit 1
    }

    materialise_leaf() {
        local src_dir="${1}"
        local dest_dir="${2}"
        local src name
        if [ -L "${dest_dir}" ]; then
            rm -f -- "${dest_dir}"
        fi
        mkdir -p "${dest_dir}"
        find -L "${dest_dir}" -maxdepth 1 \( -type l -o -type f \) -print0 2> /dev/null |
            xargs -0 rm -f -- 2> /dev/null || :
        for src in "${src_dir}"/* "${src_dir}"/*/main.*; do
            [ -f "${src}" ] || continue
            case "$(basename "${src}")" in
                __pycache__ | *.pyc) continue ;;
            esac
            name="$(public_name_for "${src}")"
            install_stem_link "${src}" "${dest_dir}/${name}"
        done
    }

    local has_flat=0
    local f
    for f in "${src_root}"/*; do
        [ -f "${f}" ] || continue
        case "$(basename "${f}")" in
            __pycache__ | *.pyc) continue ;;
        esac
        has_flat=1
        break
    done
    if [ "${has_flat}" -eq 1 ]; then
        materialise_leaf "${src_root}" "${root_path}"
    fi

    local lib_nodes=()
    local src_node
    for src_node in "${src_root}"/_local#lib#*; do
        [ -e "${src_node}" ] || continue
        lib_nodes+=("${src_node}")
    done
    # Leftover hash under capsules: <from>/<pkg>/_local#lib#*
    for src_node in "${src_root}"/*/_local#lib#*; do
        [ -e "${src_node}" ] || continue
        lib_nodes+=("${src_node}")
    done

    local base_node dest
    for src_node in "${lib_nodes[@]+"${lib_nodes[@]}"}"; do
        base_node="$(basename "${src_node}")"
        dest="$(decode_local_node "${base_node}")"
        if [ -d "${src_node}" ]; then
            materialise_leaf "${src_node}" "${dest}"
        else
            materialise "${src_node}" "${dest}" "${WIRE_MODE}" ""
        fi
    done

    # Capsule lib/: src/wire/<pkg>/lib → ~/.local/lib/<pkg>
    local pkg_lib pkg
    for pkg_lib in "${src_root}"/*/lib; do
        [ -d "${pkg_lib}" ] || continue
        pkg="$(basename "$(dirname "${pkg_lib}")")"
        wire_pkg_skipped "${pkg}" && continue
        case "${pkg}" in
            hosts) continue ;;
        esac
        materialise_leaf "${pkg_lib}" "${local_home}/lib/${pkg}"
    done
}

wire_tex() {
    [ -d "${from_path}" ] || {
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
    }
    mkdir -p "${root_path}"
    local pkgdir
    for pkgdir in "${from_path}"/*/; do
        [ -d "${pkgdir}" ] || continue
        materialise "$(realpath "${pkgdir}")" "${root_path}/$(basename "${pkgdir}")" \
            "${mount_mode}" "${mount_require}"
    done
}

wire_home() {
    # Capsules under from/: only slots are wired —
    #   config/ → ~/.config/<pkg>
    #   home/   → hash-decoded children under $HOME (wire-home root)
    # Top-level hash nodes (tool/_foo#…) are rejected — put them in home/.
    [ -d "${from_path}" ] || {
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
    }
    local bak_dir state_home tool_dir tool src_node base dest xdg_config
    state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    mkdir -p "${state_home}/make-wire-home"
    bak_dir="$(mktemp -d "${state_home}/make-wire-home/bak.XXXXXXX")"
    # shellcheck disable=SC2064
    trap "rmdir -- '${bak_dir}' 2>/dev/null || true" RETURN

    install_home_dest() {
        local src="${1}"
        local dest="${2}"
        mkdir -p "$(dirname "${dest}")"
        if [ -L "${dest}" ]; then
            rm -f -- "${dest}"
        elif [ -e "${dest}" ]; then
            mv "${dest}" "${bak_dir}"
        fi
        case "${mount_mode}" in
            symlink)
                ln -sfn "${src}" "${dest}"
                printf 'symlinked %s -> %s\n' "${dest}" "${src}"
                ;;
            copy)
                cp -R "${src}" "${dest}"
                printf 'copied %s <- %s\n' "${dest}" "${src}"
                ;;
        esac
    }

    xdg_config="${XDG_CONFIG_HOME:-${HOME}/.config}"

    for tool_dir in "${from_path}"/*/; do
        [ -d "${tool_dir}" ] || continue
        tool_dir="${tool_dir%/}"
        tool="$(basename "${tool_dir}")"
        wire_pkg_skipped "${tool}" && continue
        case "${tool}" in
            hosts) continue ;;
        esac

        # Reject misplaced top-level hash / library nodes (must live under home/).
        for src_node in "${tool_dir}"/*; do
            [ -e "${src_node}" ] || continue
            base="$(basename "${src_node}")"
            case "${base}" in
                bin | sbin | lib | libexec | config | root | home | .DS_Store | .gitignore | README.md | .luarc.json) continue ;;
            esac
            case "${base}" in
                _* | *\#*)
                    printf 'wire home: %s/%s must live under home/ (slot), not capsule root\n' \
                        "${tool}" "${base}" >&2
                    exit 1
                    ;;
            esac
        done

        if [ -d "${tool_dir}/config" ]; then
            install_home_dest "${tool_dir}/config" "${xdg_config}/${tool}"
        fi

        if [ -d "${tool_dir}/home" ]; then
            for src_node in "${tool_dir}/home"/*; do
                [ -e "${src_node}" ] || continue
                base="$(basename "${src_node}")"
                case "${base}" in
                    .DS_Store | .gitignore) continue ;;
                esac
                case "${base}" in
                    _* | *\#*) ;;
                    *) continue ;; # non-hash helpers (e.g. policies.json) stay unwired
                esac
                dest="${root_path}/$(printf '%s' "${base}" | decode_hash_name)"
                install_home_dest "${src_node}" "${dest}"
            done
        fi
    done
}

wire_rootfs() {
    # Capsule slot root/ → install hash-decoded children under mount root=/
    # (wire root). depth=1: from/<pkg>/root/*; depth=0: from/* are hash nodes
    # (or from/<legacy-group>/*). Tools are sudoers-d / texmf — not a folder
    # named "root" above them.
    [ -d "${from_path}" ] || {
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
    }
    local bak_dir state_home depth leaf_depth root_dir item name dest pkg
    state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    mkdir -p "${state_home}/make-wire-rootfs"
    bak_dir="$(mktemp -d "${state_home}/make-wire-rootfs/bak.XXXXXXX")"
    # shellcheck disable=SC2064
    trap "rmdir -- '${bak_dir}' 2>/dev/null || true" RETURN

    install_rootfs_item() {
        local item="${1}"
        local name dest
        name="$(basename "${item}")"
        case "${name}" in
            .* | .gitignore) return 0 ;;
        esac
        dest="${root_path}/$(printf '%s' "${name}" | decode_hash_name)"
        mkdir -p "$(dirname "${dest}")"
        if [ -e "${dest}" ]; then
            mv "${dest}" "${bak_dir}"
        fi
        cp -R "${item}" "${dest}"
        chown -R root:wheel "${dest}" 2> /dev/null || chown -R root:root "${dest}"
        printf 'copied %s <- %s\n' "${dest}" "${item}"
    }

    depth="${mount_depth:-0}"
    case "${depth}" in
        '' | *[!0-9]*) depth=0 ;;
    esac

    if [ "${depth}" -ge 1 ]; then
        leaf_depth=$((depth + 1))
        while IFS= read -r -d '' root_dir; do
            pkg="$(basename "$(dirname "${root_dir}")")"
            if [ "${depth}" -gt 1 ]; then
                pkg="$(printf '%s' "${root_dir#"${from_path}"/}" | cut -d/ -f"${depth}")"
            fi
            wire_pkg_skipped "${pkg}" && continue
            for item in "${root_dir}"/*; do
                [ -e "${item}" ] || continue
                install_rootfs_item "${item}"
            done
        done < <(find -L "${from_path}" -mindepth "${leaf_depth}" \
            -maxdepth "${leaf_depth}" -type d -name root -print0 2> /dev/null)
        return 0
    fi

    # depth=0: from/ is one root/ tree, or legacy groups under from/
    if [ -d "${from_path}/root" ] && [ "${from_path##*/}" != "root" ]; then
        for item in "${from_path}/root"/*; do
            [ -e "${item}" ] || continue
            install_rootfs_item "${item}"
        done
        return 0
    fi

    for item in "${from_path}"/*; do
        [ -e "${item}" ] || continue
        name="$(basename "${item}")"
        case "${name}" in
            .* | bin | sbin | lib | libexec | config) continue ;;
        esac
        if [ -d "${item}" ] && [[ "${name}" != *\#* && "${name}" != _* ]]; then
            # legacy group dir (old src/wire/root/<tool>/…)
            for nested in "${item}"/*; do
                [ -e "${nested}" ] || continue
                install_rootfs_item "${nested}"
            done
            continue
        fi
        install_rootfs_item "${item}"
    done
}

wire_libexec() {
    # Package-private tree only. Does NOT publish to ~/.local/{bin,sbin} —
    # use mount.bin / mount.sbin for public CLIs (one mount entry per tree).
    local DST_PARENT="${root_path}"
    local src_root="${from_path}"
    local WIRE_MODE="${mount_mode}"

    decode_local_node() {
        local f="${1}"
        f="${f/#_/.}"
        f="${f//##/ }"
        f="${f//#//}"
        f="${f%%_.*}"
        printf '%s/%s\n' "${DST_PARENT}" "${f}"
    }

    stem_name() {
        local base
        base="$(basename "${1}")"
        case "${base}" in
            *.*) printf '%s\n' "${base%.*}" ;;
            *) printf '%s\n' "${base}" ;;
        esac
    }

    public_name_for() {
        local src="${1}"
        local keep_basename="${2:-0}"
        if [[ "${src}" == */main.* ]]; then
            basename "$(dirname "${src}")"
        elif [ "${keep_basename}" -eq 1 ]; then
            # Flat tool-repo helpers: callers invoke with extension.
            basename "${src}"
        else
            stem_name "${src}"
        fi
    }

    install_stem_link() {
        local src="${1}"
        local dest="${2}"
        mkdir -p "$(dirname "${dest}")"
        if [ -L "${dest}" ] || [ -f "${dest}" ]; then
            rm -f -- "${dest}"
        elif [ -e "${dest}" ]; then
            printf 'Path already occupied: %s\n' "${dest}" >&2
            exit 1
        fi
        case "${WIRE_MODE}" in
            symlink)
                ln -sfn "${src}" "${dest}"
                printf 'symlinked %s -> %s\n' "${dest}" "${src}"
                ;;
            copy)
                cp -f "${src}" "${dest}"
                chmod 755 "${dest}"
                printf 'copied %s <- %s\n' "${dest}" "${src}"
                ;;
        esac
    }

    [ -d "${src_root}" ] || {
        printf 'Missing %s\n' "${src_root}" >&2
        exit 1
    }

    materialise_leaf_bin() {
        local src_dir="${1}"
        local dest_dir="${2}"
        local keep_basename="${3:-0}"
        local src name
        if [ -L "${dest_dir}" ]; then
            rm -f -- "${dest_dir}"
        fi
        mkdir -p "${dest_dir}"
        find -L "${dest_dir}" -maxdepth 1 \( -type l -o -type f \) -print0 2> /dev/null |
            xargs -0 rm -f -- 2> /dev/null || :
        for src in "${src_dir}"/* "${src_dir}"/*/main.*; do
            [ -f "${src}" ] || continue
            case "$(basename "${src}")" in
                __pycache__ | *.pyc) continue ;;
            esac
            case "${src}" in
                */extensions/*) continue ;;
            esac
            chmod 755 "${src}"
            name="$(public_name_for "${src}" "${keep_basename}")"
            install_stem_link "${src}" "${dest_dir}/${name}"
        done
    }

    # Flat package helpers: files directly under from/ → root/ (no bin/sbin).
    # Privilege split is only for public mount.bin / mount.sbin.
    # Legacy nested from/{bin,sbin}/ still materialises if present.
    local has_flat=0
    local f
    for f in "${src_root}"/*; do
        [ -f "${f}" ] || continue
        case "$(basename "${f}")" in
            __pycache__ | *.pyc) continue ;;
        esac
        has_flat=1
        break
    done
    if [ "${has_flat}" -eq 1 ]; then
        # keep_basename=1: install as find-filepaths.sh etc.
        materialise_leaf_bin "${src_root}" "${root_path}" 1
    fi

    local leaf
    for leaf in bin sbin; do
        if [ -d "${src_root}/${leaf}" ]; then
            materialise_leaf_bin "${src_root}/${leaf}" "${root_path}/${leaf}"
        fi
    done

    # Nested: leftover hash _local#libexec#* under <from>/<pkg>/
    local libexec_nodes=()
    local src_node
    for src_node in "${src_root}"/_local#libexec#*; do
        [ -e "${src_node}" ] || continue
        libexec_nodes+=("${src_node}")
    done
    for src_node in "${src_root}"/*/_local#libexec#*; do
        [ -e "${src_node}" ] || continue
        libexec_nodes+=("${src_node}")
    done

    local base_node dest
    for src_node in "${libexec_nodes[@]+"${libexec_nodes[@]}"}"; do
        base_node="$(basename "${src_node}")"
        dest="$(decode_local_node "${base_node}")"
        case "${base_node}" in
            *#bin | *#sbin)
                materialise_leaf_bin "${src_node}" "${dest}"
                ;;
            *)
                materialise "${src_node}" "${dest}" "${WIRE_MODE}" ""
                if [ -d "${src_node}/bin" ]; then
                    materialise_leaf_bin "${src_node}/bin" "${dest}/bin"
                fi
                if [ -d "${src_node}/sbin" ]; then
                    materialise_leaf_bin "${src_node}/sbin" "${dest}/sbin"
                fi
                ;;
        esac
    done

    # Capsule libexec/: src/wire/<pkg>/libexec → ~/.local/libexec/<pkg>
    local pkg_le pkg has_subdir sub
    for pkg_le in "${src_root}"/*/libexec; do
        [ -d "${pkg_le}" ] || continue
        pkg="$(basename "$(dirname "${pkg_le}")")"
        wire_pkg_skipped "${pkg}" && continue
        case "${pkg}" in
            hosts) continue ;;
        esac
        dest="${local_home}/libexec/${pkg}"
        has_subdir=0
        for sub in "${pkg_le}"/*/; do
            [ -d "${sub}" ] || continue
            has_subdir=1
            break
        done
        if [ "${has_subdir}" -eq 1 ]; then
            materialise "${pkg_le}" "${dest}" "${WIRE_MODE}" ""
        else
            materialise_leaf_bin "${pkg_le}" "${dest}" 1
        fi
    done
}

run_mount() {
    local name="${1}"
    mount_from="${2}"
    mount_root="${3}"
    mount_mode="${4}"
    mount_require="${5:-}"
    mount_depth="${6:-0}"
    mount_skip="${7:-}"
    local strategy="${name%%.*}"
    # mount.bin.gnupg → label gnupg (package lib/libexec); mount.bin → empty
    mount_label=""
    case "${name}" in
        *.*) mount_label="${name#*.}" ;;
    esac

    mount_mode="$(resolve_wire_value "${WIRE_MODE:-${mount_mode}}")"
    mount_require="$(resolve_wire_value "${mount_require}")"
    mount_depth="$(resolve_wire_value "${mount_depth}")"
    mount_skip="$(resolve_wire_value "${mount_skip}")"
    case "${mount_mode}" in
        symlink | copy) ;;
        *)
            printf 'mode must be symlink or copy (got %s)\n' "${mount_mode}" >&2
            exit 1
            ;;
    esac

    ensure_wire_defaults
    from_path="$(resolve_wire_value "${mount_from}")"
    root_path="$(resolve_wire_value "${mount_root}")"
    case "${from_path}" in
        /*) ;;
        *) from_path="${repo_dir}/${from_path}" ;;
    esac

    if [ "${mount_require}" = "root" ] && [ "$(id -u)" -ne 0 ]; then
        printf 'wire mount=%s skipped (requires root; e.g. sudo)\n' "${name}"
        return 0
    fi

    if [ "${mount_require}" = "exists" ] && [ ! -e "${from_path}" ]; then
        printf 'wire mount=%s skipped (missing %s; WIRE_HOST=%s)\n' \
            "${name}" "${from_path}" "${WIRE_HOST:-?}"
        return 0
    fi

    printf 'wire mount=%s strategy=%s ini=%s repo=%s mode=%s depth=%s\n' \
        "${name}" "${strategy}" "${wire_ini}" "${repo_dir}" "${mount_mode}" \
        "${mount_depth:-0}"

    case "${strategy}" in
        libexec) wire_libexec ;;
        lib) wire_lib ;;
        home) wire_home ;;
        rootfs) wire_rootfs ;;
        tex) wire_tex ;;
        bin) wire_bin ;;
        sbin) wire_sbin ;;
        *)
            printf 'Unknown mount strategy: %s (from section mount.%s)\n' \
                "${strategy}" "${name}" >&2
            exit 1
            ;;
    esac
}

# --- parse wire.ini → run mounts ---

# US-delimited records (not tab — bash collapses empty IFS whitespace fields).
mounts_tmp="$(mktemp)"
trap 'rm -f -- "${mounts_tmp}"' EXIT

cur=""
m_from="" m_root="" m_mode="symlink" m_require="" m_depth="0" m_skip=""
flush_mount() {
    [ -n "${cur}" ] || return 0
    [ -n "${m_from}" ] && [ -n "${m_root}" ] || {
        printf 'Mount %s needs from= and root=\n' "${cur}" >&2
        exit 1
    }
    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
        "${cur}" "${m_from}" "${m_root}" "${m_mode}" "${m_require}" \
        "${m_depth}" "${m_skip}" >> "${mounts_tmp}"
}

while IFS= read -r line || [ -n "${line}" ]; do
    # Comments: full-line #…, or " #" inline. Keep bare # in values
    # (e.g. from = src/_local#bin).
    line="$(printf '%s' "${line}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    case "${line}" in
        '' | \#*) continue ;;
    esac
    line="$(printf '%s' "${line}" | sed 's/[[:space:]]#.*$//;s/[[:space:]]*$//')"
    [ -n "${line}" ] || continue
    case "${line}" in
        \[mount.*\])
            flush_mount
            cur="$(printf '%s' "${line}" | sed 's/^\[mount\.//;s/\]$//')"
            m_from="" m_root="" m_mode="symlink" m_require="" m_depth="0" m_skip=""
            continue
            ;;
        \[*\])
            flush_mount
            cur=""
            continue
            ;;
    esac
    [ -n "${cur}" ] || continue
    key="${line%%=*}"
    val="${line#*=}"
    key="$(printf '%s' "${key}" | sed 's/[[:space:]]*$//')"
    val="$(printf '%s' "${val}" | sed 's/^[[:space:]]*//')"
    case "${key}" in
        from) m_from="${val}" ;;
        root) m_root="${val}" ;;
        mode) m_mode="${val}" ;;
        require) m_require="${val}" ;;
        depth) m_depth="${val}" ;;
        skip) m_skip="${val}" ;;
    esac
done < "${wire_ini}"
flush_mount

ran=0
while IFS=$'\x1f' read -r name from root mode require depth skip; do
    [ -n "${name}" ] || continue
    if [ -n "${mount_filter}" ]; then
        case "${name}" in
            "${mount_filter}" | "${mount_filter}".*) ;;
            *) continue ;;
        esac
    fi
    run_mount "${name}" "${from}" "${root}" "${mode}" "${require}" \
        "${depth:-0}" "${skip:-}"
    ran=$((ran + 1))
done < "${mounts_tmp}"

if [ "${ran}" -eq 0 ]; then
    if [ -n "${mount_filter}" ]; then
        printf 'No mount [%s] in %s\n' "mount.${mount_filter}" "${wire_ini}" >&2
    else
        printf 'No [mount.*] sections in %s\n' "${wire_ini}" >&2
    fi
    exit 1
fi

# dia:end

#!/usr/bin/env bash

# dia:begin wire/make-wire.bash

# ---
# description: >-
#   Unified wire: reads config/wire.ini from the target repo (sidecar).
#   Each [mount.<strategy>] or [mount.<strategy>.<label>] has
#   from/root/mode/require; strategy is the first dotted segment
#   (lib|libexec|home|rootfs|tex|bin|sbin). require=exists skips missing from=;
#   ${WIRE_HOST} defaults to hostname -s (per-device overlays).
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
    # stems, then exec the real script (no self-locate needed in CLIs).
    local src_abs dest libexec_dir lib_dir wire_root
    src_abs="$(realpath "${1}")"
    dest="${2}"
    libexec_dir="${3}"
    lib_dir="${4}"
    wire_root="${5}"
    mkdir -p "$(dirname "${dest}")"
    if [ -L "${dest}" ] || [ -f "${dest}" ]; then
        rm -f -- "${dest}"
    elif [ -e "${dest}" ]; then
        printf 'Path already occupied: %s\n' "${dest}" >&2
        exit 1
    fi
    cat > "${dest}" <<EOF
#!/bin/sh
# Generated by make-wire — do not edit.
WIRE_ROOT="${wire_root}"
WIRE_LIB="${lib_dir}"
WIRE_LIBEXEC="${libexec_dir}"
PATH="\${WIRE_LIBEXEC}:\${PATH}"
export WIRE_ROOT WIRE_LIB WIRE_LIBEXEC PATH
exec "${src_abs}" "\$@"
EOF
    chmod a+x "${dest}"
    printf 'wrapped %s -> %s (lib %s libexec %s)\n' \
        "${dest}" "${src_abs}" "${lib_dir}" "${libexec_dir}"
}

# Resolve helper PATH dir for a package label (repo basename or mount.bin.<label>).
# Flat packages: ~/.local/libexec/<label>
# Dotfiles hash nodes: home/<label>/_local#libexec#… → ~/.local/libexec/…/bin
wire_resolve_libexec() {
    local label="${1}"
    local home_pkg node dest
    if [ -d "${local_home}/libexec/${label}/bin" ]; then
        printf '%s\n' "${local_home}/libexec/${label}/bin"
        return 0
    fi
    home_pkg="${repo_dir}/src/wire/home/${label}"
    if [ -d "${home_pkg}" ]; then
        for node in "${home_pkg}"/_local#libexec#*; do
            [ -e "${node}" ] || continue
            dest="${HOME}/$(printf '%s' "$(basename "${node}")" | decode_hash_name)"
            if [ -d "${dest}/bin" ]; then
                printf '%s\n' "${dest}/bin"
                return 0
            fi
            if [ -d "${dest}" ]; then
                printf '%s\n' "${dest}"
                return 0
            fi
            # Not installed yet — still emit the deterministic path (…/bin if hashed).
            case "$(basename "${node}")" in
                *#bin) printf '%s\n' "${dest}"; return 0 ;;
            esac
            printf '%s\n' "${dest}"
            return 0
        done
    fi
    printf '%s\n' "${local_home}/libexec/${label}"
}

# --- strategies (use mount_* globals) ---

wire_bin() {
    # Public CLIs under from/ → root/ as stem without extension.
    # Installs a PATH stub (not a bare symlink) so helpers in mount.libexec
    # resolve by name and WIRE_{ROOT,LIB,LIBEXEC} point at package trees.
    # Labeled mounts (mount.bin.gnupg) use the label for lib/libexec, not the
    # repo basename — see WIRING.md. Repo-tree runs use direnv (.envrc).
    local src base name dest libexec_dir lib_dir target_src wire_pkg
    mkdir -p "${root_path}"
    wire_pkg="${pkg}"
    if [ -n "${mount_label:-}" ]; then
        wire_pkg="${mount_label}"
    fi
    lib_dir="${local_home}/lib/${wire_pkg}"
    libexec_dir="$(wire_resolve_libexec "${wire_pkg}")"

    if [ -f "${from_path}" ]; then
        set -- "${from_path}"
    elif [ -d "${from_path}" ]; then
        set -- "${from_path}"/*
    else
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
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
            "${lib_dir}" "${repo_dir}"
    done
}

wire_sbin() {
    # Same publish rules as wire_bin; root= is typically ~/.local/sbin.
    wire_bin
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
    if [ -d "${src_root}/home" ]; then
        for src_node in "${src_root}"/home/*/_local#lib#*; do
            [ -e "${src_node}" ] || continue
            lib_nodes+=("${src_node}")
        done
    fi

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
    [ -d "${from_path}" ] || {
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
    }
    local bak_dir state_home
    state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    mkdir -p "${state_home}/make-wire-home"
    bak_dir="$(mktemp -d "${state_home}/make-wire-home/bak.XXXXXXX")"
    # Expand path now: with set -u, a RETURN trap must not reference a local
    # after the function scope ends.
    # shellcheck disable=SC2064
    trap "rmdir -- '${bak_dir}' 2>/dev/null || true" RETURN

    find -E -L "${from_path}" -mindepth 2 -maxdepth 2 ! -iname ".DS_Store" |
        while IFS= read -r src_node; do
            base="$(basename "${src_node}")"
            case "${base}" in
                _local#libexec#* | _local#lib#*) continue ;;
            esac
            dest="${root_path}/$(printf '%s' "${base}" | decode_hash_name)"
            mkdir -p "$(dirname "${dest}")"
            if [ -L "${dest}" ]; then
                rm -f -- "${dest}"
            elif [ -e "${dest}" ]; then
                mv "${dest}" "${bak_dir}"
            fi
            case "${mount_mode}" in
                symlink)
                    ln -sfn "${src_node}" "${dest}"
                    printf 'symlinked %s -> %s\n' "${dest}" "${src_node}"
                    ;;
                copy)
                    cp -R "${src_node}" "${dest}"
                    printf 'copied %s <- %s\n' "${dest}" "${src_node}"
                    ;;
            esac
        done
}

wire_rootfs() {
    [ -d "${from_path}" ] || {
        printf 'Missing %s\n' "${from_path}" >&2
        exit 1
    }
    local bak_dir state_home cfg_dir item name dest
    state_home="${XDG_STATE_HOME:-${HOME}/.local/state}"
    mkdir -p "${state_home}/make-wire-rootfs"
    bak_dir="$(mktemp -d "${state_home}/make-wire-rootfs/bak.XXXXXXX")"
    # shellcheck disable=SC2064
    trap "rmdir -- '${bak_dir}' 2>/dev/null || true" RETURN

    for cfg_dir in "${from_path}"/*/; do
        [ -d "${cfg_dir}" ] || continue
        for item in "${cfg_dir%/}"/*; do
            [ -e "${item}" ] || continue
            name="$(basename "${item}")"
            case "${name}" in
                .*) continue ;;
            esac
            dest="${root_path}/$(printf '%s' "${name}" | decode_hash_name)"
            mkdir -p "$(dirname "${dest}")"
            if [ -e "${dest}" ]; then
                mv "${dest}" "${bak_dir}"
            fi
            cp -R "${item}" "${dest}"
            chown -R root:wheel "${dest}" 2> /dev/null || chown -R root:root "${dest}"
            printf 'copied %s <- %s\n' "${dest}" "${item}"
        done
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

    # Nested / legacy: hash-encoded _local#libexec#* (e.g. under wire/home/*)
    local libexec_nodes=()
    local src_node
    for src_node in "${src_root}"/_local#libexec#*; do
        [ -e "${src_node}" ] || continue
        libexec_nodes+=("${src_node}")
    done
    if [ -d "${src_root}/home" ]; then
        for src_node in "${src_root}"/home/*/_local#libexec#*; do
            [ -e "${src_node}" ] || continue
            libexec_nodes+=("${src_node}")
        done
    fi

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
}

run_mount() {
    local name="${1}"
    mount_from="${2}"
    mount_root="${3}"
    mount_mode="${4}"
    mount_require="${5:-}"
    local strategy="${name%%.*}"
    # mount.bin.gnupg → label gnupg (package lib/libexec); mount.bin → empty
    mount_label=""
    case "${name}" in
        *.*) mount_label="${name#*.}" ;;
    esac

    mount_mode="$(resolve_wire_value "${WIRE_MODE:-${mount_mode}}")"
    mount_require="$(resolve_wire_value "${mount_require}")"
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

    printf 'wire mount=%s strategy=%s ini=%s repo=%s mode=%s\n' \
        "${name}" "${strategy}" "${wire_ini}" "${repo_dir}" "${mount_mode}"

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

mounts_tmp="$(mktemp)"
trap 'rm -f -- "${mounts_tmp}"' EXIT

cur=""
m_from="" m_root="" m_mode="symlink" m_require=""
flush_mount() {
    [ -n "${cur}" ] || return 0
    [ -n "${m_from}" ] && [ -n "${m_root}" ] || {
        printf 'Mount %s needs from= and root=\n' "${cur}" >&2
        exit 1
    }
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "${cur}" "${m_from}" "${m_root}" "${m_mode}" "${m_require}" >> "${mounts_tmp}"
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
            m_from="" m_root="" m_mode="symlink" m_require=""
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
    esac
done < "${wire_ini}"
flush_mount

ran=0
while IFS=$'\t' read -r name from root mode require; do
    [ -n "${name}" ] || continue
    if [ -n "${mount_filter}" ]; then
        case "${name}" in
            "${mount_filter}" | "${mount_filter}".*) ;;
            *) continue ;;
        esac
    fi
    run_mount "${name}" "${from}" "${root}" "${mode}" "${require}"
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


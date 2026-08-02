#!/usr/bin/env bash

# ---
# description: >-
#   Symlinks src/wiring/bin scripts into ${MY_LOCAL_HOME:-$HOME/.local}/bin
#   (basename without extension)
# ---

# ---

set -o errexit
set -o nounset

WIRING_ROOT="src/wiring"
DIRS=("bin")

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
cd "${script_dir}" || exit 1

repo_dir="$(git rev-parse --show-toplevel)"
local_home="${MY_LOCAL_HOME:-${HOME}/.local}"

smart-lns() {
    local src="${1}"
    local tar="${2}"
    if [ -L "${tar}" ]; then
        rm -- "${tar}"
    elif [ -e "${tar}" ]; then
        printf 'Path already occupied (not a symlink): %s\n' "${tar}" >&2
        exit 1
    fi
    ln -s "${src}" "${tar}"
    printf 'symlinked %s -> %s\n' "${tar}" "${src}"
}

for dir in "${DIRS[@]}"; do
    src_dir="${repo_dir}/${WIRING_ROOT}/${dir}"
    dst_dir="${local_home}/${dir}"
    mkdir -p "${dst_dir}"

    find -L "${dst_dir}" -maxdepth 1 -type l -print0 2> /dev/null |
        xargs -0 rm -- 2> /dev/null || :

    for src in "${src_dir}"/*.*; do
        if [ -f "${src}" ]; then
            chmod 755 "${src}"
            base="$(basename "${src}" | sed 's:\.[^.]*$::')"
            smart-lns "${src}" "${dst_dir}/${base}"
        fi
    done

    for src in "${src_dir}"/*/main.*; do
        if [ -f "${src}" ]; then
            chmod 755 "${src}"
            name="$(basename "$(dirname "${src}")")"
            smart-lns "${src}" "${dst_dir}/${name}"
        fi
    done
done

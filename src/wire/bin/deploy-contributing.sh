#!/usr/bin/env sh

# ---
# description: >-
#   Drops a static CONTRIBUTING.md template; substitutes {{name}} from
#   project.name in .mtdt.yaml (no contributing fields in the schema)
# ---

# ---

set -o errexit
set -o nounset

find_mtdt_root() (
    start="${1:-${PWD}}"
    root="$(CDPATH='' cd -- "${start}" 2> /dev/null && pwd -P)" || return 1
    while [ ! -f "${root}/.mtdt.yaml" ]; do
        parent="$(dirname "${root}")"
        if [ "${parent}" = "${root}" ]; then
            printf 'No .mtdt.yaml found above %s\n' "${start}" >&2
            return 1
        fi
        root="${parent}"
    done
    printf '%s\n' "${root}"
)

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
root="$(find_mtdt_root "${script_dir}")"
template="${root}/share/templates/contributing/base.md"

set -- "${@:-.}"

if [ ! -f "${template}" ]; then
    printf '%s\n' "Missing template: ${template}" >&2
    exit 1
fi

find "${@}" -type f -iname ".mtdt.yaml" |
    while IFS="" read -r file; do
        repo_dir="$(dirname "${file}")"
        name="$(yq -r '.project.name // ""' "${file}")"
        if [ -z "${name}" ] || [ "${name}" = "null" ]; then
            printf '%s\n' "Skip (no project.name): ${file}" >&2
            continue
        fi
        out="${repo_dir}/CONTRIBUTING.md"
        # Escape sed replacement specials in name minimally
        name_esc="$(printf '%s' "${name}" | sed -e 's/[&/\]/\\&/g')"
        sed -e "s/{{name}}/${name_esc}/g" "${template}" > "${out}"
        printf '%s\n' "Wrote ${out}"
    done

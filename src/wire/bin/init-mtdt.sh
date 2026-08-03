#!/usr/bin/env sh

# ---
# description: >-
#   Scaffolds a new .mtdt.yaml in the given directory (default: .) from
#   templates/mtdt.yaml with a fresh UUID and the directory basename as name
# ---

# ---

set -o errexit
set -o nounset

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
template="${root}/templates/mtdt.yaml"

target="${1:-.}"
out="${target}/.mtdt.yaml"

if [ -e "${out}" ]; then
    printf '%s\n' "Refusing to overwrite existing ${out}" >&2
    exit 1
fi

if [ ! -d "${target}" ]; then
    printf '%s\n' "Not a directory: ${target}" >&2
    exit 1
fi

if [ ! -f "${template}" ]; then
    printf '%s\n' "Missing template: ${template}" >&2
    exit 1
fi

id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
dir_name="$(basename "$(realpath "${target}")")"

# Escape & \ and sed replacement delimiters for safe substitution.
escape_sed() {
    printf '%s' "${1}" | sed -e 's/[\\&|]/\\&/g'
}

id_esc="$(escape_sed "${id}")"
name_esc="$(escape_sed "${dir_name}")"

# Accept both {{ id }} and {{id}} (Jinja-compatible spacing).
sed \
    -e "s|{{[[:space:]]*id[[:space:]]*}}|${id_esc}|g" \
    -e "s|{{[[:space:]]*name[[:space:]]*}}|${name_esc}|g" \
    "${template}" > "${out}"

printf '%s\n' "Wrote ${out}"
printf '%s\n' "  id: ${id}"
printf '%s\n' "  name: ${dir_name}"
printf '%s\n' "Replace remaining {{ … }} placeholders before deploy/sync."

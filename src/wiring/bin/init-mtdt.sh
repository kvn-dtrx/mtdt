#!/usr/bin/env sh

# ---
# description: >-
#   Scaffolds a new .mtdt.yaml in the given directory (default: .) with a
#   fresh UUID and placeholder fields
# ---

# ---

set -o errexit
set -o nounset

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

id="$(uuidgen | tr '[:upper:]' '[:lower:]')"
dir_name="$(basename "$(realpath "${target}")")"
year="$(date +%Y)"

cat > "${out}" <<EOF
project:
  id: ${id}
  name: ${dir_name}
  description: >-
    TODO: short project description
  authors:
    - name: Kvn Dtrx
      mail: kvn.dtrx+git@protonmail.ch
  license: null
  github:
    url: null
    visibility: null
EOF

printf '%s\n' "Wrote ${out}"
printf '%s\n' "  id: ${id}"
printf '%s\n' "  name: ${dir_name}"

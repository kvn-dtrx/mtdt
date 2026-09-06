#!/usr/bin/env sh

set -o errexit

script_dir="$(dirname "$(realpath "${0}")")"
exec python3 "${script_dir}/update-glab-repos.py" visibility "${@}"

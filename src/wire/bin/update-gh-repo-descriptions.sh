#!/usr/bin/env sh

# ---
# description: >-
#   Updates GitHub repo description from .mtdt.yaml for all repositories
#   subordinate to the specified directories
# ---

# ---

set -- "${@:-.}"

find "${@}" -type f -iname ".mtdt.yaml" |
    while IFS="" read -r file; do
        repo_dir="$(dirname "${file}")"
        if [ -d "${repo_dir}/.git" ]; then
            description="$(yq -r ".project.description" "${file}" 2> /dev/null)"
            if [ -n "${description}" ] &&
                [ "${description}" != "null" ]; then
                (
                    cd "${repo_dir}" ||
                        exit 1
                    gh repo edit --description "${description}"
                )
            fi
        fi
    done

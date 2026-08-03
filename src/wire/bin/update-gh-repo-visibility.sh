#!/usr/bin/env sh

# ---
# description: >-
#   Updates GitHub repo visibility from .mtdt.yaml for all repositories
#   subordinate to the specified directories
# ---

# ---

set -- "${@:-.}"

find "${@}" -type f -iname ".mtdt.yaml" |
    while IFS="" read -r file; do
        repo_dir="$(dirname "${file}")"
        if [ -d "${repo_dir}/.git" ]; then
            visibility="$(yq -r ".forges.github.visibility" "${file}" 2> /dev/null)"
            case "${visibility}" in
                public | private | internal) ;;
                "" | null) continue ;;
                *)
                    printf '%s\n' \
                        "Invalid visibility in ${file}:" \
                        "  '${visibility}' (expected public|private|internal)" >&2
                    continue
                    ;;
            esac
            (
                cd "${repo_dir}" ||
                    exit 1
                current="$(gh repo view --json visibility -q .visibility 2> /dev/null)"
                if [ -z "${current}" ]; then
                    exit 0
                fi
                current_lc="$(printf '%s' "${current}" | tr '[:upper:]' '[:lower:]')"
                if [ "${current_lc}" = "${visibility}" ]; then
                    exit 0
                fi
                printf '%s\n' \
                    "Visibility change:" \
                    "  $(basename "${repo_dir}"): ${current_lc} -> ${visibility}"
                gh repo edit \
                    --visibility "${visibility}" \
                    --accept-visibility-change-consequences
            )
        fi
    done

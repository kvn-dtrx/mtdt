#!/usr/bin/env sh

# ---
# description: >-
#   Updates GitHub repo visibility from effective mtdt forges.github.visibility
#   (.mtdt.yaml ⊕ .mtdt.local.yaml) for all repositories under the given dirs
# ---

# ---

set -o errexit
set -o nounset

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"

resolve_mtdt() {
    if command -v resolve-mtdt > /dev/null 2>&1; then
        resolve-mtdt "${1}"
    elif [ -f "${script_dir}/resolve-mtdt.py" ]; then
        python3 "${script_dir}/resolve-mtdt.py" "${1}"
    else
        cat "${1}"
    fi
}

set -- "${@:-.}"

find "${@}" -type f -iname ".mtdt.yaml" |
    while IFS="" read -r file; do
        repo_dir="$(dirname "${file}")"
        if [ -d "${repo_dir}/.git" ]; then
            effective="$(mktemp)"
            if ! resolve_mtdt "${file}" > "${effective}"; then
                printf '%s\n' "resolve-mtdt failed for ${file}" >&2
                rm -f "${effective}"
                continue
            fi
            visibility="$(yq -r ".forges.github.visibility" "${effective}" 2> /dev/null)"
            rm -f "${effective}"
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

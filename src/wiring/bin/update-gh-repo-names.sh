#!/usr/bin/env sh

# ---
# description: >-
#   Prompts to update GitHub repo name based on the local directory name
#   for all repositories subordinate to the specified directories
# ---

# ---

set -o errexit
set -o nounset

set -- "${@:-.}"

find -L "${@}" -type d -iname ".git" |
    while IFS="" read -r git_dir; do
        project_rel="$(dirname "${git_dir}")"
        project="$(git -C "${project_rel}" rev-parse --show-toplevel)"
        project_name="$(basename "${project}")"
        (
            cd "${project}"
            github_name="$(gh repo view --json name -q .name 2> /dev/null)"
            if [ -n "${github_name}" ]; then
                if [ "${project_name}" != "${github_name}" ]; then
                    printf '%s\n' \
                        "Divergence detected:" \
                        "  Directory: ${project_name}" \
                        "  GitHub:  ${github_name}"
                    printf "Rename GitHub repo to '%s'? [y/N] " "${project_name}"
                    read -r ans < /dev/tty
                    case "${ans}" in
                        [Yy]*) gh repo rename "${project_name}" --yes ;;
                        [Nn]* | "") printf '%s\n' "Skipped." ;;
                        *) printf '%s\n' "Please answer y or n." >&2 ;;
                    esac
                fi
            fi
        )
    done

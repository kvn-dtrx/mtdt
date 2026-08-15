#!/usr/bin/env sh

# ---
# description: >-
#   Prompts to rename the GitHub repo to match the mtdt-derived slug
#   (derive-project-slug of project.name). Optional --dirname uses the
#   local checkout basename instead (legacy).
# ---

# ---

set -o errexit
set -o nounset

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"

usage() {
    printf '%s\n' \
        "Usage: update-gh-repo-names [--dirname] [DIR...]" \
        "  Default: rename GitHub repo toward derive-project-slug(project.name)." \
        "  --dirname: use local checkout basename as the target (legacy)."
}

mode=mtdt
roots_tmp="$(mktemp)"
list_tmp="$(mktemp)"
trap 'rm -f "${roots_tmp}" "${list_tmp}"' EXIT

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --dirname)
            mode='dirname'
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                printf '%s\n' "${1}" >> "${roots_tmp}"
                shift
            done
            break
            ;;
        -*)
            printf '%s\n' "Unknown option: ${1}" >&2
            exit 2
            ;;
        *)
            printf '%s\n' "${1}" >> "${roots_tmp}"
            shift
            ;;
    esac
done

if [ ! -s "${roots_tmp}" ]; then
    printf '%s\n' "." > "${roots_tmp}"
fi

derive_slug() {
    if command -v derive-project-slug > /dev/null 2>&1; then
        derive-project-slug
    elif [ -f "${script_dir}/derive-project-slug.py" ]; then
        python3 "${script_dir}/derive-project-slug.py"
    else
        printf '%s\n' "derive-project-slug not found on PATH or beside this script" >&2
        return 127
    fi
}

while IFS= read -r root; do
    [ -n "${root}" ] || continue
    find "${root}" -type f -iname ".mtdt.yaml" >> "${list_tmp}"
done < "${roots_tmp}"

while IFS="" read -r file; do
    [ -n "${file}" ] || continue

    project_dir="$(CDPATH='' cd -- "$(dirname "${file}")" && pwd)"
    if [ ! -d "${project_dir}/.git" ] &&
        ! git -C "${project_dir}" rev-parse --git-dir > /dev/null 2>&1; then
        continue
    fi

    dirname="$(basename "${project_dir}")"
    display_name="$(yq -r '.project.name // ""' "${file}")"
    if [ -z "${display_name}" ] || [ "${display_name}" = "null" ]; then
        printf '%s\n' "SKIP ${project_dir}: missing project.name" >&2
        continue
    fi

    if [ "${mode}" = "dirname" ]; then
        target="${dirname}"
        target_label="directory"
    else
        if ! target="$(printf '%s\n' "${display_name}" | derive_slug)"; then
            printf '%s\n' "SKIP ${project_dir}: derive-project-slug failed" >&2
            continue
        fi
        if [ -z "${target}" ]; then
            printf '%s\n' "SKIP ${project_dir}: empty slug from name '${display_name}'" >&2
            continue
        fi
        target_label="mtdt slug"
    fi

    github_name="$(
        CDPATH='' cd -- "${project_dir}" &&
            gh repo view --json name -q .name 2> /dev/null || true
    )"
    if [ -z "${github_name}" ]; then
        continue
    fi
    if [ "${target}" = "${github_name}" ]; then
        continue
    fi

    printf '%s\n' \
        "Divergence detected (${project_dir}):" \
        "  project.name: ${display_name}" \
        "  directory:    ${dirname}" \
        "  target (${target_label}): ${target}" \
        "  GitHub:       ${github_name}"
    printf "Rename GitHub repo to '%s'? [y/N] " "${target}"
    if ! read -r ans < /dev/tty; then
        printf '%s\n' "Skipped (no tty)."
        continue
    fi
    case "${ans}" in
        [Yy]*)
            if ! (
                CDPATH='' cd -- "${project_dir}" &&
                    gh repo rename "${target}" --yes
            ); then
                printf '%s\n' "Rename failed for ${project_dir}" >&2
            fi
            ;;
        [Nn]* | "") printf '%s\n' "Skipped." ;;
        *) printf '%s\n' "Please answer y or n." >&2 ;;
    esac
done < "${list_tmp}"

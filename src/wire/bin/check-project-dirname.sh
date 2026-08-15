#!/usr/bin/env sh

# ---
# description: >-
#   Reports repositories whose directory basename diverges from the slug
#   derived from project.name in .mtdt.yaml. Optional --fix renames the
#   directory; refuses to overwrite an existing destination path.
# ---

# ---

set -o errexit
set -o nounset

fix=0

usage() {
    printf '%s\n' \
        "Usage: check-project-dirname [--fix] [DIR...]" \
        "  Find .mtdt.yaml trees whose directory basename ≠ derive-project-slug(name)." \
        "  Default: report only (exit 1 if any divergence or error)." \
        "  --fix: rename directory to the derived slug." \
        "  Existing destination paths block the rename (non-zero exit)."
}

roots_tmp="$(mktemp)"
list_tmp="$(mktemp)"
trap 'rm -f "${roots_tmp}" "${list_tmp}"' EXIT

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --fix)
            fix=1
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

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"

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

: > "${list_tmp}"
while IFS= read -r root; do
    [ -n "${root}" ] || continue
    find "${root}" -type f -iname ".mtdt.yaml" >> "${list_tmp}"
done < "${roots_tmp}"

mismatches=0
blocked=0
renamed=0
ok=0

while IFS="" read -r file; do
    [ -n "${file}" ] || continue

    project_dir="$(CDPATH='' cd -- "$(dirname "${file}")" && pwd)"
    dirname="$(basename "${project_dir}")"
    name="$(yq -r '.project.name // ""' "${file}")"

    if [ -z "${name}" ] || [ "${name}" = "null" ]; then
        printf '%s\n' "ERROR ${project_dir}: missing project.name" >&2
        blocked=$((blocked + 1))
        continue
    fi

    slug="$(printf '%s\n' "${name}" | derive_slug)" || {
        blocked=$((blocked + 1))
        continue
    }
    if [ -z "${slug}" ]; then
        printf '%s\n' "ERROR ${project_dir}: empty slug from name '${name}'" >&2
        blocked=$((blocked + 1))
        continue
    fi

    if [ "${slug}" = "${dirname}" ]; then
        ok=$((ok + 1))
        continue
    fi

    mismatches=$((mismatches + 1))
    parent="$(dirname "${project_dir}")"
    dest="${parent}/${slug}"

    if [ "${fix}" -eq 0 ]; then
        printf '%s\n' \
            "DIVERGE ${project_dir}" \
            "  name: ${name}" \
            "  slug: ${slug}"
        continue
    fi

    if [ -e "${dest}" ]; then
        printf '%s\n' \
            "BLOCK ${project_dir}" \
            "  name:   ${name}" \
            "  slug:   ${slug}" \
            "  reason: destination exists: ${dest}" >&2
        blocked=$((blocked + 1))
        continue
    fi

    if mv "${project_dir}" "${dest}"; then
        printf '%s\n' "RENAMED ${project_dir} -> ${dest}"
        renamed=$((renamed + 1))
    else
        printf '%s\n' "ERROR failed to rename ${project_dir} -> ${dest}" >&2
        blocked=$((blocked + 1))
    fi
done < "${list_tmp}"

printf '%s\n' \
    "ok=${ok} diverge=${mismatches} renamed=${renamed} blocked=${blocked} fix=${fix}"

if [ "${blocked}" -ne 0 ]; then
    exit 1
fi
if [ "${mismatches}" -ne 0 ] && [ "${fix}" -eq 0 ]; then
    exit 1
fi
# With --fix, leftover divergences only happen if blocked; renamed counts as resolved.
if [ "${fix}" -eq 1 ] && [ "$((mismatches - renamed))" -ne 0 ]; then
    exit 1
fi
exit 0

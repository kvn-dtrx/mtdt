#!/usr/bin/env sh

# ---
# description: >-
#   Performs basic structural validation of .mtdt.yaml files under the
#   given directories (required keys, license/year shapes, visibility)
# ---

# ---

set -o errexit
set -o nounset

set -- "${@:-.}"
errors=0
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

find "${@}" -type f -iname ".mtdt.yaml" > "${tmp}"

while IFS="" read -r file; do
    [ -n "${file}" ] || continue

    if ! yq -e '.project' "${file}" > /dev/null 2>&1; then
        printf '%s\n' "ERROR ${file}: top-level project: required" >&2
        errors=$((errors + 1))
        continue
    fi

    for path in .project.id .project.name .project.description; do
        value="$(yq -r "${path} // \"\"" "${file}")"
        if [ -z "${value}" ] || [ "${value}" = "null" ]; then
            printf '%s\n' "ERROR ${file}: missing ${path}" >&2
            errors=$((errors + 1))
        fi
    done

    acount="$(yq -r '.project.authors | length' "${file}" 2> /dev/null || printf '0')"
    if [ "${acount}" = "0" ] || [ "${acount}" = "null" ]; then
        printf '%s\n' "ERROR ${file}: project.authors must be a non-empty list" >&2
        errors=$((errors + 1))
    fi

    license_null="$(yq -r '.project.license == null' "${file}")"
    license_type="$(yq -r '.project.license.type // ""' "${file}")"
    if [ "${license_null}" != "true" ] && [ -n "${license_type}" ] && [ "${license_type}" != "null" ]; then
        year_tag="$(yq -r '.project.license.year | type' "${file}" 2> /dev/null || printf '')"
        year_val="$(yq -r '.project.license.year' "${file}" 2> /dev/null || printf '')"
        year_ok=0
        case "${year_tag}" in
            !!int | !!float) year_ok=1 ;;
            !!str)
                case "${year_val}" in
                    [0-9][0-9][0-9][0-9] | [0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9])
                        year_ok=1
                        ;;
                esac
                ;;
            !!seq)
                # non-empty sequence of numbers
                if [ "$(yq -r '.project.license.year | length' "${file}")" -gt 0 ] &&
                    [ "$(yq -r '[.project.license.year[] | type] | unique | . == ["!!int"]' "${file}")" = "true" ]; then
                    year_ok=1
                fi
                ;;
        esac
        if [ "${year_ok}" -ne 1 ]; then
            printf '%s\n' \
                "ERROR ${file}: project.license.year must be int, YYYY-YYYY, or list of ints" >&2
            errors=$((errors + 1))
        fi
    fi

    visibility="$(yq -r '.project.github.visibility // ""' "${file}")"
    case "${visibility}" in
        "" | null | public | private | internal) ;;
        *)
            printf '%s\n' "ERROR ${file}: invalid github.visibility '${visibility}'" >&2
            errors=$((errors + 1))
            ;;
    esac

    if yq -e '.project.subtrees' "${file}" > /dev/null 2>&1; then
        printf '%s\n' "ERROR ${file}: subtrees must be top-level, not under project:" >&2
        errors=$((errors + 1))
    fi
done < "${tmp}"

if [ "${errors}" -ne 0 ]; then
    printf '%s\n' "Validation failed with ${errors} error(s)." >&2
    exit 1
fi
printf '%s\n' "OK"

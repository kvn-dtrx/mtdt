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
                # non-empty sequence of integers (use tag; yq mishandles == ["!!int"])
                if [ "$(yq -r '.project.license.year | length' "${file}")" -gt 0 ] &&
                    [ "$(yq -r '.project.license.year | map(tag == "!!int") | all' "${file}")" = "true" ]; then
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

    if yq -e '.project.github' "${file}" > /dev/null 2>&1; then
        printf '%s\n' "ERROR ${file}: github must be under forges:, not project:" >&2
        errors=$((errors + 1))
    fi

    if yq -e '.subtrees' "${file}" > /dev/null 2>&1; then
        printf '%s\n' "ERROR ${file}: subtrees is not part of the schema" >&2
        errors=$((errors + 1))
    fi

    # Validate visibility on every forge host entry that declares one
    host_count="$(yq -r '.forges // {} | keys | length' "${file}" 2> /dev/null || printf '0')"
    if [ "${host_count}" != "0" ] && [ "${host_count}" != "null" ]; then
        idx=0
        while [ "${idx}" -lt "${host_count}" ]; do
            host="$(yq -r ".forges | keys | .[${idx}]" "${file}")"
            visibility="$(yq -r ".forges.${host}.visibility // \"\"" "${file}")"
            case "${visibility}" in
                "" | null | public | private | internal) ;;
                *)
                    printf '%s\n' \
                        "ERROR ${file}: invalid forges.${host}.visibility '${visibility}'" >&2
                    errors=$((errors + 1))
                    ;;
            esac
            idx=$((idx + 1))
        done
    fi
done < "${tmp}"

if [ "${errors}" -ne 0 ]; then
    printf '%s\n' "Validation failed with ${errors} error(s)." >&2
    exit 1
fi
printf '%s\n' "OK"

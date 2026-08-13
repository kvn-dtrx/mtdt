#!/usr/bin/env sh

# ---
# description: >-
#   Performs basic structural validation of .mtdt.yaml files under the
#   given directories (required keys, license/year shapes, visibility).
#   Warns (non-fatal) when a forge is public but project.license is null,
#   or when derive-project-slug(name) ≠ forge URL slug (github/gitlab/…).
#   Effective forges come from resolve-mtdt (.mtdt.local.yaml overlay).
# ---

# ---

set -o errexit
set -o nounset

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

resolve_mtdt() {
    if command -v resolve-mtdt > /dev/null 2>&1; then
        resolve-mtdt "${1}"
    elif [ -f "${script_dir}/resolve-mtdt.py" ]; then
        python3 "${script_dir}/resolve-mtdt.py" "${1}"
    else
        cat "${1}"
    fi
}

# Last path segment of an HTTPS or git@ URL; strips trailing .git and /.
forge_slug_from_url() {
    url="${1}"
    url="${url%%\?*}"
    url="${url%%#*}"
    while [ "${url%/}" != "${url}" ]; do
        url="${url%/}"
    done
    case "${url}" in
        *.git) url="${url%.git}" ;;
    esac
    printf '%s' "${url##*/}"
}

set -- "${@:-.}"
errors=0
warnings=0
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

    effective="$(mktemp)"
    if ! resolve_mtdt "${file}" > "${effective}"; then
        printf '%s\n' "ERROR ${file}: resolve-mtdt failed (check .mtdt.local.yaml)" >&2
        errors=$((errors + 1))
        rm -f "${effective}"
        continue
    fi

    license_undeclared=0
    if [ "${license_null}" = "true" ] ||
        [ -z "${license_type}" ] || [ "${license_type}" = "null" ]; then
        license_undeclared=1
    fi

    project_name="$(yq -r '.project.name // ""' "${file}")"
    derived_slug=""
    if [ -n "${project_name}" ] && [ "${project_name}" != "null" ]; then
        derived_slug="$(printf '%s\n' "${project_name}" | derive_slug)" || derived_slug=""
    fi

    host_count="$(yq -r '.forges // {} | keys | length' "${effective}" 2> /dev/null || printf '0')"
    if [ "${host_count}" != "0" ] && [ "${host_count}" != "null" ]; then
        idx=0
        while [ "${idx}" -lt "${host_count}" ]; do
            host="$(yq -r ".forges | keys | .[${idx}]" "${effective}")"
            visibility="$(yq -r ".forges.${host}.visibility // \"\"" "${effective}")"
            case "${visibility}" in
                "" | null | public | private | internal) ;;
                *)
                    printf '%s\n' \
                        "ERROR ${file}: invalid forges.${host}.visibility '${visibility}'" >&2
                    errors=$((errors + 1))
                    ;;
            esac
            if [ "${visibility}" = "public" ] && [ "${license_undeclared}" -eq 1 ]; then
                printf '%s\n' \
                    "WARN ${file}: forges.${host} is public but project.license is null/unset" \
                    "  (set an OSS type, or proprietary/ARR if no use rights are granted)" >&2
                warnings=$((warnings + 1))
            fi

            forge_url="$(yq -r ".forges.${host}.url // \"\"" "${effective}")"
            if [ -n "${forge_url}" ] && [ "${forge_url}" != "null" ] &&
                [ -n "${derived_slug}" ]; then
                forge_slug="$(forge_slug_from_url "${forge_url}")"
                if [ -n "${forge_slug}" ] && [ "${forge_slug}" != "${derived_slug}" ]; then
                    printf '%s\n' \
                        "WARN ${file}: forges.${host} slug '${forge_slug}' ≠ derived slug '${derived_slug}'" \
                        "  (from project.name '${project_name}'; effective URL after local overlay)" >&2
                    warnings=$((warnings + 1))
                fi
            fi
            idx=$((idx + 1))
        done
    fi
    rm -f "${effective}"
done < "${tmp}"

if [ "${errors}" -ne 0 ]; then
    printf '%s\n' "Validation failed with ${errors} error(s)." >&2
    exit 1
fi
if [ "${warnings}" -ne 0 ]; then
    printf '%s\n' "OK (${warnings} warning(s))"
else
    printf '%s\n' "OK"
fi

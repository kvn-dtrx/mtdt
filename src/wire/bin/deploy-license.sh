#!/usr/bin/env sh

# ---
# description: >-
#   Renders LICENSE (or project.license.file) from .mtdt.yaml and the
#   matching template under share/templates/license/
# ---

# ---

set -o errexit
set -o nounset

# Default output name when project.license.file is unset.
DEFAULT_LICENSE_FILE="LICENSE.txt"

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
root="$(git -C "${script_dir}" rev-parse --show-toplevel)"
templates="${root}/share/templates/license"

set -- "${@:-.}"

format_year() {
    file="${1}"
    tag="$(yq -r '.project.license.year | type' "${file}" 2> /dev/null || printf '')"
    case "${tag}" in
        !!int | !!float | !!str)
            yq -r '.project.license.year' "${file}"
            ;;
        !!seq)
            yq -r '.project.license.year | map(tostring) | join(", ")' "${file}"
            ;;
        *)
            printf '%s' ""
            ;;
    esac
}

format_owners() {
    file="${1}"
    override="$(yq -r '.project.license["copyright-owner"] // .project.license.copyright_owner // ""' "${file}")"
    if [ -n "${override}" ] && [ "${override}" != "null" ]; then
        printf '%s' "${override}"
        return
    fi
    yq -r '[.project.authors[].name] | join(", ")' "${file}"
}

license_type_to_template() {
    # Map SPDX-ish / short names onto template filenames
    type_lc="$(printf '%s' "${1}" | tr '[:upper:]' '[:lower:]')"
    case "${type_lc}" in
        mit) printf '%s' "mit.txt" ;;
        isc) printf '%s' "isc.txt" ;;
        apache | apache-2.0 | apache2) printf '%s' "apache.txt" ;;
        gpl | gpl-3.0 | gnu) printf '%s' "gnu.txt" ;;
        wtfpl | wtfpl-2.0) printf '%s' "wtfpl.txt" ;;
        proprietary | arr | all-rights-reserved) printf '%s' "proprietary.txt" ;;
        *)
            printf '%s\n' "No template mapping for license type: ${1}" >&2
            return 1
            ;;
    esac
}

find "${@}" -type f -iname ".mtdt.yaml" |
    while IFS="" read -r file; do
        repo_dir="$(dirname "${file}")"
        license_type="$(yq -r '.project.license.type // ""' "${file}")"
        if [ -z "${license_type}" ] || [ "${license_type}" = "null" ]; then
            continue
        fi

        template_name="$(license_type_to_template "${license_type}")" || continue
        template="${templates}/${template_name}"
        if [ ! -f "${template}" ]; then
            printf '%s\n' "Missing template: ${template}" >&2
            continue
        fi

        year="$(format_year "${file}")"
        owners="$(format_owners "${file}")"
        out_rel="$(yq -r ".project.license.file // \"${DEFAULT_LICENSE_FILE}\"" "${file}")"
        if [ -z "${out_rel}" ] || [ "${out_rel}" = "null" ]; then
            out_rel="${DEFAULT_LICENSE_FILE}"
        fi
        out="${repo_dir}/${out_rel}"

        # shellcheck disable=SC2016
        sed \
            -e "s/\\[year\\]/${year}/g" \
            -e "s/\\[fullname\\]/${owners}/g" \
            "${template}" > "${out}"
        printf '%s\n' "Wrote ${out}"
    done

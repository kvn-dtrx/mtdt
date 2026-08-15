#!/usr/bin/env sh

# ---
# description: >-
#   For each .mtdt.yaml tree with a git checkout, dry-run push HEAD to the
#   effective forges.github.url (resolve-mtdt: base ⊕ .mtdt.local.yaml).
#   Skips missing .git or null/empty github URL. Needs network + credentials.
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

usage() {
    printf '%s\n' \
        "Usage: check-forge-push [DIR...]" \
        "  Dry-run git push of HEAD to effective forges.github.url" \
        "  (.mtdt.yaml ⊕ .mtdt.local.yaml)." \
        "  Skips repos without .git or without a github URL." \
        "  Exit 1 if any dry-run fails."
}

case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
esac

set -- "${@:-.}"

ok=0
skipped=0
failed=0
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT

find "${@}" -type f -iname ".mtdt.yaml" > "${tmp}"

while IFS="" read -r file; do
    [ -n "${file}" ] || continue

    project_dir="$(CDPATH='' cd -- "$(dirname "${file}")" && pwd)"

    if [ ! -d "${project_dir}/.git" ] &&
        ! git -C "${project_dir}" rev-parse --git-dir > /dev/null 2>&1; then
        printf '%s\n' "SKIP ${project_dir}: not a git checkout"
        skipped=$((skipped + 1))
        continue
    fi

    effective="$(mktemp)"
    if ! resolve_mtdt "${file}" > "${effective}"; then
        printf '%s\n' \
            "FAIL ${project_dir}" \
            "  reason: resolve-mtdt failed (check .mtdt.local.yaml)" >&2
        failed=$((failed + 1))
        rm -f "${effective}"
        continue
    fi

    url="$(yq -r '.forges.github.url // ""' "${effective}")"
    rm -f "${effective}"

    if [ -z "${url}" ] || [ "${url}" = "null" ]; then
        printf '%s\n' "SKIP ${project_dir}: forges.github.url unset"
        skipped=$((skipped + 1))
        continue
    fi

    case "${url}" in
        *github.com* | *github.*) ;;
        *)
            printf '%s\n' \
                "FAIL ${project_dir}" \
                "  url:    ${url}" \
                "  reason: forges.github.url does not look like a GitHub URL" >&2
            failed=$((failed + 1))
            continue
            ;;
    esac

    if ! git -C "${project_dir}" rev-parse --verify HEAD > /dev/null 2>&1; then
        printf '%s\n' \
            "FAIL ${project_dir}" \
            "  url:    ${url}" \
            "  reason: no commits (HEAD unborn)" >&2
        failed=$((failed + 1))
        continue
    fi

    err="$(mktemp)"
    if git -C "${project_dir}" push --dry-run --porcelain "${url}" HEAD > /dev/null 2> "${err}"; then
        printf '%s\n' "OK ${project_dir}"
        ok=$((ok + 1))
    else
        detail="$(tr '\n' ' ' < "${err}" | sed 's/[[:space:]]\{1,\}/ /g')"
        printf '%s\n' \
            "FAIL ${project_dir}" \
            "  url:    ${url}" \
            "  reason: git push --dry-run failed${detail:+ (${detail})}" >&2
        failed=$((failed + 1))
    fi
    rm -f "${err}"
done < "${tmp}"

printf '%s\n' "ok=${ok} failed=${failed} skipped=${skipped}"

if [ "${failed}" -ne 0 ]; then
    exit 1
fi
exit 0

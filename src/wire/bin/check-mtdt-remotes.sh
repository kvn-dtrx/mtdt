#!/usr/bin/env sh

# ---
# description: >-
#   Check (default) or fix (--fix) git origin/upstream against mtdt forges.
#   Own repo: origin ← base forges.github.url (no upstream).
#   Fork (local URL ≠ base): origin ← local, upstream ← base.
#   Check exits 1 on divergence; --fix runs git remote add/set-url/remove.
#   Write URL scheme from gitconfig (mtdt.githubProtocol or url.*.insteadOf);
#   identity still compared protocol-agnostically. Coloured via log-*.
# ---

# ---

set -o errexit
set -o nounset

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
repo_logging="$(CDPATH='' cd -- "${script_dir}/../logging/libexec" 2> /dev/null && pwd || true)"

if [ -n "${repo_logging}" ] && [ -f "${repo_logging}/env.sh" ]; then
    # shellcheck source=/dev/null
    . "${repo_logging}/env.sh"
    case ":${PATH}:" in
        *":${repo_logging}:"*) ;;
        *)
            PATH="${repo_logging}:${PATH}"
            export PATH
            ;;
    esac
elif [ -f "${WIRE_LIBEXEC_SHARED:-${HOME}/.local/libexec/logging}/env.sh" ]; then
    # shellcheck source=/dev/null
    . "${WIRE_LIBEXEC_SHARED:-${HOME}/.local/libexec/logging}/env.sh"
fi

usage() {
    log-info "Usage: check-mtdt-remotes [--fix] [DIR...]"
    log-debug "Default: report origin/upstream drift vs mtdt (exit 1 if any)."
    log-debug "--fix:   git remote add/set-url/remove to match mtdt."
    log-debug "  no fork:  origin ← .mtdt.yaml; drop upstream if present"
    log-debug "  fork:     origin ← .mtdt.local.yaml; upstream ← .mtdt.yaml"
    log-debug "  scheme:   git config mtdt.githubProtocol (ssh|https) or"
    log-debug "            url.<ssh>.insteadOf https://github.com/ (and reverse)"
}

fix=0
roots_tmp="$(mktemp)"
list_tmp="$(mktemp)"
trap 'rm -f "${roots_tmp}" "${list_tmp}"' EXIT

while [ "$#" -gt 0 ]; do
    case "${1}" in
        --fix | --apply)
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
            log-error "Unknown option: ${1}"
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

while IFS= read -r root; do
    [ -n "${root}" ] || continue
    find "${root}" -type f -iname ".mtdt.yaml" >> "${list_tmp}"
done < "${roots_tmp}"

canon_github() {
    printf '%s' "${1}" | tr '[:upper:]' '[:lower:]' | sed -E \
        -e 's#^git@github\.com:#https://github.com/#' \
        -e 's#^ssh://git@github\.com/#https://github.com/#' \
        -e 's#\.git$##' \
        -e 's#/$##'
}

github_owner_repo() {
    canon_github "${1}" | sed -E 's#^https://github\.com/##'
}

url_scheme() {
    case "${1}" in
        git@* | ssh://*)
            printf 'ssh\n'
            ;;
        https://* | http://*)
            printf 'https\n'
            ;;
        *)
            printf 'other\n'
            ;;
    esac
}

# Prefer mtdt.githubProtocol, else url.*.insteadOf between github https↔ssh.
infer_github_scheme() {
    dir="${1}"
    explicit="$(git -C "${dir}" config --get mtdt.githubProtocol 2> /dev/null || true)"
    case "${explicit}" in
        ssh | https)
            printf '%s\n' "${explicit}"
            return 0
            ;;
    esac

    prefer_ssh=0
    prefer_https=0
    # shellcheck disable=SC2162
    while read -r key val; do
        [ -n "${key}" ] || continue
        base="${key#url.}"
        base="$(printf '%s' "${base}" | sed -E 's/\.[Ii]nstead[Oo]f$//')"
        base_l="$(printf '%s' "${base}" | tr '[:upper:]' '[:lower:]')"
        val_l="$(printf '%s' "${val}" | tr '[:upper:]' '[:lower:]')"
        case "${val_l}" in
            https://github.com* | http://github.com*)
                case "${base_l}" in
                    git@github.com:* | ssh://git@github.com*)
                        prefer_ssh=1
                        ;;
                esac
                ;;
            git@github.com:* | ssh://git@github.com*)
                case "${base_l}" in
                    https://github.com*)
                        prefer_https=1
                        ;;
                esac
                ;;
        esac
    done << EOF
$(git -C "${dir}" config --get-regexp '^url\..*\.insteadof$' 2> /dev/null || true)
EOF

    if [ "${prefer_ssh}" -eq 1 ] && [ "${prefer_https}" -eq 0 ]; then
        printf 'ssh\n'
    elif [ "${prefer_https}" -eq 1 ] && [ "${prefer_ssh}" -eq 0 ]; then
        printf 'https\n'
    else
        printf '\n'
    fi
}

# Rewrite a github URL to the preferred scheme; empty scheme → leave as-is.
prefer_github_url() {
    url="${1}"
    scheme="${2}"
    owner_repo="$(github_owner_repo "${url}")"
    if [ -z "${owner_repo}" ] || [ "${owner_repo}" = "${url}" ]; then
        printf '%s\n' "${url}"
        return 0
    fi
    case "${scheme}" in
        ssh)
            printf 'git@github.com:%s.git\n' "${owner_repo}"
            ;;
        https)
            printf 'https://github.com/%s\n' "${owner_repo}"
            ;;
        *)
            printf '%s\n' "${url}"
            ;;
    esac
}

remote_get() {
    git -C "${1}" remote get-url "${2}" 2> /dev/null || true
}

remote_has() {
    git -C "${1}" remote 2> /dev/null | grep -qxF "${2}"
}

# Compare current remote URL to desired write URL; echo action: ok|set|add
# want is already scheme-adjusted. Identity match + matching scheme ⇒ ok.
remote_plan() {
    dir="${1}"
    name="${2}"
    want="${3}"
    prefer_scheme="${4}"
    if remote_has "${dir}" "${name}"; then
        cur="$(remote_get "${dir}" "${name}")"
        if [ "$(canon_github "${cur}")" != "$(canon_github "${want}")" ]; then
            printf 'set\n'
            return 0
        fi
        if [ -n "${prefer_scheme}" ] &&
            [ "$(url_scheme "${cur}")" != "${prefer_scheme}" ]; then
            printf 'set\n'
            return 0
        fi
        printf 'ok\n'
    else
        printf 'add\n'
    fi
}

ok=0
skipped=0
diverge=0
fixed=0

while IFS="" read -r file; do
    [ -n "${file}" ] || continue
    project_dir="$(CDPATH='' cd -- "$(dirname "${file}")" && pwd)"
    local_file="${project_dir}/.mtdt.local.yaml"

    if [ ! -d "${project_dir}/.git" ] &&
        ! git -C "${project_dir}" rev-parse --git-dir > /dev/null 2>&1; then
        log-debug "skip ${project_dir}: not a git checkout"
        skipped=$((skipped + 1))
        continue
    fi

    base_url="$(yq -r '.forges.github.url // ""' "${file}")"
    if [ -z "${base_url}" ] || [ "${base_url}" = "null" ]; then
        log-debug "skip ${project_dir}: forges.github.url unset in .mtdt.yaml"
        skipped=$((skipped + 1))
        continue
    fi

    local_url=""
    if [ -f "${local_file}" ]; then
        local_url="$(yq -r '.forges.github.url // ""' "${local_file}")"
        if [ "${local_url}" = "null" ]; then
            local_url=""
        fi
    fi

    is_fork=0
    if [ -n "${local_url}" ] &&
        [ "$(canon_github "${local_url}")" != "$(canon_github "${base_url}")" ]; then
        is_fork=1
    fi

    if [ "${is_fork}" -eq 1 ]; then
        origin_url="${local_url}"
        upstream_url="${base_url}"
        kind="fork"
    else
        origin_url="${base_url}"
        upstream_url=""
        kind="own"
    fi

    prefer_scheme="$(infer_github_scheme "${project_dir}")"
    origin_url="$(prefer_github_url "${origin_url}" "${prefer_scheme}")"
    if [ -n "${upstream_url}" ]; then
        upstream_url="$(prefer_github_url "${upstream_url}" "${prefer_scheme}")"
    fi

    origin_action="$(remote_plan "${project_dir}" origin "${origin_url}" "${prefer_scheme}")"
    upstream_action="ok"
    drop_upstream=0
    if [ "${is_fork}" -eq 1 ]; then
        upstream_action="$(remote_plan "${project_dir}" upstream "${upstream_url}" "${prefer_scheme}")"
    elif remote_has "${project_dir}" upstream; then
        drop_upstream=1
        upstream_action="drop"
    fi

    if [ "${origin_action}" = "ok" ] && [ "${upstream_action}" = "ok" ]; then
        log-debug "ok ${kind} ${project_dir}"
        ok=$((ok + 1))
        continue
    fi

    diverge=$((diverge + 1))
    log-warn "DIVERGE ${kind} ${project_dir}"

    if [ "${origin_action}" = "set" ]; then
        cur="$(remote_get "${project_dir}" origin)"
        if [ "${fix}" -eq 1 ]; then
            git -C "${project_dir}" remote set-url origin "${origin_url}"
            log-info "origin: set-url ${origin_url} (was ${cur})"
        else
            log-warn "origin: ${cur} → ${origin_url}"
        fi
    elif [ "${origin_action}" = "add" ]; then
        if [ "${fix}" -eq 1 ]; then
            git -C "${project_dir}" remote add origin "${origin_url}"
            log-info "origin: add ${origin_url}"
        else
            log-warn "origin: missing → ${origin_url}"
        fi
    else
        log-debug "origin: ok ($(remote_get "${project_dir}" origin))"
    fi

    if [ "${is_fork}" -eq 1 ]; then
        if [ "${upstream_action}" = "set" ]; then
            cur="$(remote_get "${project_dir}" upstream)"
            if [ "${fix}" -eq 1 ]; then
                git -C "${project_dir}" remote set-url upstream "${upstream_url}"
                log-info "upstream: set-url ${upstream_url} (was ${cur})"
            else
                log-warn "upstream: ${cur} → ${upstream_url}"
            fi
        elif [ "${upstream_action}" = "add" ]; then
            if [ "${fix}" -eq 1 ]; then
                git -C "${project_dir}" remote add upstream "${upstream_url}"
                log-info "upstream: add ${upstream_url}"
            else
                log-warn "upstream: missing → ${upstream_url}"
            fi
        else
            log-debug "upstream: ok ($(remote_get "${project_dir}" upstream))"
        fi
    elif [ "${drop_upstream}" -eq 1 ]; then
        cur="$(remote_get "${project_dir}" upstream)"
        if [ "${fix}" -eq 1 ]; then
            git -C "${project_dir}" remote remove upstream
            log-info "upstream: removed (was ${cur})"
        else
            log-warn "upstream: unexpected → remove (${cur})"
        fi
    fi

    if [ "${fix}" -eq 1 ]; then
        fixed=$((fixed + 1))
    fi
done < "${list_tmp}"

log-info "ok=${ok} diverge=${diverge} fixed=${fixed} skipped=${skipped} fix=${fix}"

if [ "${diverge}" -ne 0 ] && [ "${fix}" -eq 0 ]; then
    exit 1
fi
exit 0

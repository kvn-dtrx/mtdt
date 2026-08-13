# ---
# description: >-
#   Idempotent PATH prepend for repo-wide script helpers (log-*).
#   Source from hooks and non-stub entry points:
#     . "${WIRE_LIBEXEC_SHARED:-${HOME}/.local/libexec/logging}/env.sh"
# ---

# ---

WIRE_LIBEXEC_SHARED="${WIRE_LIBEXEC_SHARED:-${HOME}/.local/libexec/logging}"
export WIRE_LIBEXEC_SHARED
case ":${PATH}:" in
    *":${WIRE_LIBEXEC_SHARED}:"*) ;;
    *) PATH="${WIRE_LIBEXEC_SHARED}:${PATH}"; export PATH ;;
esac

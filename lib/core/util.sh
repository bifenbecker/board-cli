# shellcheck shell=sh

BOARD_EXIT_ERROR=1
BOARD_EXIT_USAGE=2
BOARD_EXIT_UNSUPPORTED=3
BOARD_EXIT_NOT_FOUND=4
BOARD_EXIT_AUTH=5
BOARD_EXIT_PARTIAL=6
BOARD_EXIT_CONFLICT=7

BOARD_INSTALL_URL=https://raw.githubusercontent.com/bifenbecker/board-cli/main/install.sh

board_warn() {
    printf 'board: %s\n' "$*" >&2
}

board_die() {
    board_warn "$@"
    exit "$BOARD_EXIT_ERROR"
}

board_usage_die() {
    board_warn "$@"
    if [ -n "${BOARD_PATH:-}" ]; then
        printf "Run 'board %s --help' for usage.\n" "$BOARD_PATH" >&2
    else
        printf "Run 'board --help' for usage.\n" >&2
    fi
    exit "$BOARD_EXIT_USAGE"
}

board_unsupported() {
    board_warn "${1:-board ${BOARD_PATH:-}} is not supported on ${BOARD_KIND:-this board}"
    exit "$BOARD_EXIT_UNSUPPORTED"
}

board_not_found() {
    board_warn "$@"
    exit "$BOARD_EXIT_NOT_FOUND"
}

board_auth_die() {
    board_warn "$@"
    exit "$BOARD_EXIT_AUTH"
}

# The issue is not where the caller saw it, so nothing was written.
board_conflict() {
    board_warn "conflict: $*"
    exit "$BOARD_EXIT_CONFLICT"
}

# A write went through and a later step did not. The id goes to stdout so a caller holds it and
# does not repeat the write.
# Usage: board_partial <id> <message>
board_partial() {
    printf '%s\n' "$1"
    board_warn "partial: $2"
    exit "$BOARD_EXIT_PARTIAL"
}

# Ends a command whose adapter call failed, inside $(...). Exit 6 promises the id on stdout, and
# the id went into the variable that captured the call.
# Usage: board_doc=$(board_call ...) || board_fail "$?" "$board_doc"
board_fail() {
    if [ "$1" = "$BOARD_EXIT_PARTIAL" ] && [ -n "$2" ]; then
        printf '%s\n' "$2"
    fi
    exit "$1"
}

board_require() {
    command -v "$1" >/dev/null 2>&1 || board_die "$1 is required${2:+ ($2)}; install it and retry"
}

# jq built for Windows writes CRLF unless given -b. Only that build needs it, and only Git Bash and
# Cygwin have /usr/bin/cygpath, so other systems skip the probe and its process.
board_jq_probe() {
    BOARD_JQ_BINARY=
    if [ -x /usr/bin/cygpath ] && command jq -b -n null >/dev/null 2>&1; then
        BOARD_JQ_BINARY=1
    fi
    export BOARD_JQ_BINARY
}

# Always 0 or 1: jq's own codes 2, 3 and 5 would read as board's.
_jq() {
    if [ -n "${BOARD_JQ_BINARY:-}" ]; then
        command jq -b -L "$BOARD_HOME/lib" "$@" || return 1
    else
        command jq -L "$BOARD_HOME/lib" "$@" || return 1
    fi
}

board_is_true() {
    case ${1:-} in
        '' | 0 | false | no) return 1 ;;
        *) return 0 ;;
    esac
}

# One directory per run, shared with the subshells of $(...) and removed by the main process.
board_tmp_init() {
    [ -z "${BOARD_TMP:-}" ] || return 0
    BOARD_TMP=$(mktemp -d 2>/dev/null) || board_die "cannot create a temporary directory"
    BOARD_OUT=$BOARD_TMP/out
    BOARD_ERR=$BOARD_TMP/err
    export BOARD_TMP BOARD_OUT BOARD_ERR
    trap 'rm -rf "$BOARD_TMP"' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

board_urlencode() {
    printf '%s' "$1" | _jq -sRr '@uri'
}

# Newline-separated list helpers: arrays do not exist in POSIX sh.
board_list_add() {
    if [ -n "$1" ]; then
        printf '%s\n%s' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

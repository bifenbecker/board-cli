# shellcheck shell=sh

# Helpers for command parsers. Global flags are stripped earlier, in board_main.

board_arg() {
    [ $# -ge 2 ] || board_usage_die "$1 needs a value"
}

board_unknown_flag() {
    board_usage_die "unknown flag '$1'"
}

board_unexpected() {
    board_usage_die "unexpected argument '$1'"
}

# Usage: board_read_body_file <path|->  — sets BOARD_BODY.
board_read_body_file() {
    if [ "$1" = - ]; then
        BOARD_BODY=$(cat) || board_die "cannot read stdin"
    else
        [ -f "$1" ] || board_die "file not found: $1"
        BOARD_BODY=$(cat -- "$1") || board_die "cannot read $1"
    fi
    BOARD_BODY_SET=1
}

board_require_body() {
    [ -n "${BOARD_BODY_SET:-}" ] || board_usage_die "${1:-text} is required: pass --body <text> or --body-file <path|->"
    [ -n "$BOARD_BODY" ] || board_usage_die "${1:-text} is empty"
}

board_require_id() {
    [ -n "$1" ] || board_usage_die "<id> is required"
    case $1 in
        -*) board_usage_die "<id> must not start with a dash, got '$1'" ;;
    esac
}

board_require_int() {
    case $2 in
        '' | *[!0-9]*) board_usage_die "$1 must be a number, got '$2'" ;;
    esac
}

board_require_one_of() {
    board_roo_name=$1
    board_roo_value=$2
    shift 2
    for board_roo_allowed in "$@"; do
        [ "$board_roo_value" = "$board_roo_allowed" ] && return 0
    done
    board_usage_die "$board_roo_name must be one of: $*"
}

# Must be yyyy-mm-dd: every board stores a due date that way.
board_require_date() {
    case $2 in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
        *) board_usage_die "$1 must be YYYY-MM-DD, got '$2'" ;;
    esac
}

# Usage: board_require_limit <value>  — "all" or a positive number.
board_require_limit() {
    [ "$1" = all ] && return 0
    board_require_int --limit "$1"
    [ "$1" -gt 0 ] || board_usage_die "--limit must be at least 1, or all"
}

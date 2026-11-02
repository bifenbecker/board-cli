# shellcheck shell=sh

# Running provider tools. A provider tool has no timeout of its own, and a hung one must not hang
# the agent that called board, so everything goes through board_exec.

BOARD_TIMEOUT=${BOARD_TIMEOUT:-60}
case $BOARD_TIMEOUT in
    '' | 0 | *[!0-9]*) BOARD_TIMEOUT=60 ;;
esac
BOARD_EXIT_TIMEOUT=124

# Colour, pagers, prompts and update notices all break a parsed answer.
NO_COLOR=1
GH_PROMPT_DISABLED=1
GH_NO_UPDATE_NOTIFIER=1
GH_PAGER='cat'
GLAB_CHECK_UPDATE=false
GLAB_PAGER='cat'
PAGER='cat'
export NO_COLOR GH_PROMPT_DISABLED GH_NO_UPDATE_NOTIFIER GH_PAGER GLAB_CHECK_UPDATE GLAB_PAGER PAGER

# The probe runs the tool: on Windows a bare "timeout" can be System32's, which sleeps instead.
board_timeout_probe() {
    BOARD_TIMEOUT_CMD=
    BOARD_TIMEOUT_KILL=
    for board_tp_cmd in timeout gtimeout; do
        if command -v "$board_tp_cmd" >/dev/null 2>&1 && "$board_tp_cmd" 5 true >/dev/null 2>&1; then
            BOARD_TIMEOUT_CMD=$board_tp_cmd
            # A tool that ignores TERM would outlive the timeout without this.
            if "$board_tp_cmd" -k 1 5 true >/dev/null 2>&1; then
                BOARD_TIMEOUT_KILL=1
            fi
            break
        fi
    done
    export BOARD_TIMEOUT_CMD BOARD_TIMEOUT_KILL
}

# For a system without timeout(1). A background job starts with /dev/null as stdin, so stdin is
# kept on fd 3 and handed over. The watchdog polls rather than sleeping the whole timeout, so it
# ends with the command; its stdout is closed so it cannot hold a $(...) open.
board_watchdog() {
    exec 3<&0
    "$@" <&3 3<&- &
    board_wd_pid=$!
    exec 3<&-
    (
        board_wd_left=$BOARD_TIMEOUT
        while [ "$board_wd_left" -gt 0 ]; do
            sleep 1
            kill -0 "$board_wd_pid" 2>/dev/null || exit 0
            board_wd_left=$((board_wd_left - 1))
        done
        kill "$board_wd_pid" 2>/dev/null
        sleep 5
        kill -9 "$board_wd_pid" 2>/dev/null
    ) >/dev/null 2>&1 </dev/null &
    board_wd_status=0
    wait "$board_wd_pid" || board_wd_status=$?
    case $board_wd_status in
        143 | 137) return "$BOARD_EXIT_TIMEOUT" ;;
    esac
    return "$board_wd_status"
}

# Usage: board_exec <command> [args...]
# Stdin passes through. Stdout goes to $BOARD_OUT and stderr to $BOARD_ERR, read by the caller
# right after. Returns the command's status; 124 means it timed out, whichever timeout ran it.
board_exec() {
    board_ex_status=0
    if [ -n "${BOARD_TIMEOUT_KILL:-}" ]; then
        "$BOARD_TIMEOUT_CMD" -k 5 "$BOARD_TIMEOUT" "$@" >"$BOARD_OUT" 2>"$BOARD_ERR" || board_ex_status=$?
    elif [ -n "${BOARD_TIMEOUT_CMD:-}" ]; then
        "$BOARD_TIMEOUT_CMD" "$BOARD_TIMEOUT" "$@" >"$BOARD_OUT" 2>"$BOARD_ERR" || board_ex_status=$?
    else
        board_watchdog "$@" >"$BOARD_OUT" 2>"$BOARD_ERR" || board_ex_status=$?
    fi
    case $board_ex_status in
        143 | 137) return "$BOARD_EXIT_TIMEOUT" ;;
    esac
    return "$board_ex_status"
}

# Prints an id on the stdout of board itself (fd 9, opened by bin/board), so a call inside $(...)
# cannot swallow it. Without fd 9, as in a unit test of a single function, plain stdout.
# Usage: board_print_id <id>
board_print_id() {
    if { true >&9; } 2>/dev/null; then
        printf '%s\n' "$1" >&9
    else
        printf '%s\n' "$1"
    fi
}

# A tool ran out of time. A read failed; a write may or may not have happened, so it must not be
# repeated blindly. BOARD_WRITE starts as "this command writes": an adapter's transport narrows it
# to each call, so a read that times out before any write stays a plain failure.
board_timed_out() {
    if [ -n "${BOARD_WRITE:-}" ]; then
        [ -z "${BOARD_WRITE_ID:-}" ] || board_print_id "$BOARD_WRITE_ID"
        board_warn "timed out after ${BOARD_TIMEOUT}s: the write may have gone through. Check before repeating it"
        return "$BOARD_EXIT_PARTIAL"
    fi
    board_warn "timed out after ${BOARD_TIMEOUT}s"
    return "$BOARD_EXIT_ERROR"
}

# Saves the raw answer as a fixture when BOARD_RECORD names a directory. Headers are never saved.
# Usage: board_record <name>
board_record() {
    [ -n "${BOARD_RECORD:-}" ] || return 0
    mkdir -p "$BOARD_RECORD"
    sed 's/"emailAddress":"[^"]*"/"emailAddress":"user@example.com"/g; s/"email":"[^"]*"/"email":"user@example.com"/g' \
        "$BOARD_OUT" >"$BOARD_RECORD/$1.json"
}

# The fixture name of a REST call: the same rule as tests/fake/_fake.sh.
# Usage: board_rest_key <method> <path>
board_rest_key() {
    printf '%s_%s' "$1" "${2%%\?*}" | sed 's/[^A-Za-z0-9.-]\{1,\}/_/g; s/_$//'
}

# The first line of stderr with terminal escapes gone, for an error message.
board_err_line() {
    sed 's/\x1b\[[0-9;]*m//g' "$BOARD_ERR" | sed '/^[[:space:]]*$/d' | head -n 1
}

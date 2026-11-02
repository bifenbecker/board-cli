# shellcheck shell=sh

# Loads the core the way bin/board does, without running a command.
exec_load() {
    BOARD_HOME=$BOARD_TEST_ROOT
    export BOARD_HOME
    for lib in util exec; do
        . "$BOARD_HOME/lib/core/$lib.sh"
    done
    board_jq_probe
    board_tmp_init
}

test_exec_splits_stdout_and_stderr() {
    exec_load
    board_timeout_probe
    board_exec sh -c 'echo out; echo err >&2' || t_fail "exec failed"
    t_eq "$(cat "$BOARD_OUT")" out stdout
    t_eq "$(cat "$BOARD_ERR")" err stderr
}

test_exec_passes_stdin_through() {
    exec_load
    board_timeout_probe
    printf 'строка\n' | board_exec cat || t_fail "exec failed"
    t_eq "$(cat "$BOARD_OUT")" строка stdin
}

test_exec_returns_the_status() {
    exec_load
    board_timeout_probe
    board_st=0
    board_exec sh -c 'exit 7' || board_st=$?
    t_eq "$board_st" 7 status
}

test_timeout_is_124() {
    exec_load
    board_timeout_probe
    BOARD_TIMEOUT=1
    board_st=0
    board_exec sleep 10 || board_st=$?
    t_eq "$board_st" 124 status
}

test_watchdog_passes_stdin_and_status() {
    exec_load
    BOARD_TIMEOUT_CMD=
    board_st=0
    printf 'in\n' | board_exec sh -c 'cat; exit 3' || board_st=$?
    t_eq "$board_st" 3 status
    t_eq "$(cat "$BOARD_OUT")" in stdout
}

test_watchdog_kills_a_hung_command() {
    exec_load
    BOARD_TIMEOUT_CMD=
    BOARD_TIMEOUT=1
    board_st=0
    board_exec sleep 10 </dev/null || board_st=$?
    t_eq "$board_st" 124 status
}

test_err_line_strips_colour() {
    exec_load
    board_timeout_probe
    board_exec sh -c 'printf "\n\033[31mboom\033[0m\nmore\n" >&2' || true
    t_eq "$(board_err_line)" boom line
}

test_urlencode_handles_cyrillic_and_spaces() {
    exec_load
    t_eq "$(board_urlencode 'a b/я')" 'a%20b%2F%D1%8F' encoded
}

test_cut_warns_when_it_truncates() {
    exec_load
    . "$BOARD_HOME/lib/core/gql.sh"
    printf '[1,2,3]' >in
    board_cut 2 <in >out 2>err
    t_eq "$(cat out)" '[1,2]' list
    t_contains "$(cat err)" 'more exist' warning
    board_cut 3 <in >out 2>err
    t_eq "$(cat err)" '' 'no warning at the limit'
}

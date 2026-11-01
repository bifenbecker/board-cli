# shellcheck shell=sh

# Assertions for tests/unit and tests/contract. A test file is a plain script: each case is a
# function named test_*, run by tests/run.sh in its own subshell.

TEST_FAILED=0

t_fail() {
    printf '    %s\n' "$*" >&2
    TEST_FAILED=1
}

# Usage: t_run <command...>  — runs it, leaving T_OUT, T_ERR and T_STATUS.
t_run() {
    T_STATUS=0
    "$@" >"$T_TMP/out" 2>"$T_TMP/err" || T_STATUS=$?
    T_OUT=$(cat "$T_TMP/out")
    T_ERR=$(cat "$T_TMP/err")
}

board() {
    sh "$BOARD_TEST_ROOT/bin/board" "$@"
}

t_eq() {
    [ "$1" = "$2" ] || t_fail "${3:-value}: expected [$2], got [$1]"
}

t_status() {
    [ "$T_STATUS" = "$1" ] || t_fail "exit: expected $1, got $T_STATUS; stderr: $T_ERR"
}

t_contains() {
    case $1 in
        *"$2"*) ;;
        *) t_fail "${3:-output} lacks [$2]: [$1]" ;;
    esac
}

t_lacks() {
    case $1 in
        *"$2"*) t_fail "${3:-output} has [$2]: [$1]" ;;
    esac
}

# Usage: t_jq <json> <filter> <expected>
t_jq() {
    t_jq_got=$(printf '%s' "$1" | t_jq_cmd -c "$2") || {
        t_fail "jq failed on [$2]: [$1]"
        return 0
    }
    t_eq "$t_jq_got" "$3" "$2"
}

t_jq_cmd() {
    jq -b "$@" 2>/dev/null || jq "$@"
}

# Writes a workflow.toml into the test's directory, from stdin, and points board at it.
t_workflow() {
    cat >"$T_TMP/workflow.toml"
    WORKFLOW_FILE=$T_TMP/workflow.toml
    export WORKFLOW_FILE
}

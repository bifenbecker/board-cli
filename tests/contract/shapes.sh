# shellcheck shell=sh

# The promise of board: the same keys and types from every adapter. Each case replays answers
# recorded from a real board through the adapter and checks the result against lib/schema/.
# A board joins by having tests/fixtures/<dir>/contract.env, which names a recorded issue.

shape_check() {
    # Usage: shape_check <schema name> <json> <array|object>
    shape_problems=$(printf '%s' "$2" | jq -r -L "$BOARD_TEST_ROOT/lib" \
        --slurpfile spec "$BOARD_TEST_ROOT/lib/schema/$1.json" --arg mode "$3" '
        include "jq/schema";
        (if $mode == "array" then .[] else . end) | [schema_problems($spec[0])] | .[]' 2>&1)
    [ -z "$shape_problems" ] || t_fail "$SHAPE_KIND $1: $shape_problems"
}

# Usage: shape_board <kind> <fixture dir>
shape_board() {
    SHAPE_KIND=$1
    shape_dir=$BOARD_TEST_ROOT/tests/fixtures/$2
    [ -f "$shape_dir/contract.env" ] || return 0
    . "$shape_dir/contract.env"
    WORKFLOW_FILE=$BOARD_TEST_ROOT/tests/live/$1.toml
    export WORKFLOW_FILE

    t_run board issue view "$ISSUE" --json
    t_status 0
    shape_check issue "$T_OUT" object
    t_jq "$T_OUT" ".id" "\"$ISSUE\""
    t_jq "$T_OUT" ".kind" "\"$1\""

    t_run board issue list --category all --json
    t_status 0
    shape_check issue "$T_OUT" array
    t_jq "$T_OUT" 'length > 0' true

    t_run board issue comment list "$ISSUE" --json
    t_status 0
    shape_check comment "$T_OUT" array

    t_run board status list --json
    t_status 0
    shape_check status "$T_OUT" array

    t_run board member list --json
    t_status 0
    shape_check member "$T_OUT" array

    t_run board milestone list --state all --json
    case $T_STATUS in
        0) shape_check milestone "$T_OUT" array ;;
        3) ;;
        *) t_fail "$1 milestone list: exit $T_STATUS: $T_ERR" ;;
    esac

    t_run board label list --json
    case $T_STATUS in
        0) shape_check label "$T_OUT" array ;;
        3) ;;
        *) t_fail "$1 label list: exit $T_STATUS: $T_ERR" ;;
    esac
}

test_github_shapes() {
    shape_board github gh
}

test_gitlab_shapes() {
    shape_board gitlab glab
}

test_linear_shapes() {
    shape_board linear linear
}

test_jira_shapes() {
    shape_board jira curl
}

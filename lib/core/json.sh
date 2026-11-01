# shellcheck shell=sh

board_json_mode() {
    [ -n "${BOARD_JSON:-}" ]
}

# True when this command changes the board. Its result must not read as a failure to repeat.
board_path_writes() {
    case " $BOARD_PATH " in
        *' create '* | *' edit '* | *' move '* | *' close '* | *' reopen '* | *' add '* | *' remove '* | *' rename '* | *' sync '* | *' init '*) return 0 ;;
    esac
    return 1
}

# Usage: <normalised JSON on stdin> | board_output <text filter from lib/jq/text.jq>
# --jq filters the JSON, --json prints it, and otherwise the text filter renders it. The filter was
# compiled before the command ran, so what fails here failed on this answer.
board_output() {
    board_o_doc=$(cat)
    [ -n "$board_o_doc" ] || board_die "the board gave no answer"
    if [ -n "${BOARD_JQ:-}" ]; then
        printf '%s\n' "$board_o_doc" | _jq -r "($BOARD_JQ
)" && return 0
        if board_path_writes; then
            printf '%s\n' "$board_o_doc"
            board_warn "partial: it went through, but --jq failed on the answer. The whole answer is above"
            exit "$BOARD_EXIT_PARTIAL"
        fi
        board_usage_die "--jq failed on this output: $BOARD_JQ"
    elif board_json_mode; then
        printf '%s\n' "$board_o_doc" | _jq . || board_die "the answer is not JSON"
    else
        printf '%s\n' "$board_o_doc" | _jq -r "include \"jq/text\"; $1" || board_die "the answer is not what was expected"
    fi
}

# A GraphQL input object as a literal, so a whole request travels on stdin. linear api takes
# variables only in argv, where Windows stops at 32k and a long description would not fit.
# shellcheck disable=SC2034  # read by lib/*/core.sh
BOARD_JQ_GQL='def gql:
    if type == "object" then
        "{" + (to_entries | map("\(.key):\(.value | gql)") | join(",")) + "}"
    elif type == "array" then
        "[" + (map(gql) | join(",")) + "]"
    else tojson end;'

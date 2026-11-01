# shellcheck shell=sh

board_json_mode() {
    [ -n "${BOARD_JSON:-}" ]
}

# Usage: <normalised JSON on stdin> | board_output <text filter from lib/jq/text.jq>
# --jq filters the JSON, --json prints it, and otherwise the text filter renders it.
board_output() {
    if [ -n "${BOARD_JQ:-}" ]; then
        _jq -r "$BOARD_JQ"
    elif board_json_mode; then
        _jq .
    else
        _jq -r "include \"jq/text\"; $1"
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

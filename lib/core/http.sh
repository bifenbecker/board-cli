# shellcheck shell=sh

# curl, for a board with no tool of its own. Everything but the URL is a config on stdin: a process
# list would show a token in argv, and Windows stops a body there at about 32,000 characters.

BOARD_HTTP_NL='
'

# A value quoted for a curl config. curl reads the same escapes JSON writes for quote, backslash,
# tab and line break, and a JSON body holds no raw control characters for it to lose.
# Usage: <value on stdin> | board_http_quote
board_http_quote() {
    _jq -Rrs tojson
}

# Usage: board_http <config function> <url>
# The function prints the curl config. On success the answer is in $BOARD_OUT and its status in
# BOARD_HTTP_STATUS. Returns curl's status: 124 is the timeout of board_exec. -q must stay first: it
# keeps ~/.curlrc out, where a location line would carry the token through a redirect.
board_http() {
    board_ht_status=0
    BOARD_HTTP_STATUS=''
    "$1" | board_exec curl -q -s -K - -w '\n%{http_code}' "$2" || board_ht_status=$?
    [ "$board_ht_status" = 0 ] || return "$board_ht_status"
    board_ht_raw=$(cat "$BOARD_OUT")
    BOARD_HTTP_STATUS=${board_ht_raw##*"$BOARD_HTTP_NL"}
    printf '%s' "${board_ht_raw%"$BOARD_HTTP_NL"*}" >"$BOARD_OUT"
}

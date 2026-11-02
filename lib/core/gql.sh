# shellcheck shell=sh

# Paging, shared by the adapters. A tool's own --paginate cannot stop at --limit, and it fails midway
# with partial output, so the loop lives here.

# Usage: board_paged <fetch function> <limit|all>
# The function takes a cursor, empty for the first page, and prints
# {nodes: [...normalised...], has_next: bool, end_cursor: string|null}. Prints the joined array,
# cut to the limit, and warns on stderr when more exist.
board_paged() {
    board_pg_fetch=$1
    board_pg_limit=$2
    board_pg_after=''
    board_pg_next=false
    board_pg_file=$BOARD_TMP/paged
    : >"$board_pg_file"
    while :; do
        board_pg_page=$("$board_pg_fetch" "$board_pg_after") || return $?
        board_pg_meta=$(printf '%s\n' "$board_pg_page" | _jq -r '
            if (.nodes | type) == "array" and (.has_next | type) == "boolean"
            then @sh "board_pg_next=\(.has_next | tostring) board_pg_cursor=\(.end_cursor // "" | tostring)"
            else error("bad page") end' 2>/dev/null) || board_die "the board gave a page that cannot be read"
        printf '%s\n' "$board_pg_page" | _jq -c '.nodes[]' >>"$board_pg_file" || board_die "the board gave a page that cannot be read"
        eval "$board_pg_meta"
        if [ "$board_pg_next" = true ] && [ "$board_pg_cursor" = "$board_pg_after" ]; then
            board_die "the board returned the same page twice"
        fi
        board_pg_after=$board_pg_cursor
        board_pg_count=$(wc -l <"$board_pg_file")
        if [ "$board_pg_limit" != all ] && [ "$board_pg_count" -ge "$board_pg_limit" ]; then
            break
        fi
        [ "$board_pg_next" = true ] || break
    done
    if [ "$board_pg_limit" = all ]; then
        _jq -sc . <"$board_pg_file"
        return 0
    fi
    if [ "$board_pg_count" -gt "$board_pg_limit" ] || [ "$board_pg_next" = true ]; then
        board_warn "showing the first $board_pg_limit; more exist: raise --limit, or pass --limit all"
    fi
    _jq -sc --argjson n "$board_pg_limit" '.[:$n]' <"$board_pg_file"
}

# Cuts a list read in one go to --limit, with the warning a truncated list owes.
# Usage: <JSON array on stdin> | board_cut <limit|all>
board_cut() {
    board_ct_doc=$(cat)
    if [ "$1" = all ]; then
        printf '%s' "$board_ct_doc"
        return 0
    fi
    if [ "$(printf '%s' "$board_ct_doc" | _jq 'length')" -gt "$1" ]; then
        board_warn "showing the first $1; more exist: raise --limit, or pass --limit all"
    fi
    printf '%s' "$board_ct_doc" | _jq -c --argjson n "$1" '.[:$n]'
}

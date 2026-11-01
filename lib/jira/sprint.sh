# shellcheck shell=sh

# Sprints live on a board, not on a project, and only the agile API reaches them.

jira_require_board() {
    [ -n "$JIRA_BOARD" ] || {
        board_warn "declare [board.target] board: the id of the Jira board that has the sprints"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    board_require_int "[board.target] board" "$JIRA_BOARD"
}

# On this endpoint a 400 has one meaning: The board does not support sprints. That is an answer about
# the board, so it is exit 3, and the only 400 in the adapter that is.
jira_sprint_page() {
    jira_sg_path=$(jira_paged_url "/rest/agile/1.0/board/$JIRA_BOARD/sprint${JIRA_SPRINT_STATE:+?state=$JIRA_SPRINT_STATE}" "$1" 50)
    jira_request GET "$jira_sg_path" || return $?
    if [ "$BOARD_HTTP_STATUS" = 400 ]; then
        board_warn "$(jira_error_line)"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    jira_check "$jira_sg_path" || return $?
    board_record "$(board_rest_key GET "$jira_sg_path")"
    _jq -c ''"$BOARD_LIB"'
        {nodes: (.values | map(jira_sprint)), has_next: (.isLast == false),
         end_cursor: (.startAt + (.values | length))}' <"$BOARD_OUT"
}

# Usage: jira_sprints [state]  — newest first. Ids grow with time; a future sprint has no date.
jira_sprints() {
    jira_require_board || return $?
    JIRA_SPRINT_STATE=${1:-}
    jira_sp_doc=$(board_paged jira_sprint_page all) || return $?
    printf '%s' "$jira_sp_doc" | _jq -c 'sort_by(.id | tonumber) | reverse'
}

jira_sprint_list() {
    jira_sl_state=''
    [ "$1" = all ] || jira_sl_state=$1
    jira_sl_doc=$(jira_sprints "$jira_sl_state") || return $?
    printf '%s' "$jira_sl_doc" | _jq -c --arg l "$2" 'if $l == "all" then . else .[:($l | tonumber)] end'
}

jira_sprint_view() {
    jira_safe "<id>" "$1"
    jira_sv_doc=$(jira_call GET "/rest/agile/1.0/sprint/$1") || return $?
    printf '%s' "$jira_sv_doc" | _jq -c ''"$BOARD_LIB"' jira_sprint'
}

jira_sprint_current() {
    jira_sc_doc=$(jira_sprints active) || return $?
    jira_sc_hit=$(printf '%s' "$jira_sc_doc" | _jq -c '[.[] | select(.state == "active")] | first // empty')
    [ -n "$jira_sc_hit" ] || {
        board_warn "no sprint is active"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$jira_sc_hit"
}

# Usage: jira_sprint_id <name|current>  — an open sprint, or exit 4.
jira_sprint_id() {
    jira_si_doc=$(jira_sprints active,future) || return $?
    jira_si_hit=$(printf '%s' "$jira_si_doc" | _jq -r --arg want "$1" '
        '"$BOARD_LIB"'
        [.[] | select(if $want == "current" then .state == "active" else (.name | ieq($want)) end) | .id] | first // ""')
    [ -n "$jira_si_hit" ] || {
        board_warn "no open sprint '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$jira_si_hit"
}

jira_sprint_assign() {
    jira_safe "a sprint" "$2"
    _jq -nc --arg k "$1" '{issues: [$k]}' | jira_send POST "/rest/agile/1.0/sprint/$2/issue" >/dev/null
}

# Out of a sprint is the backlog: the agile API has no other way to say it.
jira_sprint_clear() {
    jira_require_board || return $?
    _jq -nc --arg k "$1" '{issues: [$k]}' | jira_send POST /rest/agile/1.0/backlog/issue >/dev/null
}

# shellcheck shell=sh

# The answer is a bare array with no total, so a full page is the only sign of another.
jira_member_page() {
    jira_mp_doc=$(jira_call GET "$(jira_paged_url "$JIRA_MEMBER_PATH" "$1" 100)") || return $?
    printf '%s' "$jira_mp_doc" | _jq -c --argjson start "${1:-0}" '
        '"$BOARD_LIB"'
        {nodes: map(jira_user | make_member), has_next: (length == 100), end_cursor: ($start + length)}'
}

jira_member_list() {
    jira_require_project
    JIRA_MEMBER_PATH="/rest/api/2/user/assignable/search?project=$JIRA_PROJECT"
    if [ -n "$1" ]; then
        jira_ml_param=username
        [ -z "$JIRA_CLOUD" ] || jira_ml_param=query
        JIRA_MEMBER_PATH=$JIRA_MEMBER_PATH\&$jira_ml_param=$(board_urlencode "$1")
    fi
    board_paged jira_member_page all
}

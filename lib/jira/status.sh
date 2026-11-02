# shellcheck shell=sh

# Each issue type has its own list, and team-managed projects repeat the same one under every type.
jira_status_list() {
    jira_require_project
    jira_sl_doc=$(jira_call GET "/rest/api/2/project/$JIRA_PROJECT/statuses") || return $?
    printf '%s' "$jira_sl_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        reduce (.[].statuses[]) as $s ([]; if any(.[]; .id == $s.id) then . else . + [$s] end)
        | map(jira_status | make_status($cfg))'
}

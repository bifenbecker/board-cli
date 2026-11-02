# shellcheck shell=sh

jira_label_page() {
    jira_lp_doc=$(jira_call GET "$(jira_paged_url /rest/api/2/label "$1" 1000)") || return $?
    printf '%s' "$jira_lp_doc" | _jq -c '
        '"$BOARD_LIB"'
        {nodes: [.values[] | {name: .} | make_label],
         has_next: (.isLast == false), end_cursor: (.startAt + (.values | length))}'
}

# Labels of the site, as plain text. Data Center has no such list.
jira_label_list() {
    if [ -z "$JIRA_CLOUD" ]; then
        board_warn "Jira Data Center has no API that lists labels"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    board_paged jira_label_page all
}

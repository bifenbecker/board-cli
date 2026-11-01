# shellcheck shell=sh

# The GitLab adapter against the fake glab: what an answer means, and the status model on labels.

gitlab_board() {
    BOARD_TRUSTED_HOSTS='gitlab.example.com code.example.com git.corp:8443'
    export BOARD_TRUSTED_HOSTS
    t_workflow <<'EOF'
[board]
kind = "gitlab"
cli  = "glab"
url  = "https://gitlab.example.com/a/b"

[board.target]
board = 7

[board.statuses]
"zeta"    = "todo"
"alpha"   = "in_progress"
"done"    = "done"
"wontfix" = "canceled"

[board.priority]
high = "p::high"
low  = "p::low"
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    gl_answer GET_user '{"id":5,"username":"me","name":"Me"}'
}

gl_answer() {
    printf '%s' "$2" >"$FAKE_OVERRIDE/$1.json"
}

# Usage: gl_refuse <key> <body> <stderr>  — glab exits 1 for every HTTP error.
gl_refuse() {
    gl_answer "$1" "$2"
    printf '%s\n' "$3" >"$FAKE_OVERRIDE/$1.err"
    printf 1 >"$FAKE_OVERRIDE/$1.status"
}

gl_issue_json() {
    printf '{"id":100,"iid":1,"project_id":9,"title":"t","description":null,"state":"%s","labels":%s,"milestone":null,"assignees":[],"type":"ISSUE","due_date":null,"author":{"id":5,"username":"me","name":"Me"},"web_url":"https://gitlab.example.com/a/b/-/work_items/1","created_at":"2026-11-01T15:46:51.709Z","updated_at":"2026-11-01T15:46:51.709Z"}' \
        "${2:-opened}" "$1"
}

# Usage: gl_issue <labels JSON> [state]  — everything 'issue view' reads, and what a PUT answers.
gl_issue() {
    gl_answer GET_projects_a_2Fb_issues_1 "$(gl_issue_json "$1" "${2:-opened}")"
    gl_answer PUT_projects_a_2Fb_issues_1 "$(gl_issue_json "$1" "${2:-opened}")"
    gl_answer GET_projects_a_2Fb_issues_1_links '[]'
    gl_answer IssueHierarchy '{"data":{"project":{"workItems":{"nodes":[{"widgets":[{},{"parent":null,"children":{"nodes":[]}}]}]}}}}'
}

# The first JSON body sent. The same file holds the text of every GraphQL query.
gl_sent() {
    grep '^{"' "$FAKE_LOG.stdin" | head -n 1
}

# Usage: gl_workflow <sed script>  — sed -i differs between GNU and BSD.
gl_workflow() {
    sed "$1" "$WORKFLOW_FILE" >"$WORKFLOW_FILE.new"
    mv "$WORKFLOW_FILE.new" "$WORKFLOW_FILE"
}

gl_free_types() {
    gl_answer WorkItemTypes '{"data":{"project":{"workItemTypes":{"nodes":[{"id":"gid://gitlab/WorkItems::Type/1","name":"Issue","widgetDefinitions":[{"type":"ASSIGNEES"}]},{"id":"gid://gitlab/WorkItems::Type/5","name":"Task","widgetDefinitions":[{"type":"HIERARCHY"}]}]}}}}'
}

# --- what an answer means ----------------------------------------------------------------

test_401_is_not_authenticated() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"401 Unauthorized"}' 'glab: 401 Unauthorized (HTTP 401)'
    t_run board issue view 1
    t_status 5
}

test_403_with_a_license_is_not_supported() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"Blocked issues not available for current license"}' \
        'glab: Blocked issues not available for current license (HTTP 403)'
    t_run board issue view 1
    t_status 3
    t_contains "$T_ERR" license
}

test_other_403_is_not_allowed() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"403 Forbidden"}' 'glab: 403 Forbidden (HTTP 403)'
    t_run board issue view 1
    t_status 5
}

test_404_with_a_working_login_is_not_found() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"404 Not found"}' 'glab: 404 Not found (HTTP 404)'
    t_run board issue view 1
    t_status 4
    t_eq "$(grep -c 'GET user' "$FAKE_LOG")" 1 'calls to user'
}

test_404_with_a_dead_login_is_not_authenticated() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"404 Not found"}' 'glab: 404 Not found (HTTP 404)'
    gl_refuse GET_user '{"message":"401 Unauthorized"}' 'glab: 401 Unauthorized (HTTP 401)'
    t_run board issue view 1
    t_status 5
}

test_a_404_without_the_parentheses_counts_too() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"error":"404 Not Found"}' 'glab: HTTP 404'
    t_run board issue view 1
    t_status 4
}

test_a_server_error_is_a_failure() {
    gitlab_board
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"500 Internal Server Error"}' 'glab: 500 Internal Server Error (HTTP 500)'
    t_run board issue view 1
    t_status 1
}

test_validation_errors_read_as_text() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[]'
    gl_refuse POST_projects_a_2Fb_labels '{"message":{"color":["must be a valid color code"]}}' \
        'glab: map[message:map[color:[must be a valid color code]]]+'
    t_run board label create x
    t_status 1
    t_contains "$T_ERR" 'color must be a valid color code'
}

test_a_host_with_no_login_is_not_authenticated() {
    gitlab_board
    gl_refuse GET_user '' '   ERROR
  Unauthenticated.'
    t_run board auth status
    t_status 5
    t_contains "$T_ERR" Unauthenticated
}

test_graphql_with_a_missing_project_is_not_found() {
    gitlab_board
    gl_issue '[]'
    gl_answer IssueHierarchy '{"data":{"project":null}}'
    t_run board issue view 1
    t_status 4
}

test_graphql_with_a_missing_project_and_a_dead_login_is_not_authenticated() {
    gitlab_board
    gl_issue '[]'
    gl_answer IssueHierarchy '{"data":{"project":null}}'
    gl_refuse GET_user '{"message":"401 Unauthorized"}' 'glab: 401 Unauthorized (HTTP 401)'
    t_run board issue view 1
    t_status 5
}

test_graphql_with_a_bad_token_is_not_authenticated() {
    gitlab_board
    gl_issue '[]'
    gl_refuse IssueHierarchy '{"errors":[{"message":"Invalid token"}]}' 'glab: Invalid token'
    gl_refuse GET_user '{"message":"401 Unauthorized"}' 'glab: 401 Unauthorized (HTTP 401)'
    t_run board issue view 1
    t_status 5
}

test_graphql_error_with_a_working_login_is_a_failure() {
    gitlab_board
    gl_issue '[]'
    gl_refuse IssueHierarchy '{"errors":[{"message":"Query has complexity of 300"}]}' 'glab: Query has complexity of 300'
    t_run board issue view 1
    t_status 1
    t_contains "$T_ERR" complexity
}

test_a_read_that_times_out_is_a_failure() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues_1 ''
    printf 124 >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues_1.status"
    t_run board issue view 1
    t_status 1
    t_contains "$T_ERR" 'timed out'
}

test_a_write_that_times_out_is_partial() {
    gitlab_board
    gl_answer PUT_projects_a_2Fb_issues_1 ''
    printf 124 >"$FAKE_OVERRIDE/PUT_projects_a_2Fb_issues_1.status"
    t_run board issue move 1 done
    t_status 6
}

test_every_call_names_the_host() {
    gitlab_board
    gl_issue '[]'
    gl_answer POST_projects_a_2Fb_issues_1_notes '{"id":1,"body":"x","noteable_iid":1,"author":null}'
    t_run board issue view 1
    t_run board issue move 1 done
    t_run board issue comment add 1 --body x
    t_lacks "$(grep -v -- '--hostname gitlab.example.com' "$FAKE_LOG")" 'glab api' 'a call without --hostname'
}

test_a_body_stays_out_of_argv() {
    gitlab_board
    gl_answer POST_projects_a_2Fb_issues_1_notes '{"id":1,"body":"secret-text","noteable_iid":1,"author":null}'
    t_run board issue comment add 1 --body secret-text
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" secret-text argv
    t_contains "$(gl_sent)" secret-text stdin
}

test_board_url_may_name_a_subgroup_and_a_port() {
    gitlab_board
    gl_workflow 's#^url .*#url = "https://git.corp:8443/top/sub/proj.git"#'
    gl_answer GET_projects_top_2Fsub_2Fproj_boards_7 '{"id":7,"name":"B","lists":[]}'
    t_run board view --json
    t_status 0
    t_jq "$T_OUT" .url '"https://git.corp:8443/top/sub/proj/-/boards/7"'
    t_contains "$(cat "$FAKE_LOG")" '--hostname git.corp:8443'
}

# --- the status model --------------------------------------------------------------------

test_open_with_no_status_label_reads_as_todo() {
    gitlab_board
    gl_issue '["bug"]'
    t_run board issue view 1 --json
    t_status 0
    t_jq "$T_OUT" .status '{"name":null,"category":"todo"}'
    t_jq "$T_OUT" .labels '["bug"]'
}

test_closed_with_no_status_label_reads_as_done() {
    gitlab_board
    gl_issue '[]' closed
    t_run board issue view 1 --json
    t_jq "$T_OUT" .status '{"name":null,"category":"done"}'
}

test_status_and_priority_labels_stay_out_of_labels() {
    gitlab_board
    gl_issue '["alpha","bug","p::high"]'
    t_run board issue view 1 --json
    t_jq "$T_OUT" .status '{"name":"alpha","category":"in_progress"}'
    t_jq "$T_OUT" .labels '["bug"]'
    t_jq "$T_OUT" .priority '"high"'
}

test_two_statuses_take_the_first_declared_and_warn() {
    gitlab_board
    gl_issue '["alpha","zeta"]'
    t_run board issue view 1 --json
    t_status 0
    t_jq "$T_OUT" .status.name '"zeta"'
    t_contains "$T_ERR" 'zeta and alpha'
}

test_status_list_keeps_the_declared_order() {
    gitlab_board
    t_run board status list --json
    t_status 0
    t_jq "$T_OUT" 'map(.name)' '["zeta","alpha","done","wontfix"]'
    t_jq "$T_OUT" '.[1].category' '"in_progress"'
    [ ! -s "$FAKE_LOG" ] || t_fail "status list reached the board: $(cat "$FAKE_LOG")"
}

test_move_is_one_put_with_labels_and_state() {
    gitlab_board
    gl_issue '["done"]' closed
    t_run board issue move 1 done --json
    t_status 0
    t_eq "$(grep -c 'PUT' "$FAKE_LOG")" 1 PUTs
    t_jq "$(gl_sent)" . '{"add_labels":"done","remove_labels":"zeta,alpha,wontfix","state_event":"close"}'
}

test_move_to_canceled_closes() {
    gitlab_board
    gl_issue '["wontfix"]' closed
    t_run board issue move 1 wontfix --json
    t_jq "$(gl_sent)" .state_event '"close"'
}

test_move_to_an_open_status_reopens() {
    gitlab_board
    gl_issue '["alpha"]'
    t_run board issue move 1 ALPHA --json
    t_status 0
    t_jq "$(gl_sent)" . '{"add_labels":"alpha","remove_labels":"zeta,done,wontfix","state_event":"reopen"}'
}

test_move_to_an_unknown_status_lists_the_valid_ones() {
    gitlab_board
    t_run board issue move 1 nope
    t_status 2
    t_contains "$T_ERR" "no Status 'nope': the project has zeta, alpha, done, wontfix"
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

test_close_takes_the_first_status_of_the_reason() {
    gitlab_board
    gl_issue '["wontfix"]' closed
    t_run board issue close 1 --reason canceled --json
    t_status 0
    t_jq "$(gl_sent)" . '{"add_labels":"wontfix","remove_labels":"zeta,alpha,done","state_event":"close"}'
}

test_close_with_no_such_status_still_closes() {
    gitlab_board
    gl_workflow '/wontfix/d'
    gl_issue '[]' closed
    t_run board issue close 1 --reason canceled --json
    t_status 0
    t_jq "$(gl_sent)" . '{"remove_labels":"zeta,alpha,done","state_event":"close"}'
}

test_reopen_takes_the_first_todo_status() {
    gitlab_board
    gl_issue '["done"]' closed
    t_run board issue reopen 1 --json
    t_status 0
    t_jq "$(gl_sent)" . '{"add_labels":"zeta","remove_labels":"alpha,done,wontfix","state_event":"reopen"}'
}

test_reopen_takes_the_status_given() {
    gitlab_board
    gl_issue '["done"]' closed
    t_run board issue reopen 1 --status alpha --json
    t_status 0
    t_jq "$(gl_sent)" .add_labels '"alpha"'
    t_jq "$(gl_sent)" .state_event '"reopen"'
}

test_reopen_leaves_an_open_issue_alone() {
    gitlab_board
    gl_issue '["alpha"]'
    t_run board issue reopen 1 --json
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_a_status_nothing_declares_reads_with_no_status_name() {
    gitlab_board
    gl_issue '["other"]'
    t_run board issue view 1 --json
    t_jq "$T_OUT" .status.name null
    t_jq "$T_OUT" .labels '["other"]'
}

# --- priority ----------------------------------------------------------------------------

test_priority_swaps_the_label() {
    gitlab_board
    gl_issue '["p::low"]'
    t_run board issue edit 1 --priority low --json
    t_status 0
    t_jq "$(gl_sent)" . '{"add_labels":"p::low","remove_labels":"p::high"}'
}

test_priority_none_removes_every_priority_label() {
    gitlab_board
    gl_issue '[]'
    t_run board issue edit 1 --priority none --json
    t_status 0
    t_jq "$(gl_sent)" . '{"remove_labels":"p::high,p::low"}'
}

test_clear_priority_is_the_same() {
    gitlab_board
    gl_issue '[]'
    t_run board issue edit 1 --clear priority --json
    t_status 0
    t_jq "$(gl_sent)" . '{"remove_labels":"p::high,p::low"}'
}

test_an_undeclared_priority_is_not_supported() {
    gitlab_board
    gl_issue '[]'
    t_run board issue edit 1 --priority urgent
    t_status 3
    t_contains "$T_ERR" '[board.priority]'
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

# --- list --------------------------------------------------------------------------------

gl_list() {
    printf '[%s,%s,%s]' "$(gl_issue_json '["done"]' closed)" "$(gl_issue_json '["wontfix"]' closed)" \
        "$(gl_issue_json '[]' closed)" >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues.json"
}

test_the_open_default_asks_for_opened() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues '[]'
    t_run board issue list --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'state=opened'
    t_contains "$(cat "$FAKE_LOG")" 'order_by=updated_at'
}

test_open_is_neither_done_nor_canceled() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues "[$(gl_issue_json '["done"]'),$(gl_issue_json '["wontfix"]'),$(gl_issue_json '["alpha"]'),$(gl_issue_json '[]')]"
    t_run board issue list --json
    t_status 0
    t_jq "$T_OUT" 'map(.status.category)' '["in_progress","todo"]'
}

test_priority_none_lists_issues_without_one() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues "[$(gl_issue_json '["p::high"]'),$(gl_issue_json '[]')]"
    t_run board issue list --priority none --json
    t_status 0
    t_jq "$T_OUT" 'map(.priority)' '[null]'
    t_lacks "$(cat "$FAKE_LOG")" 'labels='
}

test_category_done_filters_on_this_side() {
    gitlab_board
    gl_list
    t_run board issue list --category done --json
    t_status 0
    t_jq "$T_OUT" 'length' 2
    t_jq "$T_OUT" 'map(.status.category) | unique' '["done"]'
    t_contains "$(cat "$FAKE_LOG")" 'state=all'
}

test_category_canceled_filters_on_this_side() {
    gitlab_board
    gl_list
    t_run board issue list --category canceled --json
    t_status 0
    t_jq "$T_OUT" 'map(.status.name)' '["wontfix"]'
}

test_status_filter_asks_for_the_declared_label() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues '[]'
    t_run board issue list --status ALPHA --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'labels=alpha'
    t_contains "$(cat "$FAKE_LOG")" 'state=all'
}

test_a_full_page_asks_for_the_next_one() {
    gitlab_board
    jq -cn --argjson i "$(gl_issue_json '[]')" '[range(100) | $i]' >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues.1.json"
    gl_answer GET_projects_a_2Fb_issues.2 "[$(gl_issue_json '[]')]"
    t_run board issue list --limit all --json
    t_status 0
    t_jq "$T_OUT" length 101
    t_contains "$(cat "$FAKE_LOG")" 'page=2'
}

test_limit_warns_when_more_exist() {
    gitlab_board
    gl_list
    t_run board issue list --category all --limit 1 --json
    t_status 0
    t_jq "$T_OUT" length 1
    t_contains "$T_ERR" 'more exist'
}

test_parent_filter_lists_the_children() {
    gitlab_board
    gl_answer IssueHierarchy '{"data":{"project":{"workItems":{"nodes":[{"widgets":[{"parent":null,"children":{"nodes":[{"iid":"1"}]}}]}]}}}}'
    gl_answer GET_projects_a_2Fb_issues "[$(gl_issue_json '[]')]"
    t_run board issue list --parent 9 --category all --json
    t_status 0
    t_jq "$T_OUT" '.[0].parent' '"9"'
    t_contains "$(cat "$FAKE_LOG")" 'iids%5B%5D=1'
}

test_a_parent_with_no_children_lists_nothing() {
    gitlab_board
    gl_answer IssueHierarchy '{"data":{"project":{"workItems":{"nodes":[{"widgets":[{"parent":null,"children":{"nodes":[]}}]}]}}}}'
    t_run board issue list --parent 9 --json
    t_status 0
    t_eq "$T_OUT" '[]'
}

test_assignee_at_me_goes_through_user() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues '[]'
    t_run board issue list --assignee @me --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'assignee_username=me'
}

test_assignee_none_asks_for_unassigned() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues '[]'
    t_run board issue list --assignee none --json
    t_contains "$(cat "$FAKE_LOG")" 'assignee_id=None'
}

# --- create and edit ---------------------------------------------------------------------

test_create_starts_in_the_first_todo_status() {
    gitlab_board
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    t_run board issue create --title t --label bug --json
    t_status 0
    t_jq "$(gl_sent)" . '{"title":"t","labels":"bug,zeta"}'
    t_jq "$T_OUT" .status.name '"zeta"'
}

test_create_in_a_done_status_closes_it() {
    gitlab_board
    gl_issue '["done"]' closed
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["done"]')"
    t_run board issue create --title t --status done --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" '"state_event":"close"'
}

test_create_with_an_unknown_type_writes_nothing() {
    gitlab_board
    gl_free_types
    t_run board issue create --title t --type nope
    t_status 2
    t_contains "$T_ERR" 'Issue, Task'
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_create_with_a_parent_makes_a_task() {
    gitlab_board
    gl_free_types
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":[]}}}'
    t_run board issue create --title t --parent 9 --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" '"issue_type":"task"'
    t_contains "$(cat "$FAKE_LOG")" 'parent=gid://gitlab/WorkItem/900'
}

test_create_with_a_parent_that_is_missing_writes_nothing() {
    gitlab_board
    gl_free_types
    gl_refuse GET_projects_a_2Fb_issues_9 '{"message":"404 Not found"}' 'glab: 404 Not found (HTTP 404)'
    t_run board issue create --title t --parent 9
    t_status 4
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_create_of_an_issue_under_a_parent_is_not_supported() {
    gitlab_board
    t_run board issue create --title t --parent 9 --type Issue
    t_status 3
    t_contains "$T_ERR" 'only a Task'
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

test_a_parent_refused_after_create_is_partial() {
    gitlab_board
    gl_free_types
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":["not allowed"]}}}'
    t_run board issue create --title t --parent 9
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_default_type_comes_from_the_declaration() {
    gitlab_board
    gl_free_types
    printf '\n[board.defaults]\ntype = "Task"\n' >>"$WORKFLOW_FILE"
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    t_run board issue create --title t
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" '"issue_type":"task"'
}

test_a_parent_beats_the_default_type() {
    gitlab_board
    gl_free_types
    printf '\n[board.defaults]\ntype = "Issue"\n' >>"$WORKFLOW_FILE"
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":[]}}}'
    t_run board issue create --title t --parent 9
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" '"issue_type":"task"'
}

test_a_read_that_fails_after_create_is_partial() {
    gitlab_board
    gl_issue '["zeta"]'
    gl_answer POST_projects_a_2Fb_issues "$(gl_issue_json '["zeta"]')"
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board issue create --title t
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_a_read_that_fails_after_a_move_is_partial() {
    gitlab_board
    gl_issue '["done"]' closed
    gl_refuse GET_projects_a_2Fb_issues_1 '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board issue move 1 done
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_a_read_that_fails_after_a_link_is_partial() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues_1 "$(gl_issue_json '[]')"
    gl_answer GET_projects_a_2Fb_issues_1_links '[]'
    gl_answer POST_projects_a_2Fb_issues_1_links '{}'
    gl_refuse IssueHierarchy '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board issue link add 1 2 --type relates
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_a_read_that_fails_with_nothing_written_is_not_partial() {
    gitlab_board
    gl_issue '["alpha"]'
    gl_refuse IssueHierarchy '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board issue reopen 1
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_a_parent_refused_after_a_conversion_is_partial() {
    gitlab_board
    gl_free_types
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer ConvertType '{"data":{"workItemConvert":{"errors":[]}}}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":["not allowed"]}}}'
    t_run board issue edit 1 --type Task --parent 9
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_an_issue_that_cannot_be_a_child_is_not_supported() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":["#5 cannot be added: it'"'"'s not allowed to add this type of parent item"]}}}'
    t_run board issue edit 1 --parent 9 --title x
    t_status 3
    t_contains "$T_ERR" 'not allowed to add this type'
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_clear_parent_sends_null() {
    gitlab_board
    gl_issue '[]'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":[]}}}'
    t_run board issue edit 1 --clear parent --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'parent=null'
}

test_type_goes_through_a_conversion() {
    gitlab_board
    gl_issue '[]'
    gl_free_types
    gl_answer ConvertType '{"data":{"workItemConvert":{"errors":[]}}}'
    t_run board issue edit 1 --type task --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'type=gid://gitlab/WorkItems::Type/5'
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_an_unknown_type_lists_the_valid_ones() {
    gitlab_board
    gl_issue '[]'
    gl_free_types
    t_run board issue edit 1 --type nope
    t_status 2
    t_contains "$T_ERR" 'Issue, Task'
}

test_a_failed_put_after_a_parent_is_partial() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_issues_9 '{"id":900,"iid":9}'
    gl_answer SetParent '{"data":{"workItemUpdate":{"errors":[]}}}'
    gl_refuse PUT_projects_a_2Fb_issues_1 '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board issue edit 1 --parent 9 --title x
    t_status 6
    t_eq "$T_OUT" 1 stdout
}

test_clear_due_and_milestone() {
    gitlab_board
    gl_issue '[]'
    t_run board issue edit 1 --clear due --clear milestone --json
    t_status 0
    t_jq "$(gl_sent)" . '{"due_date":null,"milestone_id":0}'
}

test_assignees_become_ids() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_members_all '[{"id":42,"username":"ann","name":"Ann","state":"active"}]'
    t_run board issue edit 1 --add-assignee ANN --json
    t_status 0
    t_jq "$(gl_sent)" . '{"assignee_ids":[42]}'
}

test_remove_assignee_keeps_the_others() {
    gitlab_board
    gl_issue '[]'
    jq -cn --argjson i "$(gl_issue_json '[]')" '$i + {assignees: [{id: 42, username: "ann"}, {id: 43, username: "bob"}]}' \
        >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues_1.json"
    gl_answer GET_projects_a_2Fb_members_all '[{"id":42,"username":"ann","name":"Ann","state":"active"},{"id":43,"username":"bob","name":"Bob","state":"active"}]'
    t_run board issue edit 1 --remove-assignee ann --json
    t_status 0
    t_jq "$(gl_sent)" . '{"assignee_ids":[43]}'
}

test_removing_someone_not_there_is_not_an_error() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_members_all '[]'
    t_run board issue edit 1 --remove-assignee ghost --json
    t_status 0
    t_jq "$(gl_sent)" . '{"assignee_ids":[]}'
}

test_an_unknown_assignee_is_not_found() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_members_all '[]'
    t_run board issue edit 1 --add-assignee ghost
    t_status 4
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_milestone_resolves_to_its_id() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_milestones '[{"id":77,"title":"V1"}]'
    t_run board issue edit 1 --milestone v1 --json
    t_status 0
    t_jq "$(gl_sent)" . '{"milestone_id":77}'
}

test_an_unknown_milestone_is_not_found() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_milestones '[]'
    t_run board issue edit 1 --milestone nope
    t_status 4
}

test_an_id_that_is_not_a_number_is_wrong_usage() {
    gitlab_board
    t_run board issue view abc
    t_status 2
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

# --- comments and links ------------------------------------------------------------------

test_comments_leave_out_system_notes() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues_1_notes '[{"id":1,"system":true,"body":"changed","author":null,"noteable_iid":1},{"id":2,"system":false,"body":"hi","author":{"id":5,"username":"me","name":"Me"},"noteable_iid":1,"created_at":null,"updated_at":null}]'
    t_run board issue comment list 1 --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["2"]'
    t_jq "$T_OUT" '.[0].url' '"https://gitlab.example.com/a/b/-/work_items/1#note_2"'
    t_jq "$T_OUT" '.[0].author.id' '"me"'
}

gl_links() {
    gl_answer GET_projects_a_2Fb_issues_1_links '[{"iid":2,"issue_link_id":55,"link_type":"relates_to","references":{"relative":"#2","full":"a/b#2"}},{"iid":3,"issue_link_id":56,"link_type":"relates_to","references":{"relative":"c/d#3","full":"c/d#3"}}]'
}

test_links_read_from_this_side() {
    gitlab_board
    gl_links
    t_run board issue link list 1 --json
    t_status 0
    t_jq "$T_OUT" . '[{"type":"relates","id":"2"},{"type":"relates","id":"c/d#3"}]'
}

test_link_duplicates_is_not_supported() {
    gitlab_board
    t_run board issue link add 1 2 --type duplicates
    t_status 3
    t_contains "$T_ERR" duplicates
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

test_link_blocks_on_free_is_not_supported() {
    gitlab_board
    gl_issue '[]'
    gl_refuse POST_projects_a_2Fb_issues_1_links '{"message":"Blocked issues not available for current license"}' \
        'glab: Blocked issues not available for current license (HTTP 403)'
    t_run board issue link add 1 2 --type blocks
    t_status 3
}

test_link_add_uses_the_numeric_project_and_the_iid() {
    gitlab_board
    gl_issue '[]'
    gl_answer POST_projects_a_2Fb_issues_1_links '{}'
    t_run board issue link add 1 2 --type relates --json
    t_status 0
    t_jq "$(gl_sent)" . '{"target_project_id":9,"target_issue_iid":2,"link_type":"relates_to"}'
}

test_link_twice_succeeds_without_a_second_post() {
    gitlab_board
    gl_issue '[]'
    gl_links
    t_run board issue link add 1 2 --type relates --json
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_link_remove_finds_the_link() {
    gitlab_board
    gl_issue '[]'
    gl_links
    gl_answer DELETE_projects_a_2Fb_issues_1_links_55 '{}'
    t_run board issue link remove 1 2 --type relates --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'links/55'
}

test_link_remove_of_nothing_succeeds() {
    gitlab_board
    gl_issue '[]'
    t_run board issue link remove 1 2 --type relates --json
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" DELETE
}

# --- status, labels, sprints, board ------------------------------------------------------

test_status_add_makes_a_label_and_a_list() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[]'
    gl_answer POST_projects_a_2Fb_labels '{"id":11,"name":"In Review"}'
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[]}'
    gl_answer POST_projects_a_2Fb_boards_7_lists '{"id":1}'
    t_run board status add "In Review" --category in_progress --json
    t_status 0
    t_jq "$T_OUT" . '{"id":"11","name":"In Review","category":"in_progress"}'
    t_contains "$(cat "$FAKE_LOG.stdin")" '{"label_id":11}'
}

test_status_add_twice_changes_nothing() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[{"id":11,"name":"alpha"}]'
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[{"id":3,"label":{"id":11,"name":"alpha"}}]}'
    t_run board status add ALPHA --category todo --json
    t_status 0
    t_jq "$T_OUT" .category '"in_progress"'
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_a_list_that_fails_after_the_label_is_partial() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[]'
    gl_answer POST_projects_a_2Fb_labels '{"id":11,"name":"x"}'
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[]}'
    gl_refuse POST_projects_a_2Fb_boards_7_lists '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board status add x --category todo
    t_status 6
    t_eq "$T_OUT" x stdout
}

test_a_board_that_cannot_be_read_is_not_partial_when_nothing_was_written() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[{"id":11,"name":"x"}]'
    gl_refuse GET_projects_a_2Fb_boards_7 '{"message":"500"}' 'glab: 500 (HTTP 500)'
    t_run board status add x --category todo
    t_status 1
}

test_status_rename_keeps_the_category() {
    gitlab_board
    gl_answer PUT_projects_a_2Fb_labels_alpha '{"id":11,"name":"beta"}'
    t_run board status rename ALPHA beta --json
    t_status 0
    t_jq "$T_OUT" . '{"id":"11","name":"beta","category":"in_progress"}'
}

test_status_delete_deletes_the_label() {
    gitlab_board
    gl_answer DELETE_projects_a_2Fb_labels_alpha ''
    t_run board status delete alpha --yes
    t_status 0
}

test_label_create_twice_leaves_it() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[{"id":1,"name":"bug","color":"#d73a4a","description":null}]'
    t_run board label create BUG --json
    t_status 0
    t_jq "$T_OUT" . '{"id":"1","name":"bug","color":"d73a4a","description":null}'
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_label_create_adds_the_hash_and_a_default_color() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[]'
    gl_answer POST_projects_a_2Fb_labels '{"id":1,"name":"a","color":"#112233"}'
    t_run board label create a --color 112233
    t_jq "$(gl_sent)" .color '"#112233"'
    : >"$FAKE_LOG.stdin"
    t_run board label create b
    t_jq "$(gl_sent)" .color '"#6699cc"'
}

test_sprints_on_free_are_not_supported() {
    gitlab_board
    gl_free_types
    t_run board sprint list
    t_status 3
    t_contains "$T_ERR" Premium
    t_run board sprint current
    t_status 3
    t_run board sprint view 1
    t_status 3
}

test_sprint_on_an_issue_on_free_is_refused_before_a_write() {
    gitlab_board
    gl_issue '[]'
    gl_free_types
    t_run board issue edit 1 --sprint current --title x
    t_status 3
    t_lacks "$(cat "$FAKE_LOG")" PUT
    t_run board issue list --sprint current
    t_status 3
}

test_sprints_on_premium_read_through_iterations() {
    gitlab_board
    gl_answer WorkItemTypes '{"data":{"project":{"workItemTypes":{"nodes":[{"name":"Issue","widgetDefinitions":[{"type":"ITERATION"}]}]}}}}'
    gl_answer GET_projects_a_2Fb_iterations '[{"id":3,"title":"S1","state":2,"start_date":"2026-11-01","due_date":"2026-11-14"},{"id":4,"title":null,"state":1,"start_date":"2026-11-15","due_date":"2026-11-28"}]'
    t_run board sprint list --json
    t_status 0
    t_jq "$T_OUT" 'map(.state)' '["future","active"]'
    t_run board sprint current --json
    t_status 0
    t_jq "$T_OUT" . '{"id":"3","name":"S1","state":"active","start_date":"2026-11-01","end_date":"2026-11-14"}'
}

test_board_view_uses_the_lists_in_position_order() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[{"position":1,"label":{"id":2,"name":"alpha"}},{"position":0,"label":{"id":1,"name":"zeta"}}]}'
    t_run board view --json
    t_status 0
    t_jq "$T_OUT" '.columns | map(.name)' '["zeta","alpha"]'
    t_jq "$T_OUT" '.statuses | length' 4
}

test_board_view_takes_the_first_board_when_none_is_named() {
    gitlab_board
    gl_workflow '/^board = 7/d'
    gl_answer GET_projects_a_2Fb_boards '[{"id":3,"name":"First","lists":[]},{"id":4,"name":"Second","lists":[]}]'
    t_run board view --json
    t_status 0
    t_jq "$T_OUT" .name '"First"'
}

test_a_bad_board_id_in_the_declaration_is_wrong_usage() {
    gitlab_board
    gl_workflow 's#^board = 7#board = "7/../9"#'
    t_run board view
    t_status 2
}

test_doctor_fails_on_a_list_with_no_category() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_labels '[{"id":1,"name":"zeta"},{"id":2,"name":"Review"}]'
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[{"position":0,"label":{"id":2,"name":"Review"}}]}'
    t_run board doctor --json
    t_status 1
    t_jq "$T_OUT" .ok false
    t_contains "$T_OUT" 'status \"Review\" has no category'
    t_contains "$T_OUT" 'status \"alpha\" has no label'
    t_contains "$T_OUT" 'status \"zeta\" has no list'
}

test_doctor_fails_on_a_category_that_does_not_exist() {
    gitlab_board
    gl_workflow 's#^"zeta".*#"zeta" = "later"#'
    gl_answer GET_projects_a_2Fb_labels '[]'
    gl_answer GET_projects_a_2Fb_boards_7 '{"id":7,"name":"B","lists":[]}'
    t_run board doctor --json
    t_status 1
    t_contains "$T_OUT" 'has category \"later\"'
}

# --- init --------------------------------------------------------------------------------

gl_init_answers() {
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    gl_answer GET_projects_group_2Fproj_boards '[{"id":5,"name":"Dev","lists":[{"position":1,"label":{"id":2,"name":"Done"}},{"position":0,"label":{"id":1,"name":"Weird"}}]}]'
    gl_answer GET_projects_group_2Fproj_boards_6 '{"id":6,"name":"Other","lists":[]}'
}

test_init_reads_a_boards_url() {
    gl_init_answers
    t_run board init --url https://gitlab.com/group/proj/-/boards --dry-run --json
    t_status 0
    t_contains "$T_OUT" 'kind = \"gitlab\"'
    t_contains "$T_OUT" 'url = \"https://gitlab.com/group/proj\"'
    t_contains "$T_OUT" 'board = 5'
    t_contains "$T_OUT" 'Done = \"done\"'
    t_contains "$T_OUT" '# Weird = \"\"'
}

test_init_reads_a_board_with_its_id() {
    gl_init_answers
    t_run board init --url https://gitlab.com/group/proj/-/boards/6 --dry-run --json
    t_status 0
    t_contains "$T_OUT" 'board = 6'
}

test_init_reads_work_items_and_issues_urls() {
    gl_init_answers
    t_run board init --url https://gitlab.com/group/proj/-/work_items --dry-run --json
    t_status 0
    t_contains "$T_OUT" 'url = \"https://gitlab.com/group/proj\"'
    t_run board init --url 'https://gitlab.com/group/proj/-/issues?state=opened' --dry-run --json
    t_status 0
    t_contains "$T_OUT" 'url = \"https://gitlab.com/group/proj\"'
}

test_init_on_a_self_managed_host_needs_the_kind() {
    gl_init_answers
    t_run board init --url https://code.example.com/group/proj/-/boards --dry-run
    t_status 2
    t_run board init --url https://code.example.com/group/proj/-/boards --kind gitlab --dry-run --json
    t_status 0
    t_contains "$T_OUT" 'url = \"https://code.example.com/group/proj\"'
    t_contains "$(cat "$FAKE_LOG")" '--hostname code.example.com'
}

test_init_refuses_a_url_with_no_project() {
    gl_init_answers
    t_run board init --url https://gitlab.com --kind gitlab --dry-run
    t_status 2
}

test_init_refuses_userinfo_in_the_url() {
    gl_init_answers
    t_run board init --url https://gitlab.com@evil.example/group/proj --kind gitlab --dry-run
    t_status 2
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

# --- hostile answers ---------------------------------------------------------------------

test_a_name_from_the_board_cannot_run_as_code() {
    gitlab_board
    gl_issue '[]'
    gl_answer GET_projects_a_2Fb_issues_1 "$(gl_issue_json '[]' | sed 's/"iid":1/"iid":"$(touch PWNED)"/')"
    t_run board issue view 1 --json
    [ ! -e PWNED ] || t_fail "an answer ran as code"
}

test_a_status_with_quotes_in_its_name_is_quoted() {
    gitlab_board
    gl_answer GET_projects_a_2Fb_issues '[]'
    t_run board issue list --assignee "a'; touch PWNED; '" --search "x'y" --json
    t_status 0
    [ ! -e PWNED ] || t_fail "a value ran as code"
}

# shellcheck shell=sh disable=SC2016,SC2119,SC2120

# The Jira adapter with no network. workflow.toml and any config beside it come with a repository,
# so the trust cases are written as attacks: each one tries to get the token out of this machine.

JIRA_T_TOKEN=tok-secret-value

# A clean machine: nothing the developer has at home may decide a test.
jira_home() {
    HOME=$T_TMP/home
    mkdir -p "$HOME"
    unset JIRA_CONFIG_FILE BOARD_JIRA_HOSTS
    JIRA_API_TOKEN=$JIRA_T_TOKEN
    FAKE_OVERRIDE=$T_TMP/answers
    mkdir -p "$FAKE_OVERRIDE"
    export HOME JIRA_API_TOKEN FAKE_OVERRIDE
}

# Writes an answer from stdin. Usage: ans <key> [http status]
ans() {
    cat >"$FAKE_OVERRIDE/$1.json"
    [ -z "${2:-}" ] || printf '%s' "$2" >"$FAKE_OVERRIDE/$1.status"
}

cloud_board() {
    jira_home
    BOARD_JIRA_HOSTS=site.atlassian.net
    export BOARD_JIRA_HOSTS
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://site.atlassian.net"
project = "KAN"
config  = "jira.yml"
EOF
    printf 'installation: Cloud\nlogin: me@example.com\nauth_type: basic\n' >"$T_TMP/jira.yml"
}

dc_board() {
    jira_home
    BOARD_JIRA_HOSTS=jira.corp.example
    export BOARD_JIRA_HOSTS
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://jira.corp.example"
project = "KAN"
config  = "jira.yml"
[board.target]
board = 7
EOF
    printf 'installation: Local\nlogin: me\nauth_type: bearer\n' >"$T_TMP/jira.yml"
}

# Answers for a board the workflow names but the machine does not trust.
evil_board() {
    jira_home
    t_workflow <<EOF
[board]
kind    = "jira"
url     = "$1"
project = "KAN"
EOF
}

no_request() {
    [ ! -s "$FAKE_LOG" ] || t_fail "a request left: $(cat "$FAKE_LOG")"
    [ ! -s "$FAKE_LOG.stdin" ] || t_fail "a curl config was written"
}

# The JSON bodies sent, one per line, through the same two decodings curl and Jira apply.
sent_bodies() {
    sed -n 's/^data-binary = //p' "$FAKE_LOG.stdin" | t_jq_cmd -r 'rtrimstr("\n")'
}

issue_json() {
    cat <<EOF
{"key":"$1","fields":{"summary":"t","description":null,"issuetype":{"name":"Task","subtask":false,"hierarchyLevel":0},
"status":{"id":"1","name":"${2:-To Do}","statusCategory":{"key":"${3:-new}"}},"assignee":null,"labels":[],
"priority":{"name":"${4:-Medium}"},"subtasks":[],"issuelinks":[],"fixVersions":[],"duedate":null,
"reporter":{"accountId":"a1","displayName":"A"},"created":"2026-11-02T01:04:07.800+1100","updated":"2026-11-02T01:04:07.800+1100"}}
EOF
}

# A view after a write reads these two.
view_answers() {
    printf '[]' | ans GET_rest_api_2_field
    issue_json "${1:-KAN-1}" | ans "GET_rest_api_2_issue_${1:-KAN-1}"
}

# --- trust ---------------------------------------------------------------------------------

test_repository_url_alone_is_not_trusted() {
    evil_board https://evil.example
    t_run board issue list
    t_status 5
    t_contains "$T_ERR" evil.example
    t_contains "$T_ERR" BOARD_JIRA_HOSTS
    no_request
}

test_every_kind_of_call_is_refused_before_a_request() {
    evil_board https://evil.example
    t_run board auth status
    t_status 5
    t_run board issue create --title t
    t_status 5
    t_run board api GET /rest/api/2/myself
    t_status 5
    t_run board status list
    t_status 5
    no_request
}

test_doctor_does_not_reach_an_untrusted_host() {
    evil_board https://evil.example
    t_run board doctor --json
    t_status 1
    no_request
}

test_repository_config_cannot_add_trust() {
    jira_home
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://evil.example"
project = "KAN"
config  = ".jira.yml"
EOF
    printf 'server: https://evil.example\nlogin: me\ninstallation: Cloud\n' >"$T_TMP/.jira.yml"
    t_run board issue list
    t_status 5
    no_request
}

test_repository_cannot_name_the_user_config_path() {
    evil_board https://evil.example
    mkdir -p "$HOME/x"
    printf 'server: https://evil.example\n' >"$HOME/x/config.yml"
    t_workflow <<EOF
[board]
kind    = "jira"
url     = "https://evil.example"
project = "KAN"
config  = "$HOME/x/config.yml"
EOF
    t_run board issue list
    t_status 5
    no_request
}

test_server_of_the_user_config_is_trusted() {
    evil_board https://jira.corp.example
    mkdir -p "$HOME/.config/.jira"
    printf 'installation: Local\nserver: https://jira.corp.example\nlogin: me\n' >"$HOME/.config/.jira/.config.yml"
    printf '{"name":"me","displayName":"Me"}' | ans GET_rest_api_2_myself
    t_run board auth status --json
    t_status 0
    t_jq "$T_OUT" .user '"Me"'
}

test_jira_config_file_replaces_the_default_file() {
    evil_board https://other.corp.example
    mkdir -p "$HOME/.config/.jira"
    printf 'server: https://other.corp.example\n' >"$HOME/.config/.jira/.config.yml"
    printf 'server: https://elsewhere.corp.example\n' >"$T_TMP/mine.yml"
    JIRA_CONFIG_FILE=$T_TMP/mine.yml
    export JIRA_CONFIG_FILE
    t_run board auth status
    t_status 5
    no_request
}

test_jira_config_file_names_a_host() {
    evil_board https://jira.corp.example
    printf 'server: "https://jira.corp.example/"  # the office\r\nlogin: me\r\n' >"$T_TMP/mine.yml"
    JIRA_CONFIG_FILE=$T_TMP/mine.yml
    export JIRA_CONFIG_FILE
    printf '{"name":"me"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
}

test_a_nested_server_key_is_not_the_server() {
    evil_board https://evil.example
    mkdir -p "$HOME/.config/.jira"
    printf 'board:\n  server: https://evil.example\n# server: https://evil.example\nxserver: https://evil.example\n' \
        >"$HOME/.config/.jira/.config.yml"
    t_run board auth status
    t_status 5
    no_request
}

test_listed_host_is_matched_whole() {
    for url in https://evil.jira.corp.example https://jira.corp.example.evil.net \
        https://jira.corp.example:8443 https://corp.example https://example; do
        evil_board "$url"
        BOARD_JIRA_HOSTS='other.example jira.corp.example'
        export BOARD_JIRA_HOSTS
        t_run board auth status
        t_status 5
        no_request
    done
}

test_listed_host_ignores_case_and_position() {
    evil_board https://JIRA.Corp.Example
    BOARD_JIRA_HOSTS='first.example jira.corp.EXAMPLE last.example'
    export BOARD_JIRA_HOSTS
    printf '{"name":"me"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
}

test_a_pattern_in_the_list_is_not_a_pattern() {
    evil_board https://evil.example
    BOARD_JIRA_HOSTS='*'
    export BOARD_JIRA_HOSTS
    t_run board auth status
    t_status 5
    no_request
}

test_repository_cannot_strip_tls_from_a_listed_host() {
    evil_board http://jira.corp.example
    BOARD_JIRA_HOSTS=jira.corp.example
    export BOARD_JIRA_HOSTS
    t_run board auth status
    t_status 5
    t_contains "$T_ERR" http
    no_request
}

test_repository_cannot_strip_tls_from_the_user_server() {
    evil_board http://jira.corp.example
    mkdir -p "$HOME/.config/.jira"
    printf 'server: https://jira.corp.example\n' >"$HOME/.config/.jira/.config.yml"
    t_run board auth status
    t_status 5
    no_request
}

test_user_may_name_plain_http_for_their_own_server() {
    evil_board http://jira.corp.example
    mkdir -p "$HOME/.config/.jira"
    printf 'server: http://jira.corp.example\nlogin: me\n' >"$HOME/.config/.jira/.config.yml"
    printf '{"name":"me"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
}

test_init_refuses_an_untrusted_host() {
    jira_home
    t_run board init --url https://evil.example/browse/KAN --kind jira
    t_status 5
    t_contains "$T_ERR" evil.example
    t_contains "$T_ERR" BOARD_JIRA_HOSTS
    no_request
    [ ! -e workflow.toml ] || t_fail "workflow.toml was written"
}

test_init_refuses_userinfo_in_the_url() {
    jira_home
    BOARD_JIRA_HOSTS=site.atlassian.net
    export BOARD_JIRA_HOSTS
    t_run board init --url https://site.atlassian.net@evil.example/browse/KAN --kind jira
    t_status 2
    no_request
}

test_api_path_cannot_change_the_host() {
    cloud_board
    t_run board api GET @evil.example/x
    t_status 2
    t_run board api GET .evil.example/x
    t_status 2
    no_request
}

test_token_is_never_in_argv() {
    cloud_board
    mkdir -p "$T_TMP/bin"
    cat >"$T_TMP/bin/curl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T_TMP/argv"
exec "$BOARD_TEST_ROOT/tests/fake/curl" "\$@"
EOF
    chmod +x "$T_TMP/bin/curl"
    PATH=$T_TMP/bin:$PATH
    printf '{"id":"1","key":"KAN-1"}' | ans POST_rest_api_2_issue
    view_answers
    t_run board issue create --title "secret body test" --body "the body" --json
    t_status 0
    t_lacks "$(cat "$T_TMP/argv")" "$JIRA_T_TOKEN" argv
    t_lacks "$(cat "$T_TMP/argv")" "the body" argv
    t_lacks "$T_OUT$T_ERR" "$JIRA_T_TOKEN" output
}

test_a_quote_in_a_login_cannot_add_a_curl_option() {
    cloud_board
    printf 'login: a" url = "https://evil.example\ninstallation: Cloud\n' >"$T_TMP/jira.yml"
    printf '{"accountId":"a","displayName":"A"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    got=$(sed -n 's/^user = //p' "$FAKE_LOG.stdin" | t_jq_cmd -r .)
    t_eq "$got" "a\" url = \"https://evil.example:$JIRA_T_TOKEN" 'the user, decoded'
    t_eq "$(grep -c '^url' "$FAKE_LOG.stdin")" 0 'url lines'
}

# --- auth ----------------------------------------------------------------------------------

test_cloud_logs_in_with_basic() {
    cloud_board
    printf '{"accountId":"a","displayName":"A"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" "user = \"me@example.com:$JIRA_T_TOKEN\""
}

test_data_center_logs_in_with_bearer() {
    dc_board
    printf '{"name":"me"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" "header = \"Authorization: Bearer $JIRA_T_TOKEN\""
    t_lacks "$(cat "$FAKE_LOG.stdin")" 'user ='
}

test_auth_type_in_the_config_wins_over_installation() {
    dc_board
    printf 'installation: Local\nlogin: me\nauth_type: basic\n' >"$T_TMP/jira.yml"
    printf '{"name":"me"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" "user = \"me:$JIRA_T_TOKEN\""
}

test_no_token_falls_back_to_netrc() {
    cloud_board
    unset JIRA_API_TOKEN
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" netrc-optional
    t_lacks "$(cat "$FAKE_LOG.stdin")" 'user ='
}

test_a_token_with_no_login_is_exit_5() {
    cloud_board
    printf 'installation: Cloud\n' >"$T_TMP/jira.yml"
    t_run board auth status
    t_status 5
    t_contains "$T_ERR" login
    no_request
}

test_a_config_for_another_server_gives_only_the_login() {
    cloud_board
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://site.atlassian.net"
project = "KAN"
EOF
    mkdir -p "$HOME/.config/.jira"
    printf 'server: https://jira.corp.example\nlogin: office-login\ninstallation: Local\nauth_type: bearer\n' \
        >"$HOME/.config/.jira/.config.yml"
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" "user = \"office-login:$JIRA_T_TOKEN\""
    t_lacks "$(cat "$FAKE_LOG.stdin")" Bearer
}

test_a_config_cannot_trust_a_host_by_giving_a_login() {
    evil_board https://evil.example
    mkdir -p "$HOME/.config/.jira"
    printf 'server: https://jira.corp.example\nlogin: office-login\n' >"$HOME/.config/.jira/.config.yml"
    t_run board auth status
    t_status 5
    no_request
}

test_data_center_may_live_under_a_path() {
    dc_board
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://jira.corp.example/jira/"
project = "KAN"
config  = "jira.yml"
EOF
    printf '{"name":"me"}' | ans GET_jira_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'GET https://jira.corp.example/jira/rest/api/2/myself'
}

test_a_path_on_cloud_is_only_where_a_browser_was() {
    cloud_board
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://site.atlassian.net/jira/software/projects/KAN"
project = "KAN"
config  = "jira.yml"
EOF
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'GET https://site.atlassian.net/rest/api/2/myself'
}

# --- classification ------------------------------------------------------------------------

test_401_and_403_are_exit_5() {
    cloud_board
    printf 'Client must be authenticated to access this resource.' | ans GET_rest_api_2_project_KAN_statuses 401
    t_run board status list
    t_status 5
    printf '{"errorMessages":["No permission"]}' | ans GET_rest_api_2_project_KAN_statuses 403
    t_run board status list
    t_status 5
    t_contains "$T_ERR" 'No permission'
}

test_404_with_a_good_login_is_exit_4() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf '{"errorMessages":["Issue does not exist"]}' | ans GET_rest_api_2_issue_KAN-9 404
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board issue view KAN-9
    t_status 4
    t_eq "$(grep -c myself "$FAKE_LOG")" 1 'calls to myself'
}

test_404_with_a_bad_login_is_exit_5() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf '{"errorMessages":["Issue does not exist"]}' | ans GET_rest_api_2_issue_KAN-9 404
    printf 'Client must be authenticated' | ans GET_rest_api_2_myself 401
    t_run board issue view KAN-9
    t_status 5
}

test_a_bad_token_on_myself_does_not_loop() {
    cloud_board
    printf '{}' | ans GET_rest_api_2_myself 404
    t_run board auth status
    t_status 5
    t_eq "$(grep -c myself "$FAKE_LOG")" 1 'calls to myself'
}

test_400_joins_messages_and_errors() {
    cloud_board
    printf '{"errorMessages":["first"],"errors":{"summary":"second"}}' | ans POST_rest_api_2_issue 400
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board issue create --title t
    t_status 1
    t_contains "$T_ERR" first
    t_contains "$T_ERR" 'summary: second'
}

test_400_with_a_bad_login_is_exit_5() {
    cloud_board
    printf '{"errorMessages":["The target project does not exist"]}' | ans POST_rest_api_2_issue 400
    printf 'no' | ans GET_rest_api_2_myself 401
    t_run board issue create --title t
    t_status 5
}

test_429_says_so() {
    cloud_board
    printf '{}' | ans GET_rest_api_2_project_KAN_statuses 429
    t_run board status list
    t_status 1
    t_contains "$T_ERR" 429
}

test_500_is_exit_1() {
    cloud_board
    printf '<html>down</html>' | ans GET_rest_api_2_project_KAN_statuses 500
    t_run board status list
    t_status 1
    t_contains "$T_ERR" 500
}

# Usage: curl_exits <status>  — curl itself ends with this status.
curl_exits() {
    mkdir -p "$T_TMP/bin"
    printf '#!/bin/sh\nexit %s\n' "$1" >"$T_TMP/bin/curl"
    chmod +x "$T_TMP/bin/curl"
    PATH=$T_TMP/bin:$PATH
}

test_curl_failing_to_connect_is_exit_1() {
    cloud_board
    curl_exits 7
    t_run board status list
    t_status 1
    t_contains "$T_ERR" site.atlassian.net
    t_run board issue create --title t
    t_status 1
}

test_a_timed_out_read_is_exit_1() {
    cloud_board
    curl_exits 124
    t_run board status list
    t_status 1
    t_contains "$T_ERR" 'timed out'
}

test_a_timed_out_write_is_exit_6() {
    cloud_board
    curl_exits 124
    t_run board issue create --title t
    t_status 6
}

test_a_connection_broken_during_a_write_is_exit_6() {
    cloud_board
    curl_exits 56
    t_run board issue create --title t
    t_status 6
}

test_a_read_timing_out_before_a_write_is_exit_1() {
    cloud_board
    curl_exits 124
    t_run board issue edit KAN-1 --add-assignee 222222222222222222222222
    t_status 1
}

test_a_failed_read_back_after_create_is_partial() {
    cloud_board
    printf '{"id":"1","key":"KAN-1"}' | ans POST_rest_api_2_issue
    printf '[]' | ans GET_rest_api_2_field
    printf 'down' | ans GET_rest_api_2_issue_KAN-1 500
    t_run board issue create --title t
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_a_failed_read_back_after_an_edit_is_partial() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    printf 'down' | ans GET_rest_api_2_issue_KAN-1 500
    t_run board issue edit KAN-1 --title new
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_a_failed_read_with_no_write_is_not_partial() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf 'down' | ans GET_rest_api_2_issue_KAN-1 500
    t_run board issue view KAN-1
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_a_failed_read_back_after_a_move_is_partial() {
    cloud_board
    move_answers
    issue_json KAN-1 | ans GET_rest_api_2_issue_KAN-1.1
    printf 'down' | ans GET_rest_api_2_issue_KAN-1.2 500
    printf 'down' | ans GET_rest_api_2_issue_KAN-1.3 500
    t_run board issue move KAN-1 Done
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_a_failed_read_back_after_a_link_is_partial() {
    cloud_board
    link_type_answers
    issue_json KAN-1 | ans GET_rest_api_2_issue_KAN-1.1
    printf 'down' | ans GET_rest_api_2_issue_KAN-1.2 500
    t_run board issue link add KAN-1 KAN-2 --type blocks
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_a_search_does_not_count_as_a_write() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf 'down' | ans POST_rest_api_2_search_jql 500
    t_run board issue list
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_a_step_with_nothing_to_do_does_not_make_a_later_failure_partial() {
    dc_board
    move_answers
    sprint_answers
    printf 'down' | ans POST_rest_agile_1.0_sprint_2_issue 500
    t_run board issue edit KAN-1 --status 'To Do' --sprint current
    t_status 1
    t_eq "$T_OUT" '' stdout
    t_contains "$(cat "$FAKE_LOG")" 'POST https://jira.corp.example/rest/agile/1.0/sprint/2/issue'
}

test_a_workflow_with_no_way_there_stops_an_edit_before_any_write() {
    cloud_board
    move_answers
    t_run board issue edit KAN-1 --title new --status Blocked
    t_status 1
    t_lacks "$(cat "$FAKE_LOG")" PUT
    t_eq "$T_OUT" '' stdout
}

test_an_unknown_name_stops_an_edit_before_any_write() {
    cloud_board
    move_answers
    printf '[]' | ans GET_rest_api_2_project_KAN_versions
    t_run board issue edit KAN-1 --title new --status nope
    t_status 2
    t_run board issue edit KAN-1 --title new --milestone nope
    t_status 4
    printf '[]' | ans GET_rest_api_2_user_assignable_search
    t_run board issue edit KAN-1 --title new --add-assignee nobody
    t_status 4
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_a_transition_failing_after_an_edit_is_partial() {
    cloud_board
    move_answers
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    printf '{"errorMessages":["a field is required"]}' | ans POST_rest_api_2_issue_KAN-1_transitions 400
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board issue edit KAN-1 --title new --status Done
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_clearing_a_sprint_on_a_board_without_sprints_writes_nothing() {
    dc_board
    printf '{"errorMessages":["The board does not support sprints"]}' | ans GET_rest_agile_1.0_board_7_sprint 400
    t_run board issue edit KAN-1 --title new --clear sprint
    t_status 3
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_an_empty_search_with_a_bad_token_is_exit_5() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf '{"issues":[],"isLast":true}' | ans POST_rest_api_2_search_jql
    printf 'Client must be authenticated' | ans GET_rest_api_2_myself 401
    t_run board issue list
    t_status 5
}

test_an_empty_search_with_a_good_login_is_an_empty_list() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    printf '{"issues":[],"isLast":true}' | ans POST_rest_api_2_search_jql
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    t_run board issue list --json
    t_status 0
    t_jq "$T_OUT" . '[]'
}

# --- JQL -----------------------------------------------------------------------------------

# Runs one list and prints the JQL that went out, as Jira would read it.
jql_of() {
    printf '[]' | ans GET_rest_api_2_field
    printf '{"issues":[],"isLast":true}' | ans POST_rest_api_2_search_jql
    printf '{"accountId":"a"}' | ans GET_rest_api_2_myself
    : >"$FAKE_LOG.stdin"
    t_run board issue list "$@"
    t_status 0
    sent_bodies | t_jq_cmd -r .jql
}

test_a_quote_in_a_status_stays_inside_the_string() {
    cloud_board
    got=$(jql_of --status 'x" OR project = "OTHER')
    t_contains "$got" 'status = "x\" OR project = \"OTHER"'
}

test_a_backslash_cannot_escape_the_closing_quote() {
    cloud_board
    got=$(jql_of --status "x\\")
    t_contains "$got" 'status = "x\\"'
}

test_a_line_break_stays_inside_the_string() {
    cloud_board
    got=$(jql_of --type 'a
b')
    t_contains "$got" 'issuetype = "a\nb"'
}

test_free_text_escapes_lucene_then_jql() {
    cloud_board
    got=$(jql_of --search 'c++ "q" (x)')
    t_contains "$got" 'summary ~ "c\\+\\+ \\\"q\\\" \\(x\\)"'
    t_contains "$got" 'OR description ~'
}

test_cyrillic_passes_through_a_search() {
    cloud_board
    got=$(jql_of --search 'кириллица')
    t_contains "$got" 'summary ~ "кириллица"'
}

test_filters_become_clauses() {
    cloud_board
    got=$(jql_of --type Bug --milestone v1 --priority low --assignee none --parent KAN-1 --sprint current)
    t_contains "$got" 'project = "KAN"'
    t_contains "$got" 'statusCategory != done'
    t_contains "$got" 'issuetype = "Bug"'
    t_contains "$got" 'fixVersion = "v1"'
    t_contains "$got" 'priority in ("Low", "Lowest")'
    t_contains "$got" 'assignee is EMPTY'
    t_contains "$got" 'parent = "KAN-1"'
    t_contains "$got" 'sprint in openSprints()'
    t_contains "$got" 'ORDER BY updated DESC'
}

test_me_is_current_user() {
    cloud_board
    got=$(jql_of --assignee @me)
    t_contains "$got" 'assignee = currentUser()'
}

test_declared_statuses_filter_after_the_search() {
    cloud_board
    cat >>"$T_TMP/workflow.toml" <<'EOF'
[board.statuses]
"Won't Do" = "canceled"
EOF
    printf '[]' | ans GET_rest_api_2_field
    cat >"$FAKE_OVERRIDE/POST_rest_api_2_search_jql.json" <<EOF
{"isLast":true,"issues":[$(issue_json KAN-1 "Won't Do" done),$(issue_json KAN-2 Done done)]}
EOF
    t_run board issue list --category canceled --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["KAN-1"]'
    t_lacks "$(sent_bodies)" statusCategory
}

test_canceled_with_nothing_declared_is_empty_with_no_search() {
    cloud_board
    t_run board issue list --category canceled --json
    t_status 0
    t_jq "$T_OUT" . '[]'
    no_request
}

test_cloud_pages_by_token() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    cat >"$FAKE_OVERRIDE/POST_rest_api_2_search_jql.1.json" <<EOF
{"isLast":false,"nextPageToken":"tok2","issues":[$(issue_json KAN-1)]}
EOF
    cat >"$FAKE_OVERRIDE/POST_rest_api_2_search_jql.2.json" <<EOF
{"isLast":true,"issues":[$(issue_json KAN-2)]}
EOF
    t_run board issue list --limit all --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["KAN-1","KAN-2"]'
    t_jq "$(sent_bodies | sed -n 2p)" .nextPageToken '"tok2"'
}

test_data_center_pages_by_start_at() {
    dc_board
    printf '[]' | ans GET_rest_api_2_field
    cat >"$FAKE_OVERRIDE/POST_rest_api_2_search.1.json" <<EOF
{"startAt":0,"maxResults":1,"total":2,"issues":[$(issue_json KAN-1)]}
EOF
    cat >"$FAKE_OVERRIDE/POST_rest_api_2_search.2.json" <<EOF
{"startAt":1,"maxResults":1,"total":2,"issues":[$(issue_json KAN-2)]}
EOF
    t_run board issue list --limit all --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["KAN-1","KAN-2"]'
    t_jq "$(sent_bodies | sed -n 2p)" .startAt 1
    t_contains "$(cat "$FAKE_LOG")" 'https://jira.corp.example/rest/api/2/search'
}

# --- issues --------------------------------------------------------------------------------

test_the_shape_of_an_issue() {
    cloud_board
    view_answers
    t_run board issue view KAN-1 --json
    t_status 0
    t_jq "$T_OUT" .url '"https://site.atlassian.net/browse/KAN-1"'
    t_jq "$T_OUT" .status '{"name":"To Do","category":"todo"}'
    t_jq "$T_OUT" .author '{"id":"a1","name":"A"}'
    t_jq "$T_OUT" .created_at '"2026-11-01T14:04:07Z"'
}

test_status_categories_and_the_declared_override() {
    cloud_board
    cat >>"$T_TMP/workflow.toml" <<'EOF'
[board.statuses]
"Dropped" = "canceled"
EOF
    printf '[{"statuses":[
        {"id":"1","name":"To Do","statusCategory":{"key":"new"}},
        {"id":"2","name":"Doing","statusCategory":{"key":"indeterminate"}},
        {"id":"3","name":"Done","statusCategory":{"key":"done"}},
        {"id":"4","name":"Dropped","statusCategory":{"key":"done"}}]},
        {"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}}]}]' |
        ans GET_rest_api_2_project_KAN_statuses
    t_run board status list --json
    t_status 0
    t_jq "$T_OUT" 'map(.category)' '["todo","in_progress","done","canceled"]'
}

test_priority_reads_through_the_map() {
    cloud_board
    for pair in Highest:urgent High:high Medium:medium Low:low Lowest:low; do
        view_answers
        issue_json KAN-1 'To Do' new "${pair%:*}" | ans GET_rest_api_2_issue_KAN-1
        t_run board issue view KAN-1 --jq .priority
        t_eq "$T_OUT" "${pair#*:}" "${pair%:*}"
    done
}

test_no_priority_reads_as_null() {
    cloud_board
    view_answers
    issue_json KAN-1 | t_jq_cmd -c '.fields.priority = null' | ans GET_rest_api_2_issue_KAN-1
    t_run board issue view KAN-1 --json
    t_status 0
    t_jq "$T_OUT" .priority null
}

test_priority_writes_through_the_map() {
    cloud_board
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    view_answers
    t_run board issue edit KAN-1 --priority urgent --json
    t_status 0
    t_jq "$(sent_bodies)" .fields.priority '{"name":"Highest"}'
}

test_cloud_cannot_empty_a_priority() {
    cloud_board
    t_run board issue edit KAN-1 --priority none
    t_status 3
    t_run board issue edit KAN-1 --clear priority
    t_status 3
    no_request
}

test_data_center_may_empty_a_priority() {
    dc_board
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    view_answers
    t_run board issue edit KAN-1 --clear priority
    t_status 0
    t_jq "$(sent_bodies)" .fields.priority null
}

create_answers() {
    printf '{"id":"1","key":"KAN-1"}' | ans POST_rest_api_2_issue
    view_answers
}

test_create_defaults_to_task() {
    cloud_board
    create_answers
    t_run board issue create --title t --json
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype '{"name":"Task"}'
}

test_create_takes_the_declared_default_type() {
    cloud_board
    printf '[board.defaults]\ntype = "Story"\n' >>"$T_TMP/workflow.toml"
    create_answers
    t_run board issue create --title t
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype.name '"Story"'
}

parent_answers() {
    issue_json KAN-2 | ans GET_rest_api_2_issue_KAN-2
    printf '{"issueTypes":[{"id":"1","name":"Task","subtask":false},{"id":"5","name":"Sub-task","subtask":true}]}' |
        ans GET_rest_api_2_project_KAN
}

test_create_under_a_parent_picks_the_subtask_type() {
    cloud_board
    create_answers
    parent_answers
    t_run board issue create --title t --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" '.fields | {issuetype, parent}' '{"issuetype":{"name":"Sub-task"},"parent":{"key":"KAN-2"}}'
}

test_create_under_an_epic_keeps_an_ordinary_type() {
    cloud_board
    create_answers
    issue_json KAN-2 | t_jq_cmd -c '.fields.issuetype.hierarchyLevel = 1' | ans GET_rest_api_2_issue_KAN-2
    t_run board issue create --title t --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype.name '"Task"'
}

test_the_declared_default_does_not_stop_a_subtask() {
    cloud_board
    printf '[board.defaults]\ntype = "Task"\n' >>"$T_TMP/workflow.toml"
    create_answers
    parent_answers
    t_run board issue create --title t --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype.name '"Sub-task"'
}

test_the_declared_default_stays_under_an_epic() {
    cloud_board
    printf '[board.defaults]\ntype = "Story"\n' >>"$T_TMP/workflow.toml"
    create_answers
    issue_json KAN-2 | t_jq_cmd -c '.fields.issuetype.hierarchyLevel = 1' | ans GET_rest_api_2_issue_KAN-2
    t_run board issue create --title t --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype.name '"Story"'
}

test_a_given_type_wins_over_the_parent() {
    cloud_board
    create_answers
    t_run board issue create --title t --parent KAN-2 --type Spike
    t_status 0
    t_jq "$(sent_bodies)" .fields.issuetype.name '"Spike"'
}

test_create_with_a_status_that_is_unknown_writes_nothing() {
    cloud_board
    printf '[{"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}}]}]' |
        ans GET_rest_api_2_project_KAN_statuses
    t_run board issue create --title t --status nope
    t_status 2
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_a_later_step_failing_after_create_is_partial() {
    cloud_board
    create_answers
    printf '[{"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},{"id":"2","name":"Done","statusCategory":{"key":"done"}}]}]' |
        ans GET_rest_api_2_project_KAN_statuses
    printf '{"errors":{}}' | ans GET_rest_api_2_issue_KAN-1_transitions 500
    t_run board issue create --title t --status Done
    t_status 6
    t_eq "$T_OUT" KAN-1 stdout
}

test_two_assignees_on_create_is_exit_3() {
    cloud_board
    t_run board issue create --title t --assignee a --assignee b
    t_status 3
    no_request
}

test_assignee_body_differs_by_installation() {
    cloud_board
    create_answers
    t_run board issue create --title t --assignee 6409db899cba7ca0287b1ff6
    t_status 0
    t_jq "$(sent_bodies)" .fields.assignee '{"accountId":"6409db899cba7ca0287b1ff6"}'

    dc_board
    : >"$FAKE_LOG.stdin"
    create_answers
    printf '[{"name":"jsmith","displayName":"John Smith"}]' | ans GET_rest_api_2_user_assignable_search
    t_run board issue create --title t --assignee "John Smith"
    t_status 0
    t_jq "$(sent_bodies)" .fields.assignee '{"name":"jsmith"}'
    t_contains "$(cat "$FAKE_LOG")" 'username=John%20Smith'
}

test_me_is_read_from_myself() {
    cloud_board
    create_answers
    printf '{"accountId":"me-id"}' | ans GET_rest_api_2_myself
    t_run board issue create --title t --assignee @me
    t_status 0
    t_jq "$(sent_bodies)" .fields.assignee.accountId '"me-id"'
}

test_several_matches_is_exit_1_listing_them() {
    cloud_board
    printf '[{"accountId":"a1","displayName":"Ann A"},{"accountId":"a2","displayName":"Ann B"}]' |
        ans GET_rest_api_2_user_assignable_search
    t_run board issue create --title t --assignee Ann
    t_status 1
    t_contains "$T_ERR" 'Ann A (a1)'
    t_contains "$T_ERR" 'Ann B (a2)'
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_an_exact_name_wins_over_a_partial_match() {
    cloud_board
    create_answers
    printf '[{"accountId":"a1","displayName":"Ann"},{"accountId":"a2","displayName":"Anna"}]' |
        ans GET_rest_api_2_user_assignable_search
    t_run board issue create --title t --assignee ann
    t_status 0
    t_jq "$(sent_bodies)" .fields.assignee.accountId '"a1"'
}

test_nobody_found_is_exit_4() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_user_assignable_search
    t_run board issue create --title t --assignee nobody
    t_status 4
}

assigned_to() {
    issue_json KAN-1 | t_jq_cmd -c --arg a "$1" '.fields.assignee = {accountId: $a, displayName: "X"}' |
        ans GET_rest_api_2_issue_KAN-1
}

test_a_second_assignee_on_edit_is_exit_3() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    assigned_to 111111111111111111111111
    t_run board issue edit KAN-1 --add-assignee 222222222222222222222222
    t_status 3
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_replacing_the_assignee_in_one_call_works() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    assigned_to 111111111111111111111111
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    t_run board issue edit KAN-1 --add-assignee 222222222222222222222222 --remove-assignee 111111111111111111111111
    t_status 0
    t_jq "$(sent_bodies)" .fields.assignee.accountId '"222222222222222222222222"'
}

test_removing_someone_who_is_not_assigned_changes_nothing() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    assigned_to 111111111111111111111111
    t_run board issue edit KAN-1 --remove-assignee 222222222222222222222222
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_labels_change_without_a_read() {
    cloud_board
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    view_answers
    t_run board issue edit KAN-1 --add-label a --remove-label b
    t_status 0
    t_jq "$(sent_bodies)" .update.labels '[{"add":"a"},{"remove":"b"}]'
}

test_a_milestone_is_found_by_name() {
    cloud_board
    printf '[{"id":"10","name":"V1"}]' | ans GET_rest_api_2_project_KAN_versions
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    view_answers
    t_run board issue edit KAN-1 --milestone v1
    t_status 0
    t_jq "$(sent_bodies)" .fields.fixVersions '[{"id":"10"}]'
    t_run board issue edit KAN-1 --milestone nope
    t_status 4
}

# --- move ----------------------------------------------------------------------------------

move_answers() {
    view_answers
    printf '{"transitions":[{"id":"21","to":{"name":"In Progress","statusCategory":{"key":"indeterminate"}}},
        {"id":"41","to":{"name":"Done","statusCategory":{"key":"done"}}}]}' | ans GET_rest_api_2_issue_KAN-1_transitions
    printf '' | ans POST_rest_api_2_issue_KAN-1_transitions 204
    printf '[{"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},
        {"id":"2","name":"In Progress","statusCategory":{"key":"indeterminate"}},
        {"id":"3","name":"Done","statusCategory":{"key":"done"}},
        {"id":"4","name":"Blocked","statusCategory":{"key":"indeterminate"}}]}]' | ans GET_rest_api_2_project_KAN_statuses
}

test_move_matches_the_target_ignoring_case() {
    cloud_board
    move_answers
    t_run board issue move KAN-1 'in progress'
    t_status 0
    t_jq "$(sent_bodies)" .transition.id '"21"'
}

test_move_to_where_it_is_succeeds_with_no_transition() {
    cloud_board
    move_answers
    t_run board issue move KAN-1 'to do'
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_move_to_an_unknown_status_is_exit_2() {
    cloud_board
    move_answers
    t_run board issue move KAN-1 nope
    t_status 2
    t_contains "$T_ERR" Blocked
}

test_move_with_no_transition_is_exit_1_naming_them() {
    cloud_board
    move_answers
    t_run board issue move KAN-1 Blocked
    t_status 1
    t_contains "$T_ERR" 'In Progress, Done'
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_close_moves_to_a_done_status() {
    cloud_board
    move_answers
    t_run board issue close KAN-1
    t_status 0
    t_jq "$(sent_bodies)" .transition.id '"41"'
}

test_closing_a_closed_issue_succeeds() {
    cloud_board
    move_answers
    issue_json KAN-1 Done done | ans GET_rest_api_2_issue_KAN-1
    t_run board issue close KAN-1
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" POST
}

test_close_as_canceled_needs_a_declared_status() {
    cloud_board
    move_answers
    t_run board issue close KAN-1 --reason canceled
    t_status 2
    t_contains "$T_ERR" canceled
}

test_reopening_an_open_issue_leaves_it() {
    cloud_board
    move_answers
    issue_json KAN-1 'In Progress' indeterminate | ans GET_rest_api_2_issue_KAN-1
    t_run board issue reopen KAN-1
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" POST
}

# --- parent --------------------------------------------------------------------------------

test_a_task_under_an_epic_is_a_plain_edit() {
    cloud_board
    view_answers
    issue_json KAN-2 | t_jq_cmd -c '.fields.issuetype.hierarchyLevel = 1' | ans GET_rest_api_2_issue_KAN-2
    printf '' | ans PUT_rest_api_2_issue_KAN-1 204
    t_run board issue edit KAN-1 --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" .fields.parent '{"key":"KAN-2"}'
    t_lacks "$(cat "$FAKE_LOG")" bulk
}

bulk_answers() {
    printf '{"taskId":"77"}' | ans POST_rest_api_2_bulk_issues_move
    printf '{"status":"COMPLETE","result":{"failedIssues":{}}}' | ans GET_rest_api_2_task_77
}

test_a_task_under_a_task_becomes_a_subtask_on_cloud() {
    cloud_board
    view_answers
    parent_answers
    bulk_answers
    t_run board issue edit KAN-1 --parent KAN-2
    t_status 0
    t_jq "$(sent_bodies)" '.targetToSourcesMapping | keys' '["KAN,5,KAN-2"]'
    t_jq "$(sent_bodies)" '.targetToSourcesMapping[].issueIdsOrKeys' '["KAN-1"]'
}

test_a_failed_move_is_exit_1() {
    cloud_board
    view_answers
    parent_answers
    printf '{"taskId":"77"}' | ans POST_rest_api_2_bulk_issues_move
    printf '{"status":"COMPLETE","result":{"failedIssues":{"10":{"errors":["no"]}}}}' | ans GET_rest_api_2_task_77
    t_run board issue edit KAN-1 --parent KAN-2
    t_status 1
}

test_a_task_under_a_task_is_exit_3_on_data_center() {
    dc_board
    view_answers
    issue_json KAN-1 | t_jq_cmd -c 'del(.fields.issuetype.hierarchyLevel)' | ans GET_rest_api_2_issue_KAN-1
    issue_json KAN-2 | t_jq_cmd -c 'del(.fields.issuetype.hierarchyLevel)' | ans GET_rest_api_2_issue_KAN-2
    t_run board issue edit KAN-1 --parent KAN-2
    t_status 3
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_an_impossible_pair_is_exit_3_before_any_write() {
    cloud_board
    issue_json KAN-1 | t_jq_cmd -c '.fields.issuetype.hierarchyLevel = 1' | ans GET_rest_api_2_issue_KAN-1
    issue_json KAN-2 | ans GET_rest_api_2_issue_KAN-2
    t_run board issue edit KAN-1 --title new --parent KAN-2
    t_status 3
    t_lacks "$(cat "$FAKE_LOG")" PUT
}

test_clearing_a_subtask_parent_turns_it_back_on_cloud() {
    cloud_board
    view_answers
    parent_answers
    bulk_answers
    issue_json KAN-1 | t_jq_cmd -c '.fields.issuetype.subtask = true | .fields.parent = {key: "KAN-2"}' |
        ans GET_rest_api_2_issue_KAN-1
    t_run board issue edit KAN-1 --clear parent
    t_status 0
    t_jq "$(sent_bodies)" '.targetToSourcesMapping | keys' '["KAN,1"]'
}

test_clearing_a_parent_that_is_not_there_writes_nothing() {
    cloud_board
    view_answers
    t_run board issue edit KAN-1 --clear parent
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" PUT
    t_lacks "$(cat "$FAKE_LOG")" POST
}

# --- links ---------------------------------------------------------------------------------

link_issue() {
    issue_json KAN-1 | t_jq_cmd -c '.fields.issuelinks = [{id: "9", type: {name: "Blocks"}, outwardIssue: {key: "KAN-2"}},
        {id: "8", type: {name: "Blocks"}, inwardIssue: {key: "KAN-3"}},
        {id: "7", type: {name: "Duplicate"}, inwardIssue: {key: "KAN-4"}},
        {id: "6", type: {name: "Cloners"}, outwardIssue: {key: "KAN-5"}}]' | ans GET_rest_api_2_issue_KAN-1
}

test_links_read_from_the_side_of_the_issue() {
    cloud_board
    link_issue
    t_run board issue link list KAN-1 --json
    t_status 0
    t_jq "$T_OUT" 'map("\(.type) \(.id)")' '["blocks KAN-2","blocked-by KAN-3","duplicated-by KAN-4","relates KAN-5"]'
}

test_linking_twice_writes_nothing() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    link_issue
    t_run board issue link add KAN-1 KAN-2 --type blocks
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" POST
}

link_type_answers() {
    printf '[]' | ans GET_rest_api_2_field
    printf '{"issueLinkTypes":[{"name":"Blocks"},{"name":"Relates"},{"name":"Duplicate"}]}' | ans GET_rest_api_2_issueLinkType
    printf '' | ans POST_rest_api_2_issueLink 201
    issue_json KAN-1 | ans GET_rest_api_2_issue_KAN-1
}

test_blocks_puts_the_issue_on_the_inward_side() {
    cloud_board
    link_type_answers
    t_run board issue link add KAN-1 KAN-2 --type blocks
    t_status 0
    t_jq "$(sent_bodies)" . '{"type":{"name":"Blocks"},"inwardIssue":{"key":"KAN-1"},"outwardIssue":{"key":"KAN-2"}}'
}

test_blocked_by_swaps_the_sides() {
    cloud_board
    link_type_answers
    t_run board issue link add KAN-1 KAN-2 --type blocked-by
    t_status 0
    t_jq "$(sent_bodies)" . '{"type":{"name":"Blocks"},"inwardIssue":{"key":"KAN-2"},"outwardIssue":{"key":"KAN-1"}}'
}

test_a_site_without_the_link_type_is_exit_3() {
    cloud_board
    link_type_answers
    printf '{"issueLinkTypes":[{"name":"Relates"}]}' | ans GET_rest_api_2_issueLinkType
    t_run board issue link add KAN-1 KAN-2 --type blocks
    t_status 3
}

test_removing_a_link_finds_its_id() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    link_issue
    printf '' | ans DELETE_rest_api_2_issueLink_9 204
    t_run board issue link remove KAN-1 KAN-2 --type blocks
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'DELETE https://site.atlassian.net/rest/api/2/issueLink/9'
}

test_removing_a_link_that_is_not_there_succeeds() {
    cloud_board
    printf '[]' | ans GET_rest_api_2_field
    link_issue
    t_run board issue link remove KAN-1 KAN-2 --type relates
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" DELETE
}

# --- what Jira cannot do, and the groups -----------------------------------------------------

test_status_and_label_changes_are_exit_3_with_the_reason() {
    cloud_board
    t_run board status add x --category todo
    t_status 3
    t_contains "$T_ERR" workflows
    t_run board status rename a b
    t_status 3
    t_run board status delete a --yes
    t_status 3
    t_run board label create x
    t_status 3
    t_contains "$T_ERR" 'free text'
    t_run board label edit x --name y
    t_status 3
    t_run board label delete x --yes
    t_status 3
    no_request
}

test_label_list_is_exit_3_on_data_center() {
    dc_board
    t_run board label list
    t_status 3
    no_request
}

test_label_list_reads_plain_names_on_cloud() {
    cloud_board
    printf '{"startAt":0,"isLast":true,"values":["a","b"]}' | ans GET_rest_api_2_label
    t_run board label list --json
    t_status 0
    t_jq "$T_OUT" 'map(.name)' '["a","b"]'
    t_jq "$T_OUT" '.[0].id' null
}

test_sprints_need_a_declared_board() {
    cloud_board
    t_run board sprint list
    t_status 3
    t_contains "$T_ERR" '[board.target] board'
    no_request
}

test_a_board_without_sprints_is_exit_3() {
    dc_board
    printf '{"errorMessages":["The board does not support sprints"],"errors":{}}' |
        ans GET_rest_agile_1.0_board_7_sprint 400
    t_run board sprint list
    t_status 3
    t_contains "$T_ERR" 'does not support sprints'
    t_lacks "$(cat "$FAKE_LOG")" myself
}

sprint_answers() {
    printf '{"isLast":true,"startAt":0,"values":[
        {"id":1,"name":"S1","state":"closed","startDate":"2026-01-01T00:00:00.000Z","endDate":"2026-01-14T00:00:00.000Z"},
        {"id":2,"name":"S2","state":"active","startDate":"2026-02-01T00:00:00.000Z"},
        {"id":3,"name":"S3","state":"future"}]}' | ans GET_rest_agile_1.0_board_7_sprint
}

test_sprints_list_newest_first() {
    dc_board
    sprint_answers
    t_run board sprint list --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["3","2","1"]'
    t_jq "$T_OUT" '.[2]' '{"id":"1","name":"S1","state":"closed","start_date":"2026-01-01","end_date":"2026-01-14"}'
}

test_sprint_current_is_the_active_one_or_exit_4() {
    dc_board
    sprint_answers
    t_run board sprint current --jq .name
    t_status 0
    t_eq "$T_OUT" S2
    printf '{"isLast":true,"startAt":0,"values":[]}' | ans GET_rest_agile_1.0_board_7_sprint
    t_run board sprint current
    t_status 4
}

test_edit_into_a_sprint_goes_through_the_agile_api() {
    dc_board
    sprint_answers
    view_answers
    printf '' | ans POST_rest_agile_1.0_sprint_2_issue 204
    t_run board issue edit KAN-1 --sprint current
    t_status 0
    t_jq "$(sent_bodies)" .issues '["KAN-1"]'
}

test_a_data_center_sprint_string_reads_as_a_name() {
    dc_board
    printf '[{"id":"customfield_10100","schema":{"custom":"com.pyxis.greenhopper.jira:gh-sprint"}}]' | ans GET_rest_api_2_field
    issue_json KAN-1 | t_jq_cmd -c '.fields.customfield_10100 = [
        "com.atlassian.greenhopper.service.sprint.Sprint@1f[id=1,rapidViewId=7,state=CLOSED,name=Old,startDate=2026-01-01]",
        "com.atlassian.greenhopper.service.sprint.Sprint@2f[id=2,rapidViewId=7,state=ACTIVE,name=Now,startDate=2026-02-01]"]' |
        ans GET_rest_api_2_issue_KAN-1
    t_run board issue view KAN-1 --jq .sprint
    t_status 0
    t_eq "$T_OUT" Now
    t_contains "$(cat "$FAKE_LOG")" 'customfield_10100'
}

test_a_version_reads_as_a_milestone() {
    cloud_board
    printf '[{"id":"1","name":"a","released":true,"releaseDate":"2026-01-01"},{"id":"2","name":"b","released":false}]' |
        ans GET_rest_api_2_project_KAN_versions
    t_run board milestone list --json
    t_status 0
    t_jq "$T_OUT" 'map(.name)' '["b"]'
    t_run board milestone list --state closed --json
    t_jq "$T_OUT" '.[0] | {state, due_date, url}' \
        '{"state":"closed","due_date":"2026-01-01","url":"https://site.atlassian.net/projects/KAN/versions/1"}'
}

test_closing_a_milestone_releases_the_version() {
    cloud_board
    printf '{"id":"1","name":"a","released":true}' | ans PUT_rest_api_2_version_1
    t_run board milestone edit 1 --state closed --json
    t_status 0
    t_jq "$(sent_bodies)" . '{"released":true}'
    t_jq "$T_OUT" .state '"closed"'
}

test_comment_bodies_convert_both_ways() {
    cloud_board
    printf '{"id":"5","body":"*b*","author":{"accountId":"a"},"created":"2026-11-02T01:04:07.800+1100","updated":"2026-11-02T01:04:07.800+1100"}' |
        ans POST_rest_api_2_issue_KAN-1_comment
    t_run board issue comment add KAN-1 --body '**b**' --json
    t_status 0
    t_jq "$(sent_bodies)" .body '"*b*"'
    t_jq "$T_OUT" .body '"**b**"'
    t_jq "$T_OUT" .url '"https://site.atlassian.net/browse/KAN-1?focusedCommentId=5"'
}

test_an_id_cannot_leave_its_path() {
    cloud_board
    t_run board issue view ../../evil
    t_status 2
    t_run board issue comment delete KAN-1 ../x --yes
    t_status 2
    t_run board milestone view ../x
    t_status 2
    no_request
}

test_board_view_groups_statuses_into_columns() {
    dc_board
    printf '[{"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},{"id":"2","name":"Doing","statusCategory":{"key":"indeterminate"}},{"id":"3","name":"Review","statusCategory":{"key":"indeterminate"}}]}]' |
        ans GET_rest_api_2_project_KAN_statuses
    printf '{"id":7,"name":"B","columnConfig":{"columns":[{"name":"Open","statuses":[{"id":"1"}]},{"name":"Work","statuses":[{"id":"2"},{"id":"3"}]}]}}' |
        ans GET_rest_agile_1.0_board_7_configuration
    t_run board view --json
    t_status 0
    t_jq "$T_OUT" .columns '[{"name":"Open","statuses":["To Do"]},{"name":"Work","statuses":["Doing","Review"]}]'
    t_jq "$T_OUT" .url '"https://jira.corp.example/secure/RapidBoard.jspa?rapidView=7"'
}

test_api_sends_a_json_body_and_refuses_anything_else() {
    cloud_board
    printf '{"ok":true}' | ans POST_rest_api_2_x
    t_run sh -c 'printf "{ \"a\": 1 }" | sh "$BOARD_TEST_ROOT/bin/board" api POST /rest/api/2/x'
    t_status 0
    t_eq "$T_OUT" '{"ok":true}'
    t_jq "$(sent_bodies)" . '{"a":1}'
    t_run sh -c 'printf "@/etc/passwd" | sh "$BOARD_TEST_ROOT/bin/board" api POST /rest/api/2/x'
    t_status 2
}

# --- init ----------------------------------------------------------------------------------

init_statuses() {
    printf '[{"statuses":[{"id":"1","name":"To Do","statusCategory":{"key":"new"}},{"id":"2","name":"Won'"'"'t Do","statusCategory":{"key":"done"}}]}]' |
        ans "${1:-GET_rest_api_2_project_KAN_statuses}"
}

# Usage: init_home <trusted host>  — init has no [board] config, so the login is the user's.
init_home() {
    jira_home
    BOARD_JIRA_HOSTS=$1
    export BOARD_JIRA_HOSTS
    mkdir -p "$HOME/.config/.jira"
    printf 'login: me@example.com\n' >"$HOME/.config/.jira/.config.yml"
}

test_init_with_a_token_and_no_login_is_exit_5() {
    jira_home
    BOARD_JIRA_HOSTS=site.atlassian.net
    export BOARD_JIRA_HOSTS
    t_run board init --url https://site.atlassian.net/browse/KAN
    t_status 5
    t_contains "$T_ERR" login
    no_request
}

test_init_reads_a_board_url() {
    init_home work-40585442.atlassian.net
    init_statuses
    t_run board init --url https://work-40585442.atlassian.net/jira/software/projects/KAN/boards/1 --json
    t_status 0
    t_run board config get project
    t_eq "$T_OUT" KAN
    t_run board config get target.board
    t_eq "$T_OUT" 1
    t_run board config get url
    t_eq "$T_OUT" https://work-40585442.atlassian.net
    t_contains "$(cat workflow.toml)" '"Won'"'"'t Do" = "canceled"'
    t_lacks "$(cat workflow.toml)" 'To Do'
}

test_init_reads_a_browse_url() {
    init_home site.atlassian.net
    init_statuses
    t_run board init --url https://site.atlassian.net/browse/KAN --dry-run
    t_status 0
    t_contains "$T_OUT" 'project = "KAN"'
    t_lacks "$T_OUT" '[board.target]'
    t_run board init --url https://site.atlassian.net/browse/kan-12 --dry-run
    t_status 0
    t_contains "$T_OUT" 'project = "KAN"'
}

test_init_reads_self_hosted_with_a_context_path() {
    init_home tracker.corp.example
    init_statuses
    init_statuses GET_jira_rest_api_2_project_KAN_statuses
    t_run board init --kind jira --url https://tracker.corp.example/jira/browse/KAN-1 --dry-run
    t_status 0
    t_contains "$T_OUT" 'url = "https://tracker.corp.example/jira"'
    t_run board init --kind jira --url 'https://tracker.corp.example/secure/RapidBoard.jspa?rapidView=7&projectKey=KAN' --dry-run
    t_status 0
    t_contains "$T_OUT" 'board = 7'
    t_contains "$T_OUT" 'url = "https://tracker.corp.example"'
}

test_init_finds_the_project_of_a_board() {
    init_home tracker.corp.example
    init_statuses
    printf '{"id":7,"location":{"projectKey":"KAN"}}' | ans GET_rest_agile_1.0_board_7
    t_run board init --kind jira --url 'https://tracker.corp.example/secure/RapidBoard.jspa?rapidView=7' --dry-run
    t_status 0
    t_contains "$T_OUT" 'project = "KAN"'
}

test_init_refuses_a_url_with_no_project() {
    jira_home
    BOARD_JIRA_HOSTS=site.atlassian.net
    export BOARD_JIRA_HOSTS
    t_run board init --url https://site.atlassian.net/wiki/spaces/X
    t_status 2
    no_request
}

# --- converters ----------------------------------------------------------------------------

convert() {
    conv_lib=$(cat "$BOARD_TEST_ROOT/lib/jira/md2wiki.jq" "$BOARD_TEST_ROOT/lib/jira/wiki2md.jq")
    printf '%s' "$2" | t_jq_cmd -Rrs "$conv_lib $1"
}

m2w() {
    t_eq "$(convert md2wiki "$1")" "$2" "md2wiki of [$1]"
}

w2m() {
    t_eq "$(convert wiki2md "$1")" "$2" "wiki2md of [$1]"
}

test_md2wiki_headings() {
    m2w '# one' 'h1. one'
    m2w '###### six' 'h6. six'
    m2w '## closed ##' 'h2. closed'
    m2w '#notheading' '#notheading'
}

test_md2wiki_emphasis() {
    m2w '**b** and *i*' '*b* and _i_'
    m2w '__b__ and _i_' '*b* and _i_'
    m2w '~~gone~~' '-gone-'
    m2w '**жирный** *курсив*' '*жирный* _курсив_'
    m2w '2 * 3 * 4' '2 * 3 * 4'
    m2w 'snake_case_word' 'snake_case_word'
}

test_md2wiki_inline_code_is_left_alone() {
    m2w 'run `a *b* _c_ {d}` now' 'run {{a *b* _c_ {d}}} now'
}

test_md2wiki_code_block_with_language() {
    got=$(convert md2wiki '```python
x = **1**
```')
    t_eq "$got" '{code:python}
x = **1**
{code}'
}

test_md2wiki_code_block_with_no_language_and_no_close() {
    t_eq "$(convert md2wiki '```
a')" '{code}
a
{code}'
}

test_md2wiki_lists_nest_by_indent() {
    m2w '- a
  - b
    - c
- d' '* a
** b
*** c
* d'
    m2w '1. a
2. b' '# a
# b'
    m2w '1. a
   - b
   - c
2. d' '# a
#* b
#* c
# d'
}

test_md2wiki_links() {
    m2w '[text](https://x.example/a_b_c)' '[text|https://x.example/a_b_c]'
    m2w '![alt](https://x.example/i.png)' '!https://x.example/i.png!'
    m2w '<https://x.example>' '[https://x.example]'
    m2w 'see https://x.example/a_b_c.' 'see https://x.example/a_b_c.'
}

test_md2wiki_line_breaks() {
    got=$(convert md2wiki "$(printf 'one  \ntwo')")
    t_eq "$got" "$(printf 'one\\\\\ntwo')" 'two spaces'
    got=$(convert md2wiki "$(printf 'one\\\ntwo')")
    t_eq "$got" "$(printf 'one\\\\\ntwo')" backslash
    m2w 'soft
wrap' 'soft
wrap'
}

test_md2wiki_keeps_line_endings_simple() {
    t_eq "$(convert md2wiki "$(printf 'a\r\nb')")" 'a
b'
}

test_md2wiki_table_quote_and_rule() {
    m2w '| a | b |
|---|---|
| 1 | 2 |' '||a||b||
|1|2|'
    m2w '> quoted' 'bq. quoted'
    m2w '---' '----'
}

test_md2wiki_escapes_what_would_start_a_macro() {
    m2w 'a {b} [c]' 'a \{b} \[c]'
}

test_md2wiki_keeps_cyrillic_and_a_slash_command() {
    m2w 'строка 2 /start' 'строка 2 /start'
}

test_wiki2md_headings() {
    w2m 'h1. one' '# one'
    w2m 'h6. six' '###### six'
    w2m 'h3. Заголовок' '### Заголовок'
}

test_wiki2md_emphasis() {
    w2m '*b* and _i_' '**b** and *i*'
    w2m '-gone- +under+' '~~gone~~ under'
    w2m '*жирный* _курсив_' '**жирный** *курсив*'
    w2m '2*3*4 snake_case_word 2026-11-02' '2*3*4 snake_case_word 2026-11-02'
}

test_wiki2md_inline_code() {
    w2m '{{a *b*}}' '`a *b*`'
}

test_wiki2md_a_macro_name_in_inline_code_is_not_a_macro() {
    w2m 'use {{code}} and {{quote}} here' 'use `code` and `quote` here'
}

test_wiki2md_code_blocks() {
    t_eq "$(convert wiki2md '{code:java}
int *x*;
{code}')" '```java
int *x*;
```'
    t_eq "$(convert wiki2md '{code:title=a.py|language=python}x{code}')" '```python
x
```'
    t_eq "$(convert wiki2md '{noformat}
_raw_
{noformat}')" '```
_raw_
```'
}

test_wiki2md_lists_nest_by_their_markers() {
    w2m '* a
** b
*** c
* d' '- a
  - b
    - c
- d'
    w2m '# a
# b
#* c
# d' '1. a
2. b
   - c
3. d'
}

test_wiki2md_links() {
    w2m '[t|https://x.example/a_b]' '[t](https://x.example/a_b)'
    w2m '[https://x.example]' '<https://x.example>'
    w2m '!a.png|thumbnail!' '![a.png](a.png)'
    w2m 'see https://x.example/a_b_c' 'see https://x.example/a_b_c'
}

test_wiki2md_line_breaks() {
    t_eq "$(convert wiki2md 'one\\two')" "$(printf 'one  \ntwo')" 'mid-line'
    t_eq "$(convert wiki2md 'one\\
two')" "$(printf 'one  \ntwo')" 'at the end'
}

test_wiki2md_panel_degrades_to_a_quote() {
    t_eq "$(convert wiki2md '{panel:title=Важно|bgColor=#deebff}
inside *b*
{panel}
after')" '> **Важно**
> inside **b**
after'
}

test_wiki2md_table_degrades_to_markdown() {
    w2m '||A||B||
|1|[t|https://x.example]|' '| A | B |
| --- | --- |
| 1 | [t](https://x.example) |'
}

test_wiki2md_mentions_degrade_to_text() {
    w2m 'hi [~accountid:5b10a2844c20165700ede21g]' 'hi @5b10a2844c20165700ede21g'
    w2m 'hi [~jsmith]' 'hi @jsmith'
}

test_wiki2md_color_and_escapes() {
    w2m '{color:red}red{color} \{x\}' 'red {x}'
    w2m 'bq. q' '> q'
    w2m '----' '---'
}

test_round_trip_keeps_the_common_cases() {
    for text in 'plain строка /start' '**b** *i*' '`code`' '[t](https://x.example)'; do
        t_eq "$(convert 'md2wiki | wiki2md' "$text")" "$text" 'round trip'
    done
}

test_converters_are_within_their_limit() {
    for file in md2wiki wiki2md; do
        lines=$(wc -l <"$BOARD_TEST_ROOT/lib/jira/$file.jq")
        [ "$lines" -lt 400 ] || t_fail "$file.jq has $lines lines"
    done
}

# Every filter carries this text in argv, and Windows stops argv at about 32,000 characters.
test_the_library_fits_in_argv() {
    size=$(cat "$BOARD_TEST_ROOT/lib/jq/common.jq" "$BOARD_TEST_ROOT"/lib/jira/*.jq | wc -c)
    [ "$size" -lt 28000 ] || t_fail "BOARD_LIB of jira is $size bytes"
}

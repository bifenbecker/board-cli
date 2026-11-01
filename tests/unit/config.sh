# shellcheck shell=sh

test_reads_board_section_and_ignores_the_rest() {
    t_workflow <<'EOF'
# a project file with other sections
[git]
host = "gitlab"
kind = "not-this"

[board]
kind      = "jira"          # a trailing comment
cli       = "jira"
url       = "https://x.atlassian.net/"
project   = "KAN"
config    = ".jira.yml"
issue_uri = "/browse/{ticket}"

[board.labels]
blocked = "Cannot proceed # not a comment"

[board.size]
XS = 1   # a few hours

[tools]
required = ["git>=2.38", "jq"]
EOF
    t_run board config show --json
    t_status 0
    t_jq "$T_OUT" .kind '"jira"'
    t_jq "$T_OUT" .project '"KAN"'
    t_jq "$T_OUT" .labels.blocked '"Cannot proceed # not a comment"'
    t_jq "$T_OUT" .size.XS 1
    t_jq "$T_OUT" 'has("host")' false
}

test_quoted_keys_and_cyrillic() {
    t_workflow <<'EOF'
[board]
kind = "gitlab"
url  = "https://gitlab.com/a/b"

[board.statuses]
"In Progress" = "in_progress"
"Готово"      = "done"
'Won''t do'   = "canceled"
EOF
    t_run board config show --json
    t_status 0
    t_jq "$T_OUT" '.statuses["In Progress"]' '"in_progress"'
    t_jq "$T_OUT" '.statuses["Готово"]' '"done"'
}

test_crlf_file_reads_clean() {
    printf '[board]\r\nkind = "github"\r\nurl = "https://github.com/a/b"\r\n' >workflow.toml
    WORKFLOW_FILE=$T_TMP/workflow.toml
    export WORKFLOW_FILE
    t_run board config get url
    t_status 0
    t_eq "$T_OUT" https://github.com/a/b
}

test_found_above_the_working_directory() {
    t_workflow <<'EOF'
[board]
kind = "linear"
url  = "https://linear.app/x"
EOF
    unset WORKFLOW_FILE
    mkdir -p deep/er
    cd deep/er || exit 1
    t_run board config path
    t_status 0
    t_contains "$T_OUT" /workflow.toml
}

test_no_file_is_a_usage_error() {
    t_run env WORKFLOW_FILE=/no/such/file sh "$BOARD_TEST_ROOT/bin/board" config show
    t_status 2
}

test_no_board_section_points_at_init() {
    t_workflow <<'EOF'
[git]
host = "github"
EOF
    t_run board config show
    t_status 2
    t_contains "$T_ERR" 'board init'
}

test_unknown_kind_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "trello"
url  = "https://x"
EOF
    t_run board config show
    t_status 2
    t_contains "$T_ERR" trello
}

test_value_cannot_run_as_code() {
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://x.atlassian.net"
project = "$(touch pwned)'; touch pwned; '"
EOF
    t_run board config get project
    t_status 0
    [ ! -e pwned ] || t_fail "a config value ran as code"
}

test_config_get_absent_key_is_not_found() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get target.board
    t_status 4
}

test_config_get_rejects_a_filter() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get '.;env'
    t_status 2
}

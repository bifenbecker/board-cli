# shellcheck shell=sh disable=SC2317,SC2329

# Findings of the second adversarial review, kept as tests. workflow.toml comes with a repository,
# and a board's answer comes from a network: neither may run anything or hang board.

test_value_cannot_splice_an_array_into_the_config() {
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://x.atlassian.net"
project = "x","project":["x","sh","-c","touch PWNED"],"z":"y"
EOF
    t_run board config path
    t_status 2
    [ ! -e PWNED ] || t_fail "a value ran as code"
}

test_array_value_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
cli  = ["a"]
EOF
    t_run board config show
    t_status 2
}

test_url_with_userinfo_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com@evil.example/a/b"
EOF
    t_run board config show
    t_status 2
    t_contains "$T_ERR" host
}

test_url_must_be_a_url() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "--output=/tmp/x"
EOF
    t_run board config show
    t_status 2
}

test_board_section_as_a_table_of_url_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "jira"
[board.url]
a = "b"
EOF
    t_run board config show
    t_status 2
}

test_multi_line_string_cannot_declare_a_board() {
    cat >workflow.toml <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"

[notes]
text = """
[board]
url = "https://attacker.example.com"
"""
EOF
    WORKFLOW_FILE=$T_TMP/workflow.toml
    export WORKFLOW_FILE
    t_run board config get url
    t_status 0
    t_eq "$T_OUT" https://github.com/a/b
}

test_duplicate_key_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"
url  = "https://github.com/c/d"
EOF
    t_run board config show
    t_status 2
    t_contains "$T_ERR" twice
}

test_escaped_quote_and_hash_stay_in_the_value() {
    t_workflow <<'EOF'
[board]
kind    = "jira"
url     = "https://x.atlassian.net"
project = "a\"b#c"
EOF
    t_run board config get project
    t_status 0
    t_eq "$T_OUT" 'a"b#c'
}

test_spaced_and_dotted_forms_read_the_same() {
    t_workflow <<'EOF'
[ board ]
kind = "github"
url  = "https://github.com/a/b"
statuses.Todo = "todo"

[ board . target ]
number = 5
EOF
    t_run board config show --json
    t_status 0
    t_jq "$T_OUT" .statuses.Todo '"todo"'
    t_jq "$T_OUT" .target.number 5
}

test_table_array_named_board_is_not_the_board() {
    t_workflow <<'EOF'
[[board]]
kind = "github"
url  = "https://github.com/a/b"
EOF
    t_run board config show
    t_status 2
}

hostile_paged() {
    BOARD_HOME=$BOARD_TEST_ROOT
    export BOARD_HOME
    . "$BOARD_HOME/lib/core/util.sh"
    . "$BOARD_HOME/lib/core/exec.sh"
    . "$BOARD_HOME/lib/core/gql.sh"
    board_jq_probe
    board_tmp_init
}

test_paging_stops_on_a_page_that_is_not_json() {
    hostile_paged
    bad_page() { printf '<html>rate limited</html>'; }
    t_run sh -c 'exit 0'
    st=0
    (board_paged bad_page all) >out 2>err || st=$?
    t_eq "$st" 1 status
}

test_paging_stops_on_a_page_without_nodes() {
    hostile_paged
    no_nodes() { printf '{"nodes":null,"has_next":false}'; }
    st=0
    (board_paged no_nodes all) >out 2>err || st=$?
    t_eq "$st" 1 status
}

test_paging_stops_when_the_cursor_does_not_move() {
    hostile_paged
    same_page() { printf '{"nodes":[{"a":1}],"has_next":true,"end_cursor":"x"}'; }
    st=0
    (board_paged same_page all) >out 2>err || st=$?
    t_eq "$st" 1 status
}

test_cursor_from_a_board_cannot_run_as_code() {
    hostile_paged
    bad_cursor() { printf '{"nodes":[],"has_next":false,"end_cursor":["x","sh","-c","touch PWNED"]}'; }
    (board_paged bad_cursor all) >out 2>err || true
    [ ! -e PWNED ] || t_fail "a cursor ran as code"
}

test_bad_filter_is_refused_before_a_write() {
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"
[board.target]
owner  = "a"
number = 5
EOF
    t_run board issue create --title t --jq '.['
    t_status 2
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

test_filter_may_start_with_a_dash() {
    t_run board version --jq '-1'
    t_status 0
    t_eq "$T_OUT" -1
}

test_text_value_may_look_like_a_global_flag() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"
EOF
    t_run board issue create --body --help
    t_status 2
    t_contains "$T_ERR" --title
}

test_install_refuses_an_empty_prefix() {
    t_run sh "$BOARD_TEST_ROOT/install.sh" --prefix ''
    t_status 1
    t_contains "$T_ERR" empty
}

test_install_does_not_replace_a_checkout() {
    mkdir -p bin share
    cp "$BOARD_TEST_ROOT/bin/board" bin/board
    t_run sh "$BOARD_TEST_ROOT/install.sh" --from "$BOARD_TEST_ROOT" --prefix "$T_TMP"
    t_status 1
    t_contains "$T_ERR" 'not installed by board'
}

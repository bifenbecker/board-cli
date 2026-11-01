# shellcheck shell=sh

# workflow.toml arrives with a repository, so nothing in it may decide what runs on this machine.

test_cli_cannot_name_a_program_in_the_repository() {
    printf '#!/bin/sh\ntouch pwned\n' >evil
    chmod +x evil
    t_workflow <<'EOF'
[board]
kind = "github"
cli  = "./evil"
url  = "https://github.com/a/b"
[board.target]
owner  = "a"
number = 5
EOF
    t_run board issue list
    t_status 2
    [ ! -e pwned ] || t_fail "a program named in workflow.toml ran"
}

test_cli_cannot_name_another_tool() {
    t_workflow <<'EOF'
[board]
kind = "github"
cli  = "sh"
url  = "https://github.com/a/b"
EOF
    t_run board issue list
    t_status 2
    t_contains "$T_ERR" "cli 'sh'"
}

test_the_usual_tool_is_accepted() {
    t_workflow <<'EOF'
[board]
kind = "jira"
cli  = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get cli
    t_status 0
}

test_foreign_github_host_is_refused() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.evil.example/a/b"

[board.target]
owner  = "a"
number = 5
EOF
    t_run board issue list
    t_status 5
    t_contains "$T_ERR" BOARD_TRUSTED_HOSTS
    [ ! -s "$FAKE_LOG" ] || t_fail "the host was reached: $(cat "$FAKE_LOG")"
}

test_host_named_by_the_user_is_accepted() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.acme.example/a/b"

[board.target]
owner  = "a"
number = 5
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    printf '{"data":{"viewer":{"login":"me"}}}' >"$FAKE_OVERRIDE/Viewer.json"
    BOARD_TRUSTED_HOSTS='github.acme.example other.example'
    export BOARD_TRUSTED_HOSTS
    t_run board auth status --jq .user
    t_status 0
    t_eq "$T_OUT" me
}

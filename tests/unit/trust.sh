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

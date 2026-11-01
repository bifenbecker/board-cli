# shellcheck shell=sh

test_bare_call_prints_orientation() {
    t_run board
    t_status 0
    t_contains "$T_OUT" 'START HERE'
    t_contains "$T_OUT" 'EXIT CODES'
    t_contains "$T_OUT" 'board doctor'
}

test_version_matches_the_file() {
    t_run board --version
    t_status 0
    t_eq "$T_OUT" "$(tr -d '\r\n' <"$BOARD_TEST_ROOT/VERSION")"
}

test_version_as_json() {
    t_run board version --jq .version
    t_status 0
    t_eq "$T_OUT" "$(tr -d '\r\n' <"$BOARD_TEST_ROOT/VERSION")"
}

test_unknown_command_is_usage() {
    t_run board nonsense
    t_status 2
    t_contains "$T_ERR" "unknown command"
}

test_command_help_has_exit_codes() {
    t_run board version --help
    t_status 0
    t_contains "$T_OUT" 'EXIT CODES'
    t_contains "$T_OUT" 'partial'
}

test_group_without_subcommand_prints_its_help() {
    t_run board config
    t_status 0
    t_contains "$T_OUT" COMMANDS
}

test_global_flag_is_found_after_the_command() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get --jq . kind
    t_status 0
    t_eq "$T_OUT" jira
}

test_flag_with_equals_is_split() {
    t_run board --jq=.version version
    t_status 0
    t_eq "$T_OUT" "$(tr -d '\r\n' <"$BOARD_TEST_ROOT/VERSION")"
}

test_slash_argument_survives_git_bash() {
    # Git Bash rewrites /start into a Windows path unless board turns that off.
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get --jq '"/start"' kind
    t_status 0
    t_eq "$T_OUT" /start
}

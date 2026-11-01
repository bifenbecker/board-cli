# shellcheck shell=sh

init_answers() {
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    cat >"$FAKE_OVERRIDE/ProjectMeta.json" <<'EOF'
{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_x","title":"t","url":"u","workflows":{"nodes":[]},
"fields":{"nodes":[{"id":"F","name":"Status","dataType":"SINGLE_SELECT","options":[
{"id":"1","name":"Todo"},{"id":"2","name":"In Progress"},{"id":"3","name":"Done"},{"id":"4","name":"Странный"}]}]}}}}}
EOF
}

init_run() {
    t_run board init --url https://github.com/users/a/projects/5 --repo a/b "$@"
}

test_creates_a_file_when_there_is_none() {
    init_answers
    init_run
    t_status 0
    t_eq "$T_OUT" workflow.toml
    t_run board config get target.number
    t_eq "$T_OUT" 5 number
    t_run board config get url
    t_eq "$T_OUT" https://github.com/a/b url
}

test_status_it_cannot_place_stays_commented_out() {
    init_answers
    init_run
    t_contains "$(cat workflow.toml)" '# "Странный" = ""'
    t_contains "$(cat workflow.toml)" '"In Progress" = "in_progress"'
}

test_dry_run_writes_nothing() {
    init_answers
    init_run --dry-run
    t_status 0
    t_contains "$T_OUT" '[board]'
    [ ! -e workflow.toml ] || t_fail "dry run wrote a file"
}

test_keeps_what_the_file_has() {
    init_answers
    printf '[git]\nhost = "github"\n' >workflow.toml
    init_run
    t_status 0
    t_contains "$(cat workflow.toml)" 'host = "github"'
    t_contains "$(cat workflow.toml)" '[board]'
}

test_adds_only_missing_sections() {
    init_answers
    cat >workflow.toml <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"

[tools]
required = ["jq"]
EOF
    init_run
    t_status 0
    t_contains "$(cat workflow.toml)" '[board.target]'
    t_eq "$(grep -c '^\[board\]' workflow.toml)" 1 'board sections'
}

test_running_twice_changes_nothing() {
    init_answers
    init_run
    first=$(cat workflow.toml)
    t_run rm -f "$T_TMP/.fake/ProjectMeta"
    init_run
    t_status 0
    t_eq "$(cat workflow.toml)" "$first" file
}

test_empty_status_section_is_not_declared_twice() {
    init_answers
    cat >workflow.toml <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"

[board.statuses]
# nothing placed yet
EOF
    init_run
    t_status 0
    t_eq "$(grep -c '^\[board\.statuses\]' workflow.toml)" 1 'status sections'
}

test_another_board_is_not_overwritten() {
    init_answers
    cat >workflow.toml <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    before=$(cat workflow.toml)
    init_run
    t_status 2
    t_contains "$T_OUT" '[board]'
    t_eq "$(cat workflow.toml)" "$before" file
}

test_partial_board_section_is_not_guessed_at() {
    init_answers
    cat >workflow.toml <<'EOF'
[board]
cli = "gh"
EOF
    before=$(cat workflow.toml)
    init_run
    t_status 2
    t_eq "$(cat workflow.toml)" "$before" file
}

test_workflow_file_names_where_to_write() {
    init_answers
    WORKFLOW_FILE=$T_TMP/other.toml
    export WORKFLOW_FILE
    init_run
    t_status 0
    [ -f other.toml ] || t_fail "other.toml was not written"
    [ ! -e workflow.toml ] || t_fail "workflow.toml was written"
}

test_project_url_needs_a_repo() {
    init_answers
    t_run board init --url https://github.com/users/a/projects/5
    t_status 2
    t_contains "$T_ERR" --repo
}

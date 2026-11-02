# shellcheck shell=sh

# Findings of the first adversarial review, kept as tests.

errors_github() {
    t_workflow <<'EOF'
[board]
kind = "github"
cli  = "gh"
url  = "https://github.com/a/b"

[board.target]
owner  = "a"
number = 5

[board.statuses]
"Todo" = "todo"
"Done" = "done"
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
}

test_partial_write_keeps_the_id_on_stdout() {
    . "$BOARD_TEST_ROOT/lib/core/util.sh"
    t_run sh -c '. "$BOARD_TEST_ROOT/lib/core/util.sh"
        doc=$(board_partial 77 "half done") || board_fail "$?" "$doc"'
    t_status 6
    t_eq "$T_OUT" 77 stdout
    t_contains "$T_ERR" 'partial'
}

test_failure_other_than_partial_prints_nothing() {
    t_run sh -c '. "$BOARD_TEST_ROOT/lib/core/util.sh"
        doc=$(exit 4) || board_fail "$?" "$doc"'
    t_status 4
    t_eq "$T_OUT" '' stdout
}

test_unreadable_body_file_is_a_failure_not_an_empty_body() {
    errors_github
    mkdir body-is-a-directory
    t_run board issue edit 12 --body-file body-is-a-directory
    t_status 2
    [ ! -s "$FAKE_LOG" ] || t_fail "the board was reached: $(cat "$FAKE_LOG")"
}

test_bad_jq_filter_is_wrong_usage() {
    t_run board version --jq 'nonsense('
    t_status 2
}

test_jq_runtime_error_is_wrong_usage() {
    t_run board version --jq '.version.a.b'
    t_status 2
}

test_config_get_false_is_a_value() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
flag = false
EOF
    t_run board config get flag
    t_status 0
    t_eq "$T_OUT" false
}

test_config_get_below_a_scalar_is_not_found() {
    t_workflow <<'EOF'
[board]
kind = "jira"
url  = "https://x.atlassian.net"
EOF
    t_run board config get kind.x
    t_status 4
}

test_links_have_string_ids() {
    got=$(jq -nc -L "$BOARD_TEST_ROOT/lib" 'include "jq/common";
        {id: 1, kind: "github", links: [{type: "blocks", id: 12}]} | make_issue({}) | .links[0].id')
    t_eq "$got" '"12"' id
}

test_no_status_name_with_declared_statuses_does_not_crash() {
    got=$(jq -nc -L "$BOARD_TEST_ROOT/lib" 'include "jq/common";
        {id: 1, kind: "github", status: {name: null, native: "todo"}}
        | make_issue({statuses: {Done: "done"}}) | .status.category')
    t_eq "$got" '"todo"' category
}

test_doctor_reports_checks_that_did_not_run() {
    errors_github
    mkdir -p "$FAKE_OVERRIDE"
    printf '{"data":{"viewer":{"login":"me"}}}' >"$FAKE_OVERRIDE/Viewer.json"
    printf '{"errors":[{"type":"FORBIDDEN","message":"no"}]}' >"$FAKE_OVERRIDE/ProjectMeta.json"
    printf 1 >"$FAKE_OVERRIDE/ProjectMeta.status"
    t_run board doctor --json
    t_status 1
    t_jq "$T_OUT" .ok false
    t_jq "$T_OUT" '.errors | length' 1
}

test_label_create_refuses_name_flag() {
    errors_github
    t_run board label create a --name b
    t_status 2
}

test_view_comments_on_a_draft_still_shows_the_item() {
    errors_github
    printf '{"data":{"node":{"id":"PVTI_x","type":"DRAFT_ISSUE","isArchived":false,"status":{"name":"Todo"},"project":{"id":"p","number":5},"content":{"__typename":"DraftIssue","id":"DI_x","title":"t","body":"","assignees":{"nodes":[]}}}}}' >"$FAKE_OVERRIDE/ItemView.json"
    t_run board issue view PVTI_x --comments --json
    t_status 0
    t_jq "$T_OUT" .comments '[]'
    t_jq "$T_OUT" .id '"PVTI_x"'
}

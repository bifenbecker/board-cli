# shellcheck shell=sh

# Findings of the adapter's adversarial review, kept as tests.

gh_board() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"

[board.target]
owner  = "a"
number = 5

[board.statuses]
"Todo"        = "todo"
"В работе"    = "in_progress"
"Done"        = "done"
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    cat >"$FAKE_OVERRIDE/ProjectMeta.json" <<'EOF'
{"data":{"repositoryOwner":{"projectV2":{"id":"PVT_x","title":"t","url":"u","workflows":{"nodes":[]},
"fields":{"nodes":[{"id":"F","name":"Status","dataType":"SINGLE_SELECT","options":[
{"id":"1","name":"Todo","color":"GREEN","description":""},
{"id":"2","name":"В работе","color":"BLUE","description":""},
{"id":"3","name":"Done","color":"PURPLE","description":""}]}]}}}}}
EOF
    printf '{"data":{"viewer":{"login":"me"}}}' >"$FAKE_OVERRIDE/Viewer.json"
}

# An open issue on the project, with labels x and y.
gh_issue_answer() {
    cat >"$FAKE_OVERRIDE/IssueView.json" <<EOF
{"data":{"repository":{"issue":{"id":"I_1","number":${1:-11},"title":"t","body":"","url":"u","state":"${2:-OPEN}",
"repository":{"nameWithOwner":"a/b"},"author":{"login":"me"},"assignees":{"nodes":[]},
"labels":{"nodes":[{"name":"x"},{"name":"y"}]},
"projectItems":{"nodes":[{"id":"PVTI_1","type":"ISSUE","isArchived":false,"status":{"name":"Todo","optionId":"1"},
"project":{"id":"PVT_x","number":5,"owner":{"login":"a"}}}]}}}}}
EOF
}

gh_log() {
    cat "$FAKE_LOG" 2>/dev/null
}

gh_stdin() {
    cat "$FAKE_LOG.stdin" 2>/dev/null
}

gh_list_answer() {
    cat >"$FAKE_OVERRIDE/BoardItems.json" <<'EOF'
{"data":{"repositoryOwner":{"projectV2":{"items":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"id":"PVTI_1","type":"ISSUE","isArchived":false,"status":{"name":"Todo"},
 "content":{"__typename":"Issue","number":1,"title":"plain","body":"has a needle inside","url":"u","state":"OPEN",
  "repository":{"nameWithOwner":"a/b"},"assignees":{"nodes":[]},"labels":{"nodes":[{"name":"x\"q"}]}}},
{"id":"PVTI_2","type":"PULL_REQUEST","isArchived":false,"status":{"name":"Todo"},
 "content":{"__typename":"PullRequest","number":4,"title":"a pr","body":"","url":"u","state":"OPEN",
  "repository":{"nameWithOwner":"a/b"},"assignees":{"nodes":[]},"labels":{"nodes":[]}}},
{"id":"PVTI_3","type":"ISSUE","isArchived":false,"status":{"name":"Done"},
 "content":{"__typename":"Issue","number":3,"title":"closed","body":"","url":"u","state":"CLOSED",
  "repository":{"nameWithOwner":"a/b"},"assignees":{"nodes":[{"login":"me"}]},"labels":{"nodes":[{"name":"Bug"}]},
  "parent":{"number":1,"repository":{"nameWithOwner":"a/b"}}}}
]}}}}}
EOF
}

test_edit_adds_a_label_without_resending_the_others() {
    gh_board
    gh_issue_answer
    printf '[]' >"$FAKE_OVERRIDE/POST_repos_a_b_issues_11_labels.json"
    t_run board issue edit 11 --add-label new --json
    t_status 0
    t_contains "$(gh_stdin)" '"labels":["new"]' body
    t_lacks "$(gh_stdin)" '"x"' body
}

test_removing_a_label_that_is_not_there_succeeds() {
    gh_board
    gh_issue_answer
    printf '{"message":"Label does not exist"}' >"$FAKE_OVERRIDE/DELETE_repos_a_b_issues_11_labels_nope.json"
    printf 'gh: Label does not exist (HTTP 404)\n' >"$FAKE_OVERRIDE/DELETE_repos_a_b_issues_11_labels_nope.err"
    printf 1 >"$FAKE_OVERRIDE/DELETE_repos_a_b_issues_11_labels_nope.status"
    t_run board issue edit 11 --remove-label nope --json
    t_status 0
}

test_create_checks_the_status_before_it_writes() {
    gh_board
    t_run board issue create --title t --status Nope
    t_status 2
    t_lacks "$(gh_log)" 'repos/a/b/issues' log
}

test_undeclared_priority_stops_before_a_write() {
    gh_board
    t_run board issue create --title t --priority urgent
    t_status 3
    t_lacks "$(gh_log)" 'repos/a/b/issues' log
}

test_issue_exists_and_view_fails_is_partial() {
    gh_board
    printf '{"number":77,"node_id":"I_77"}' >"$FAKE_OVERRIDE/POST_repos_a_b_issues.json"
    printf '{"data":{"addProjectV2ItemById":{"item":{"id":"PVTI_77"}}}}' >"$FAKE_OVERRIDE/AddItem.json"
    printf '{"errors":[{"type":"OTHER","message":"boom"}]}' >"$FAKE_OVERRIDE/IssueView.json"
    printf 1 >"$FAKE_OVERRIDE/IssueView.status"
    t_run board issue create --title t
    t_status 6
    t_eq "$T_OUT" 77 stdout
}

test_failed_parent_with_nothing_written_is_not_partial() {
    gh_board
    gh_issue_answer
    t_run board issue edit 11 --parent abc
    t_status 2
}

test_reopen_with_a_bad_status_does_not_reopen() {
    gh_board
    gh_issue_answer 11 CLOSED
    t_run board issue reopen 11 --status Nope
    t_status 2
    t_lacks "$(gh_log)" PATCH log
}

test_close_as_canceled_with_no_such_status_writes_nothing() {
    gh_board
    gh_issue_answer
    t_run board issue close 11 --reason canceled
    t_status 2
    t_lacks "$(gh_log)" PATCH log
}

test_read_timeout_in_a_move_is_a_plain_failure() {
    gh_board
    gh_issue_answer
    printf 124 >"$FAKE_OVERRIDE/IssueView.status"
    t_run board issue move 11 Done
    t_status 1
}

test_status_rename_finds_cyrillic_in_any_case() {
    gh_board
    printf '{"data":{"updateProjectV2Field":{"projectV2Field":{"options":[]}}}}' >"$FAKE_OVERRIDE/SetOptions.json"
    t_run board status rename 'в РАБОТЕ' Готово
    t_contains "$(gh_stdin)" '"name":"Готово"' body
}

test_milestone_is_looked_up_in_the_repository_of_the_issue() {
    gh_board
    gh_issue_answer 5
    printf '[[{"number":9,"title":"M1"}]]' >"$FAKE_OVERRIDE/GET_repos_o_r_milestones.json"
    printf '{}' >"$FAKE_OVERRIDE/PATCH_repos_o_r_issues_5.json"
    t_run board issue edit 'o/r#5' --milestone M1 --json
    t_status 0
    t_contains "$(gh_log)" 'repos/o/r/milestones' log
    t_contains "$(gh_stdin)" '"milestone":9' body
}

test_type_on_a_user_repository_is_unsupported() {
    gh_board
    gh_issue_answer
    printf '{"data":{"repository":{"issueTypes":null}}}' >"$FAKE_OVERRIDE/IssueTypes.json"
    t_run board issue edit 11 --type Bug
    t_status 3
}

test_pull_requests_are_not_listed() {
    gh_board
    gh_list_answer
    t_run board issue list --category all --jq 'map(.id)'
    t_status 0
    t_lacks "$T_OUT" '"4"' list
}

test_search_reads_the_body() {
    gh_board
    gh_list_answer
    t_run board issue list --category all --search NEEDLE --jq 'map(.id)'
    t_status 0
    t_contains "$T_OUT" '"1"' list
    t_lacks "$T_OUT" '"3"' list
}

test_label_filter_is_decided_here() {
    gh_board
    gh_list_answer
    t_run board issue list --category all --label 'x"q' --jq 'length'
    t_eq "$T_OUT" 1 count
    t_run board issue list --category all --label 'x*' --jq 'length'
    t_eq "$T_OUT" 0 count
    t_run board issue list --category all --label bug --jq 'map(.id)'
    t_contains "$T_OUT" '"3"' 'case'
}

test_names_it_cannot_express_stay_out_of_the_query() {
    gh_board
    gh_list_answer
    t_run board issue list --label 'x*' --status 'a,b'
    t_lacks "$(gh_stdin)" 'label:x' body
    t_lacks "$(gh_stdin)" 'status:a' body
}

test_priority_none_matches_issues_without_one() {
    gh_board
    gh_list_answer
    t_run board issue list --category all --priority none --jq 'length'
    t_eq "$T_OUT" 2 count
}

test_parent_filter_takes_the_long_form() {
    gh_board
    gh_list_answer
    t_run board issue list --category all --parent 'A/B#1' --jq 'map(.id)'
    t_contains "$T_OUT" '"3"' list
}

test_an_item_of_a_pull_request_is_refused() {
    gh_board
    printf '{"data":{"node":{"id":"PVTI_9","type":"PULL_REQUEST","project":{"number":5},"content":{"__typename":"PullRequest","id":"PR_1","number":4}}}}' >"$FAKE_OVERRIDE/ItemView.json"
    t_run board issue close PVTI_9
    t_status 3
}

test_item_id_of_a_real_issue_reaches_its_number() {
    gh_board
    printf '{"data":{"node":{"id":"PVTI_1","type":"ISSUE","isArchived":false,"status":{"name":"Todo"},"project":{"number":5},"content":{"__typename":"Issue","id":"I_1","number":11,"title":"t","url":"u","state":"OPEN","repository":{"nameWithOwner":"a/b"},"assignees":{"nodes":[]},"labels":{"nodes":[]}}}}}' >"$FAKE_OVERRIDE/ItemView.json"
    printf '[[]]' >"$FAKE_OVERRIDE/GET_repos_a_b_issues_11_comments.json"
    t_run board issue comment list PVTI_1 --json
    t_status 0
    t_jq "$T_OUT" . '[]'
}

test_a_draft_cannot_be_a_parent() {
    gh_board
    gh_issue_answer
    printf '{"data":{"node":{"id":"PVTI_d","type":"DRAFT_ISSUE","project":{"number":5},"content":{"__typename":"DraftIssue","id":"DI_1"}}}}' >"$FAKE_OVERRIDE/ItemView.json"
    t_run board issue edit 11 --parent PVTI_d
    t_status 3
}

test_foreign_project_with_the_same_number_is_ignored() {
    gh_board
    cat >"$FAKE_OVERRIDE/IssueView.json" <<'EOF'
{"data":{"repository":{"issue":{"id":"I_1","number":11,"title":"t","url":"u","state":"OPEN",
"repository":{"nameWithOwner":"a/b"},"assignees":{"nodes":[]},"labels":{"nodes":[]},
"projectItems":{"nodes":[
{"id":"PVTI_other","status":{"name":"Elsewhere"},"project":{"number":5,"owner":{"login":"z"}}},
{"id":"PVTI_1","status":{"name":"Todo"},"project":{"number":5,"owner":{"login":"a"}}}]}}}}}
EOF
    t_run board issue view 11 --jq .status.name
    t_eq "$T_OUT" Todo
}

test_url_case_does_not_turn_ids_long() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/A/B"

[board.target]
owner  = "a"
number = 5
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    gh_issue_answer
    t_run board issue view 11 --jq .id
    t_eq "$T_OUT" 11
}

test_missing_project_in_a_list_is_not_found() {
    gh_board
    printf '{"data":{"repositoryOwner":null}}' >"$FAKE_OVERRIDE/BoardItems.json"
    t_run board issue list
    t_status 4
}

test_inherited_ready_flag_changes_nothing() {
    gh_board
    gh_issue_answer
    GH_READY=1
    export GH_READY
    t_run board issue view 11 --jq .id
    t_status 0
}

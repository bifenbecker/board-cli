# shellcheck shell=sh

# The Linear adapter: what a failure means, what travels where, and the places the API is odd.

linear_board() {
    t_workflow <<'EOF'
[board]
kind    = "linear"
url     = "https://linear.app/acme"
project = "3KD"
EOF
    linear_answers
}

linear_narrowed() {
    t_workflow <<'EOF'
[board]
kind    = "linear"
url     = "https://linear.app/acme"
project = "3KD"

[board.target]
project = "982b67e1e776"
EOF
    linear_answers
    linear_meta_answer false ',"project":{"id":"P","name":"Test","url":"https://linear.app/acme/project/test-982b67e1e776"}'
}

linear_answers() {
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    linear_meta_answer false ''
}

# Usage: linear_meta_answer <cycles on?> <text after the team>
linear_meta_answer() {
    cat >"$FAKE_OVERRIDE/BoardMeta.json" <<EOF
{"data":{"team":{"id":"T","key":"3KD","name":"Three","cyclesEnabled":$1,"states":{"nodes":[
{"id":"s-done","name":"Done","type":"completed","position":3},
{"id":"s-triage","name":"Triage","type":"triage","position":0},
{"id":"s-back","name":"Backlog","type":"backlog","position":0},
{"id":"s-prog","name":"In Progress","type":"started","position":0},
{"id":"s-dup","name":"Duplicate","type":"duplicate","position":5},
{"id":"s-canc","name":"Canceled","type":"canceled","position":4}]}}$2}}
EOF
}

# Usage: linear_issue_answer <state JSON> <more fields>  — a repeated key wins over the default.
linear_issue_answer() {
    cat >"$FAKE_OVERRIDE/IssueView.json" <<EOF
{"data":{"issue":{"id":"u1","identifier":"3KD-1","title":"t","description":"d","url":"https://linear.app/acme/issue/3KD-1/t",
"priority":0,"dueDate":null,"trashed":null,"createdAt":"2026-11-01T14:02:59.396Z","updatedAt":"2026-11-01T14:02:59.396Z",
"state":$1,"assignee":null,"creator":null,"labels":{"nodes":[]},"parent":null,"cycle":null,"projectMilestone":null,
"children":{"nodes":[]},"relations":{"nodes":[]},"inverseRelations":{"nodes":[]}$2}}}
EOF
}

linear_backlog='{"id":"s-back","name":"Backlog","type":"backlog"}'

# Usage: linear_fails <op> <stream: out|err> <JSON or text>
linear_fails() {
    printf 1 >"$FAKE_OVERRIDE/$1.status"
    if [ "$2" = out ]; then
        printf '%s' "$3" >"$FAKE_OVERRIDE/$1.json"
    else
        : >"$FAKE_OVERRIDE/$1.json"
        printf '%s\n' "$3" >"$FAKE_OVERRIDE/$1.err"
    fi
}

linear_mutations() {
    grep -c '^mutation' "$FAKE_LOG.stdin" 2>/dev/null || true
}

# --- what a failure means ----------------------------------------------------------------

test_missing_entity_on_stdout_is_not_found() {
    linear_board
    linear_fails IssueView out '{"errors":[{"message":"Entity not found: Issue","extensions":{"code":"INPUT_ERROR","userError":true,"userPresentableMessage":"Could not find referenced Issue."}}],"data":null}'
    t_run board issue view 3KD-99999
    t_status 4
    t_contains "$T_ERR" 'Could not find referenced Issue'
}

test_the_other_wording_of_not_found_is_not_found() {
    linear_board
    linear_fails IssueCreate out '{"errors":[{"message":"issue not found","extensions":{"code":"INPUT_ERROR","userError":true}}],"data":null}'
    t_run board issue create --title t
    t_status 4
}

test_invalid_query_on_stderr_is_a_failure() {
    linear_board
    linear_fails IssueView err '{"errors":[{"message":"Cannot query field \"nosuch\" on type \"Issue\".","extensions":{"code":"GRAPHQL_VALIDATION_FAILED"}}]}'
    t_run board issue view 3KD-1
    t_status 1
    t_contains "$T_ERR" 'Cannot query field'
}

test_bad_login_is_exit_5_on_either_stream() {
    linear_board
    linear_fails Viewer err '{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}'
    t_run board auth status
    t_status 5
    rm "$FAKE_OVERRIDE/Viewer.err"
    linear_fails Viewer out '{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}'
    t_run board auth status
    t_status 5
}

test_no_login_at_all_is_exit_5() {
    linear_board
    linear_fails Viewer err 'API request failed: No API key configured
  Set LINEAR_API_KEY, add api_key to .linear.toml, or run `linear auth login`.'
    t_run board auth status
    t_status 5
    t_contains "$T_ERR" 'No API key configured'
}

test_a_refused_input_is_a_failure() {
    linear_board
    linear_fails StateArchive out '{"errors":[{"message":"Active issues","extensions":{"code":"INPUT_ERROR","userError":true,"userPresentableMessage":"The state contains active issues."}}],"data":null}'
    t_run board status delete Backlog --yes
    t_status 1
    t_contains "$T_ERR" 'active issues'
}

test_the_exit_code_of_the_tool_never_passes_through() {
    linear_board
    for linear_t_code in 3 4 5; do
        printf '%s' "$linear_t_code" >"$FAKE_OVERRIDE/Viewer.status"
        : >"$FAKE_OVERRIDE/Viewer.json"
        printf 'something broke\n' >"$FAKE_OVERRIDE/Viewer.err"
        t_run board auth status
        t_status 1
    done
}

test_timeout_of_a_read_is_a_failure() {
    linear_board
    printf 124 >"$FAKE_OVERRIDE/IssueView.status"
    : >"$FAKE_OVERRIDE/IssueView.json"
    t_run board issue view 3KD-1
    t_status 1
    t_contains "$T_ERR" 'timed out'
}

test_timeout_of_a_write_is_partial_with_the_id() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf 124 >"$FAKE_OVERRIDE/IssueUpdate.status"
    : >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
}

test_timeout_of_a_create_is_partial_with_no_id() {
    linear_board
    printf 124 >"$FAKE_OVERRIDE/IssueCreate.status"
    : >"$FAKE_OVERRIDE/IssueCreate.json"
    t_run board issue create --title t
    t_status 6
    t_eq "$T_OUT" '' stdout
    t_run board issue create --help
    t_contains "$T_OUT" 'there is no id yet'
}

test_timeout_after_a_first_write_prints_the_id_once() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    printf 124 >"$FAKE_OVERRIDE/LabelCreate.status"
    : >"$FAKE_OVERRIDE/LabelCreate.json"
    t_run board issue edit 3KD-1 --title new --add-label fresh
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
}

test_a_mutation_that_died_with_no_answer_may_have_gone_through() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    linear_fails IssueUpdate err 'API request failed: fetch failed'
    t_run board issue move 3KD-1 Done
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
    rm "$FAKE_OVERRIDE/IssueUpdate.err"
    linear_fails IssueUpdate out '{"errors":[{"message":"boom","extensions":{"code":"INTERNAL_ERROR"}}],"data":null}'
    t_run board issue move 3KD-1 Done
    t_status 6
    rm "$FAKE_OVERRIDE/IssueUpdate.status"
    : >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done
    t_status 6
}

test_a_read_that_died_is_a_plain_failure() {
    linear_board
    linear_fails IssueView out '{"errors":[{"message":"boom","extensions":{"code":"INTERNAL_ERROR"}}],"data":null}'
    t_run board issue move 3KD-1 Done
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_a_tool_that_never_started_wrote_nothing() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf 127 >"$FAKE_OVERRIDE/IssueUpdate.status"
    : >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done
    t_status 1
}

test_a_refused_mutation_is_a_plain_failure() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    linear_fails IssueUpdate out '{"errors":[{"message":"nope","extensions":{"code":"INVALID_INPUT","userError":true}}],"data":null}'
    t_run board issue move 3KD-1 Done
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_success_false_is_a_failure() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"success":false,"issue":null}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done
    t_status 1
    t_contains "$T_ERR" 'success: false'
    t_eq "$(grep -c '^query IssueView' "$FAKE_LOG.stdin")" 1 reads
    printf '{"data":{"issueDelete":{"success":false}}}' >"$FAKE_OVERRIDE/IssueDelete.json"
    t_run board issue delete 3KD-1 --yes
    t_status 1
}

test_board_api_with_a_mutation_counts_as_a_write() {
    linear_board
    printf 124 >"$FAKE_OVERRIDE/Anything.status"
    : >"$FAKE_OVERRIDE/Anything.json"
    printf 'mutation Anything { issueDelete(id: "x") { success } }' >q.graphql
    t_run board api - <q.graphql
    t_status 6
    printf 'query Anything { viewer { id } }' >q.graphql
    t_run board api - <q.graphql
    t_status 1
    t_run board api 'mutation { issueDelete(id: "x") { success } }' </dev/null
    t_status 6
    t_run board api 'query { viewer { id } }' </dev/null
    t_status 1
}

test_read_timeout_in_a_move_is_a_plain_failure() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf 124 >"$FAKE_OVERRIDE/BoardMeta.status"
    : >"$FAKE_OVERRIDE/BoardMeta.json"
    t_run board issue move 3KD-1 Done
    t_status 1
    t_eq "$T_OUT" '' stdout
}

test_exit_zero_with_nothing_to_read_is_a_failure() {
    linear_board
    : >"$FAKE_OVERRIDE/Viewer.json"
    t_run board auth status
    t_status 1
}

test_an_inherited_ready_flag_changes_nothing() {
    linear_board
    LN_READY=1
    export LN_READY
    t_run board status list --json
    t_status 0
    t_jq "$T_OUT" 'length' 6
}

test_a_trashed_issue_is_not_found() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"trashed":true'
    t_run board issue view 3KD-1
    t_status 4
}

test_a_trashed_issue_takes_no_write() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"trashed":true'
    t_run board issue move 3KD-1 Done
    t_status 4
    t_run board issue delete 3KD-1 --yes
    t_status 4
    t_run board issue comment list 3KD-1
    t_status 4
    t_run board issue comment add 3KD-1 --body x
    t_status 4
    t_run board issue comment edit 3KD-1 c1 --body x
    t_status 4
    t_run board issue comment delete 3KD-1 c1 --yes
    t_status 4
    t_run board issue link add 3KD-1 3KD-2 --type blocks
    t_status 4
    t_run board issue create --title t --parent 3KD-1
    t_status 4
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_trashed_other_side_takes_no_link() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    linear_issue_answer "$linear_backlog" ',"trashed":true'
    t_run board issue link add 3KD-1 3KD-2 --type blocks
    t_status 4
    t_eq "$(linear_mutations)" 0 mutations
}

# --- what travels where -------------------------------------------------------------------

test_a_long_description_stays_out_of_argv() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-1","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    linear_t_chunk=0123456789abcdef0123456789abcdef
    linear_t_i=0
    : >body.txt
    while [ "$linear_t_i" -lt 1100 ]; do
        printf '%s\n' "$linear_t_chunk" >>body.txt
        linear_t_i=$((linear_t_i + 1))
    done
    t_run board issue create --title t --body-file body.txt
    t_status 0
    t_lacks "$(cat "$FAKE_LOG")" "$linear_t_chunk" argv
    t_contains "$(cat "$FAKE_LOG.stdin")" "$linear_t_chunk" stdin
}

test_text_that_looks_like_a_placeholder_stays_text() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-1","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    t_run board issue create --title 'cost $input and %type' --body 'quote " and back\slash
second line'
    t_status 0
    linear_t_sent=$(cat "$FAKE_LOG.stdin")
    t_contains "$linear_t_sent" 'title:"cost $input and %type"'
    t_contains "$linear_t_sent" 'description:"quote \" and back\\slash\nsecond line"'
}

test_an_enum_goes_without_quotes() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"relations":{"nodes":[{"id":"r","type":"duplicate","relatedIssue":{"identifier":"3KD-2"}}]}'
    printf '{"data":{"issueRelationCreate":{"success":true}}}' >"$FAKE_OVERRIDE/RelationCreate.json"
    t_run board issue link add 3KD-1 3KD-2 --type duplicates
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'relatedIssueId: "3KD-2", type: duplicate}'
}

test_blocked_by_turns_the_relation_round() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"inverseRelations":{"nodes":[{"id":"r","type":"blocks","issue":{"identifier":"3KD-2"}}]}'
    printf '{"data":{"issueRelationCreate":{"success":true}}}' >"$FAKE_OVERRIDE/RelationCreate.json"
    t_run board issue link add 3KD-1 3KD-2 --type blocked-by
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'issueId: "3KD-2", relatedIssueId: "3KD-1", type: blocks}'
}

test_the_workspace_of_the_url_is_named() {
    linear_board
    printf '{"data":{"viewer":{"id":"u","name":"N","displayName":"n"}}}' >"$FAKE_OVERRIDE/Viewer.json"
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'linear api --workspace acme -'
}

test_a_workspace_that_could_be_a_flag_is_refused() {
    t_workflow <<'EOF'
[board]
kind    = "linear"
url     = "https://linear.app/--variable"
project = "3KD"
EOF
    t_run board status list
    t_status 2
    [ ! -s "$FAKE_LOG" ] || t_fail "the tool was run: $(cat "$FAKE_LOG")"
    t_run board init --url https://linear.app/--variable/team/3KD
    t_status 2
}

test_an_api_key_goes_without_the_workspace() {
    linear_board
    printf '{"data":{"viewer":{"id":"u","name":"N","displayName":"n"}}}' >"$FAKE_OVERRIDE/Viewer.json"
    LINEAR_API_KEY=x
    export LINEAR_API_KEY
    t_run board auth status
    t_status 0
    t_contains "$(cat "$FAKE_LOG")" 'linear api -'
}

# --- list ---------------------------------------------------------------------------------

linear_empty_list() {
    printf '{"data":{"issues":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}' >"$FAKE_OVERRIDE/IssueList.json"
}

test_default_list_asks_for_the_open_statuses() {
    linear_board
    linear_empty_list
    t_run board issue list
    t_status 0
    t_eq "$T_OUT" ''
    linear_t_sent=$(cat "$FAKE_LOG.stdin")
    t_contains "$linear_t_sent" 'state:{id:{in:["s-back","s-triage","s-prog"]}}'
    t_contains "$linear_t_sent" 'team:{id:{eq:"T"}}'
    t_lacks "$linear_t_sent" 'project:'
    t_contains "$linear_t_sent" 'first: 30'
}

test_statuses_table_overrides_the_filter_too() {
    linear_board
    cat >>"$WORKFLOW_FILE" <<'EOF'

[board.statuses]
"Duplicate" = "done"
EOF
    linear_empty_list
    t_run board issue list --category done
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'state:{id:{in:["s-done","s-dup"]}}'
}

test_list_is_narrowed_to_the_project() {
    linear_narrowed
    linear_empty_list
    t_run board issue list --category all --limit all
    t_status 0
    linear_t_sent=$(cat "$FAKE_LOG.stdin")
    t_contains "$linear_t_sent" 'project:{id:{eq:"P"}}'
    t_lacks "$linear_t_sent" 'state:'
    t_contains "$linear_t_sent" 'first: 100'
}

test_list_filters_become_conditions() {
    linear_board
    linear_empty_list
    t_run board issue list --status 'in progress' --label bug --label ui --priority none --assignee @me --search 'a"b' --parent 3KD-1 -m v1
    t_status 0
    linear_t_sent=$(cat "$FAKE_LOG.stdin")
    t_contains "$linear_t_sent" 'state:{id:{in:["s-prog"]}}'
    t_contains "$linear_t_sent" '{labels:{some:{name:{eqIgnoreCase:"bug"}}}},{labels:{some:{name:{eqIgnoreCase:"ui"}}}}'
    t_contains "$linear_t_sent" 'priority:{eq:0}'
    t_contains "$linear_t_sent" 'assignee:{isMe:{eq:true}}'
    t_lacks "$linear_t_sent" 'query MemberList'
    t_contains "$linear_t_sent" 'title:{containsIgnoreCase:"a\"b"}'
    t_contains "$linear_t_sent" 'parent:{id:{eq:"3KD-1"}}'
    t_contains "$linear_t_sent" 'projectMilestone:{name:{eqIgnoreCase:"v1"}}'
}

test_a_name_the_board_lacks_is_an_empty_list() {
    linear_board
    linear_cycles_on
    t_run board issue list --status nope --json
    t_status 0
    t_eq "$T_OUT" '[]'
    t_run board issue list --sprint nope --json
    t_status 0
    t_eq "$T_OUT" '[]'
    t_lacks "$(cat "$FAKE_LOG.stdin")" 'query IssueList'
}

test_a_failure_while_looking_up_a_name_is_still_a_failure() {
    linear_board
    linear_cycles_on
    linear_fails CycleList out '{"errors":[{"message":"Authentication required, not authenticated","extensions":{"code":"AUTHENTICATION_ERROR"}}]}'
    t_run board issue list --sprint someone
    t_status 5
}

test_someone_outside_the_team_is_filtered_on_the_server() {
    linear_board
    linear_empty_list
    t_run board issue list --assignee 'Left The Team' --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'assignee:{or:[{name:{eqIgnoreCase:"Left The Team"}},{displayName:{eqIgnoreCase:"Left The Team"}}]}'
    t_run board issue list --assignee 07458d66-3183-444e-8e96-feda82db20cb --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'assignee:{id:{eq:"07458d66-3183-444e-8e96-feda82db20cb"}}'
    t_lacks "$(cat "$FAKE_LOG.stdin")" 'query MemberList'
}

test_an_unknown_status_in_a_move_lists_the_real_ones() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    t_run board issue move 3KD-1 nope
    t_status 2
    t_contains "$T_ERR" 'Backlog, Triage, In Progress, Done, Canceled, Duplicate'
}

test_a_cyrillic_status_is_found_in_any_case() {
    linear_board
    cat >"$FAKE_OVERRIDE/BoardMeta.json" <<'EOF'
{"data":{"team":{"id":"T","key":"3KD","name":"Three","cyclesEnabled":false,"states":{"nodes":[
{"id":"s-ru","name":"Готово","type":"completed","position":0}]}}}}
EOF
    linear_issue_answer "$linear_backlog" ''
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    linear_issue_answer '{"id":"s-ru","name":"Готово","type":"completed"}' ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 'ГОТОВО' --jq .status.name
    t_status 0
    t_eq "$T_OUT" 'Готово'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'stateId:"s-ru"'
}

test_type_is_not_a_linear_idea() {
    linear_board
    t_run board issue list --type Bug
    t_status 3
    t_run board issue create --title t --type Bug
    t_status 3
    t_run board issue edit 3KD-1 --type Bug
    t_status 3
}

test_a_list_says_when_an_issue_has_more_labels_than_it_shows() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"labels":{"pageInfo":{"hasNextPage":true},"nodes":[{"name":"a"}]}'
    jq -c '{data: {issues: {pageInfo: {hasNextPage: false, endCursor: null}, nodes: [.data.issue]}}}' \
        <"$FAKE_OVERRIDE/IssueView.json" >"$FAKE_OVERRIDE/IssueList.json"
    t_run board issue list --json
    t_status 0
    t_contains "$T_ERR" 'more than 50 labels'
    linear_issue_answer "$linear_backlog" ''
    jq -c '{data: {issues: {pageInfo: {hasNextPage: true, endCursor: "c"}, nodes: [.data.issue]}}}' \
        <"$FAKE_OVERRIDE/IssueView.json" >"$FAKE_OVERRIDE/IssueList.json"
    t_run board issue list --limit 1 --json
    t_lacks "$T_ERR" 'labels'
}

test_list_warns_when_more_exist() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    jq -c '{data: {issues: {pageInfo: {hasNextPage: true, endCursor: "c"}, nodes: [.data.issue]}}}' \
        <"$FAKE_OVERRIDE/IssueView.json" >"$FAKE_OVERRIDE/IssueList.json"
    t_run board issue list --limit 1 --json
    t_status 0
    t_jq "$T_OUT" 'length' 1
    t_jq "$T_OUT" '.[0].priority' '"none"'
    t_contains "$T_ERR" 'more exist'
}

# --- write --------------------------------------------------------------------------------

test_create_goes_to_the_project_with_every_field_in_one_call() {
    linear_narrowed
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-1","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"l1","name":"Bug","color":"#EB5757","description":null}]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    t_run board issue create --title t --status backlog --label BUG --priority urgent --due 2027-01-15 --parent 3KD-9
    t_status 0
    linear_t_sent=$(cat "$FAKE_LOG.stdin")
    t_contains "$linear_t_sent" 'teamId:"T",projectId:"P",title:"t",priority:1,parentId:"3KD-9",dueDate:"2027-01-15",stateId:"s-back",labelIds:["l1"]'
    t_eq "$(linear_mutations)" 1 mutations
}

test_create_checks_every_name_before_it_writes() {
    linear_board
    linear_member_answer
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    t_run board issue create --title t --status nope
    t_status 2
    t_run board issue create --title t --assignee nobody
    t_status 4
    t_run board issue create --title t --sprint current
    t_status 3
    t_run board issue create --title t --milestone m
    t_status 3
    t_eq "$(linear_mutations)" 0 mutations
}

test_edit_checks_every_name_before_it_writes() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    linear_member_answer
    t_run board issue edit 3KD-1 --title new --status nope
    t_status 2
    t_run board issue edit 3KD-1 --title new --add-assignee nobody
    t_status 4
    t_eq "$(linear_mutations)" 0 mutations
}

test_reopen_with_a_bad_status_writes_nothing() {
    linear_board
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    t_run board issue reopen 3KD-1 --status nope
    t_status 2
    t_eq "$(linear_mutations)" 0 mutations
}

test_an_issue_that_cannot_be_read_after_create_is_partial() {
    linear_board
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-7","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    linear_fails IssueView out '{"errors":[{"message":"boom","extensions":{"code":"INTERNAL_ERROR"}}],"data":null}'
    t_run board issue create --title t
    t_status 6
    t_eq "$T_OUT" 3KD-7 stdout
}

test_every_write_that_cannot_be_read_back_is_partial() {
    linear_board
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    printf '{"data":{"issueRelationCreate":{"success":true}}}' >"$FAKE_OVERRIDE/RelationCreate.json"
    printf '{"data":{"issueRelationDelete":{"success":true}}}' >"$FAKE_OVERRIDE/RelationDelete.json"
    linear_issue_answer "$linear_backlog" ",$linear_linked"
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    printf '{"errors":[{"message":"boom","extensions":{"code":"INTERNAL_ERROR"}}],"data":null}' >"$FAKE_OVERRIDE/IssueView.json"
    t_run board issue link remove 3KD-1 3KD-2 --type blocks
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
}

test_nothing_to_write_needs_no_second_read() {
    linear_board
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    t_run board issue close 3KD-1
    t_status 0
    t_eq "$(grep -c '^query IssueView' "$FAKE_LOG.stdin")" 1 reads
}

test_the_same_label_twice_is_one_label() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-1","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"l1","name":"Bug","color":"#EB5757","description":null}]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    printf '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l2","name":"Новая","color":"#112233","description":null}}}}' >"$FAKE_OVERRIDE/LabelCreate.json"
    t_run board issue create --title t --label 'Новая' --label 'НОВАЯ' --label BUG --label bug
    t_status 0
    t_eq "$(grep -c '^mutation LabelCreate' "$FAKE_LOG.stdin")" 1 'labels made'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'labelIds:["l1"]'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'addedLabelIds:["l2"]'
}

test_a_label_name_over_80_is_refused_before_a_write() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    linear_t_long=$(awk 'BEGIN { for (i = 0; i < 81; i++) printf "я" }')
    t_run board issue create --title t --label "$linear_t_long"
    t_status 2
    t_run board issue edit 3KD-1 --title new --add-label "$linear_t_long"
    t_status 2
    t_run board label create "$linear_t_long"
    t_status 2
    t_run board label edit old --name "$linear_t_long"
    t_status 2
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_label_name_of_80_passes() {
    linear_board
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    printf '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l2","name":"x","color":"#112233","description":null}}}}' >"$FAKE_OVERRIDE/LabelCreate.json"
    linear_t_fits=$(awk 'BEGIN { for (i = 0; i < 80; i++) printf "я" }')
    t_run board label create "$linear_t_fits"
    t_status 0
}

test_a_label_on_a_second_page_can_be_removed() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"labels":{"pageInfo":{"hasNextPage":true,"endCursor":"p1"},"nodes":[{"id":"l1","name":"first"}]}'
    printf '{"data":{"issue":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"l2","name":"second"}]}}}}' >"$FAKE_OVERRIDE/IssueMore.json"
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue edit 3KD-1 --remove-label second
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'removedLabelIds:["l2"]'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'after: "p1"'
    t_contains "$(cat "$FAKE_LOG.stdin")" '@include(if: true)'
}

test_a_relation_and_a_child_on_a_second_page_are_seen() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"relations":{"pageInfo":{"hasNextPage":true,"endCursor":"r1"},"nodes":[]},"children":{"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"identifier":"3KD-8"}]}'
    printf '{"data":{"issue":{"children":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"identifier":"3KD-9"}]},"relations":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"r","type":"blocks","relatedIssue":{"id":"u2","identifier":"3KD-2"}}]}}}}' >"$FAKE_OVERRIDE/IssueMore.json"
    t_run board issue view 3KD-1 --json
    t_status 0
    t_jq "$T_OUT" '.subtasks' '["3KD-8","3KD-9"]'
    t_jq "$T_OUT" '.links' '[{"type":"blocks","id":"3KD-2"}]'
}

test_a_page_that_repeats_ends_the_read() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"labels":{"pageInfo":{"hasNextPage":true,"endCursor":"p1"},"nodes":[]}'
    printf '{"data":{"issue":{"labels":{"pageInfo":{"hasNextPage":true,"endCursor":"p1"},"nodes":[]}}}}' >"$FAKE_OVERRIDE/IssueMore.json"
    t_run board issue view 3KD-1
    t_status 1
    t_contains "$T_ERR" 'same page twice'
}

test_a_label_that_cannot_be_made_after_create_is_partial() {
    linear_board
    printf '{"data":{"issueCreate":{"issue":{"identifier":"3KD-7","updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueCreate.json"
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    linear_fails LabelCreate out '{"errors":[{"message":"bad label","extensions":{"code":"INPUT_ERROR","userError":true}}],"data":null}'
    t_run board issue create --title t --label new
    t_status 6
    t_eq "$T_OUT" 3KD-7 stdout
}

test_an_edit_that_changed_nothing_before_a_label_failed_is_not_partial() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    linear_fails LabelCreate out '{"errors":[{"message":"bad label","extensions":{"code":"INPUT_ERROR","userError":true}}],"data":null}'
    t_run board issue edit 3KD-1 --add-label new
    t_status 1
}

test_a_label_made_before_the_update_failed_is_partial() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    printf '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l2","name":"new","color":"#112233","description":null}}}}' >"$FAKE_OVERRIDE/LabelCreate.json"
    linear_fails IssueUpdate out '{"errors":[{"message":"nope","extensions":{"code":"INPUT_ERROR","userError":true}}],"data":null}'
    t_run board issue edit 3KD-1 --add-label new
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
}

test_an_edit_that_changed_fields_before_a_label_failed_is_partial() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    linear_fails LabelCreate out '{"errors":[{"message":"bad label","extensions":{"code":"INPUT_ERROR","userError":true}}],"data":null}'
    t_run board issue edit 3KD-1 --title new --add-label new
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
}

test_one_assignee_only() {
    linear_board
    t_run board issue create --title t --assignee a --assignee b
    t_status 3
    linear_issue_answer "$linear_backlog" ''
    t_run board issue edit 3KD-1 --add-assignee a --add-assignee b
    t_status 3
}

linear_member_answer() {
    printf '{"data":{"team":{"members":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"u9","name":"Roman Bulgakov","displayName":"rb"}]}}}}' >"$FAKE_OVERRIDE/MemberList.json"
}

test_assignee_is_found_by_either_name() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    linear_member_answer
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue edit 3KD-1 --add-assignee 'roman bulgakov'
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'assigneeId:"u9"'
    t_run board issue edit 3KD-1 --add-assignee RB
    t_status 0
    t_run board issue edit 3KD-1 --add-assignee nobody
    t_status 4
}

test_removing_someone_else_writes_nothing() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"assignee":{"id":"u9","name":"Roman","displayName":"rb"}'
    t_run board issue edit 3KD-1 --remove-assignee other
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

test_removing_the_assignee_sends_null() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"assignee":{"id":"u9","name":"Roman","displayName":"rb"}'
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue edit 3KD-1 --remove-assignee RB
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'assigneeId:null'
}

test_clear_sends_what_each_field_empties_with() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue edit 3KD-1 --clear priority --clear due --clear parent --clear sprint --clear milestone
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" '{priority:0,dueDate:null,parentId:null,cycleId:null,projectMilestoneId:null}'
}

test_closing_a_closed_issue_writes_nothing() {
    linear_board
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    t_run board issue close 3KD-1
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

test_close_as_canceled_finds_the_first_such_status() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue close 3KD-1 --reason canceled
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'stateId:"s-canc"'
}

test_reopen_skips_triage() {
    linear_board
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue reopen 3KD-1
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'stateId:"s-back"'
}

test_reopen_into_the_status_it_has_writes_nothing() {
    linear_board
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    t_run board issue reopen 3KD-1 --status Done
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

test_moving_to_the_status_it_has_writes_nothing() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    t_run board issue move 3KD-1 backlog
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

test_reopening_an_open_issue_writes_nothing() {
    linear_board
    linear_issue_answer '{"id":"s-prog","name":"In Progress","type":"started"}' ''
    t_run board issue reopen 3KD-1
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_duplicate_reads_as_canceled() {
    linear_board
    linear_issue_answer '{"id":"s-dup","name":"Duplicate","type":"duplicate"}' ''
    t_run board issue view 3KD-1 --jq .status.category
    t_status 0
    t_eq "$T_OUT" canceled
}

# --- links --------------------------------------------------------------------------------

linear_linked='"relations":{"nodes":[{"id":"r1","type":"blocks","relatedIssue":{"id":"u2","identifier":"3KD-2"}},{"id":"r5","type":"similar","relatedIssue":{"id":"u5","identifier":"3KD-5"}}]},"inverseRelations":{"nodes":[{"id":"r2","type":"blocks","issue":{"id":"u3","identifier":"3KD-3"}},{"id":"r3","type":"related","issue":{"id":"u4","identifier":"3KD-4"}},{"id":"r4","type":"duplicate","issue":{"id":"u6","identifier":"3KD-6"}}]}'

test_links_read_from_both_sides() {
    linear_board
    linear_issue_answer "$linear_backlog" ",$linear_linked"
    t_run board issue link list 3KD-1 --json
    t_status 0
    t_jq "$T_OUT" 'map("\(.type) \(.id)")' '["blocks 3KD-2","blocked-by 3KD-3","relates 3KD-4","duplicated-by 3KD-6"]'
}

test_link_remove_finds_the_inverse_side() {
    linear_board
    linear_issue_answer "$linear_backlog" ",$linear_linked"
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueRelationDelete":{"success":true}}}' >"$FAKE_OVERRIDE/RelationDelete.json"
    t_run board issue link remove 3KD-1 3kd-3 --type blocked-by
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'issueRelationDelete(id: "r2")'
}

# Linear can show the state from before a write for seconds after it reported success: measured on
# the live board, where 3KD-59 kept a removed label in two reads after the mutation's success.

test_a_read_that_lags_behind_an_update_is_repeated() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    cp "$FAKE_OVERRIDE/IssueView.1.json" "$FAKE_OVERRIDE/IssueView.2.json"
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ',"updatedAt":"2026-11-01T14:03:10.000Z"'
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:03:10.000Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done --jq .status.name
    t_status 0
    t_eq "$T_OUT" Done
    t_eq "$(grep -c '^query IssueView' "$FAKE_LOG.stdin")" 3 reads
}

test_a_failed_read_after_a_write_is_one_more_try() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    printf '{"errors":[{"message":"boom","extensions":{"code":"INTERNAL_ERROR"}}],"data":null}' >"$FAKE_OVERRIDE/IssueView.2.json"
    linear_issue_answer '{"id":"s-done","name":"Done","type":"completed"}' ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 Done --jq .status.name
    t_status 0
    t_eq "$T_OUT" Done
}

test_a_read_that_never_catches_up_ends_at_the_deadline() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:03:10.000Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    linear_t_start=$(date +%s)
    t_run board issue move 3KD-1 Done
    t_status 6
    t_eq "$T_OUT" 3KD-1 stdout
    t_contains "$T_ERR" 'old state'
    [ "$(($(date +%s) - linear_t_start))" -lt 45 ] || t_fail "the wait outlived its deadline"
}

test_a_link_that_is_slow_to_show_is_waited_for() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    cp "$FAKE_OVERRIDE/IssueView.1.json" "$FAKE_OVERRIDE/IssueView.2.json"
    cp "$FAKE_OVERRIDE/IssueView.1.json" "$FAKE_OVERRIDE/IssueView.3.json"
    linear_issue_answer "$linear_backlog" ',"relations":{"nodes":[{"id":"r","type":"blocks","relatedIssue":{"identifier":"3KD-2"}}]}'
    printf '{"data":{"issueRelationCreate":{"success":true}}}' >"$FAKE_OVERRIDE/RelationCreate.json"
    t_run board issue link add 3KD-1 3KD-2 --type blocks --jq '.links[0].id'
    t_status 0
    t_eq "$T_OUT" 3KD-2
}

test_a_removed_link_is_waited_for_too() {
    linear_board
    linear_issue_answer "$linear_backlog" ",$linear_linked"
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    cp "$FAKE_OVERRIDE/IssueView.1.json" "$FAKE_OVERRIDE/IssueView.2.json"
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueRelationDelete":{"success":true}}}' >"$FAKE_OVERRIDE/RelationDelete.json"
    t_run board issue link remove 3KD-1 3KD-2 --type blocks --jq '.links | length'
    t_status 0
    t_eq "$T_OUT" 0
}

test_a_link_is_found_by_the_uuid_of_the_other_side() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"relations":{"nodes":[{"id":"r1","type":"blocks","relatedIssue":{"id":"aaaaaaaa-0000-4000-8000-000000000001","identifier":"3KD-2"}}]}'
    mv "$FAKE_OVERRIDE/IssueView.json" "$FAKE_OVERRIDE/IssueView.1.json"
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueRelationDelete":{"success":true}}}' >"$FAKE_OVERRIDE/RelationDelete.json"
    t_run board issue link remove 3KD-1 aaaaaaaa-0000-4000-8000-000000000001 --type blocks
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'issueRelationDelete(id: "r1")'
}

test_removing_a_link_that_is_not_there_writes_nothing() {
    linear_board
    linear_issue_answer "$linear_backlog" ",$linear_linked"
    t_run board issue link remove 3KD-1 3KD-2 --type relates
    t_status 0
    t_eq "$(linear_mutations)" 0 mutations
}

# --- the rest of the board ----------------------------------------------------------------

test_statuses_come_in_board_order() {
    linear_board
    t_run board status list --json
    t_status 0
    t_jq "$T_OUT" 'map(.name)' '["Backlog","Triage","In Progress","Done","Canceled","Duplicate"]'
    t_jq "$T_OUT" 'map(.category) | unique' '["canceled","done","in_progress","todo"]'
}

# Linear lets two statuses share a name when their types differ.
linear_twins() {
    cat >"$FAKE_OVERRIDE/BoardMeta.json" <<'EOF'
{"data":{"team":{"id":"T","key":"3KD","name":"Three","cyclesEnabled":false,"states":{"nodes":[
{"id":"s-rev-done","name":"Review","type":"completed","position":0},
{"id":"s-back","name":"Backlog","type":"backlog","position":0},
{"id":"s-rev-now","name":"review","type":"started","position":0}]}}}}
EOF
}

test_a_name_two_statuses_share_takes_no_write() {
    linear_board
    linear_twins
    linear_issue_answer "$linear_backlog" ''
    t_run board issue move 3KD-1 review
    t_status 2
    t_contains "$T_ERR" 's-rev-now'
    t_contains "$T_ERR" 's-rev-done'
    t_run board status delete Review --yes
    t_status 2
    t_run board status rename Review Other
    t_status 2
    t_run board issue edit 3KD-1 --status Review
    t_status 2
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_name_two_statuses_share_is_reached_by_id() {
    linear_board
    linear_twins
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue move 3KD-1 s-rev-done
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'stateId:"s-rev-done"'
}

test_a_shared_name_filters_on_all_of_them_in_board_order() {
    linear_board
    linear_twins
    linear_empty_list
    t_run board issue list --status REVIEW --json
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'state:{id:{in:["s-rev-now","s-rev-done"]}}'
}

test_a_shared_name_resolves_in_board_order() {
    linear_board
    linear_twins
    t_run board status add Review --category done --json
    t_status 0
    t_jq "$T_OUT" '.id' '"s-rev-now"'
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_rename_onto_a_taken_name_writes_nothing() {
    linear_board
    t_run board status rename Backlog 'in progress'
    t_status 2
    t_contains "$T_ERR" 'exists already'
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_rename_may_change_only_the_case() {
    linear_board
    printf '{"data":{"workflowStateUpdate":{"workflowState":{"id":"s-back","name":"BACKLOG","type":"backlog"}}}}' >"$FAKE_OVERRIDE/StateUpdate.json"
    t_run board status rename Backlog BACKLOG --json
    t_status 0
    t_jq "$T_OUT" '.name' '"BACKLOG"'
}

test_status_add_maps_the_category_to_a_type() {
    linear_board
    printf '{"data":{"workflowStateCreate":{"workflowState":{"id":"n","name":"Review","type":"started"}}}}' >"$FAKE_OVERRIDE/StateCreate.json"
    t_run board status add Review --category in_progress --json
    t_status 0
    t_jq "$T_OUT" '.category' '"in_progress"'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'teamId:"T",name:"Review",type:"started",color:"#f2c94c"'
}

test_status_add_of_one_that_exists_writes_nothing() {
    linear_board
    t_run board status add BACKLOG --category todo --json
    t_status 0
    t_jq "$T_OUT" '.name' '"Backlog"'
    t_eq "$(linear_mutations)" 0 mutations
}

test_label_color_loses_and_gains_its_hash() {
    linear_board
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"l1","name":"Bug","color":"#EB5757","description":null}]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    printf '{"data":{"issueLabelCreate":{"issueLabel":{"id":"l2","name":"new","color":"#112233","description":null}}}}' >"$FAKE_OVERRIDE/LabelCreate.json"
    t_run board label list --json
    t_jq "$T_OUT" '.[0].color' '"EB5757"'
    t_run board label create new --color 112233 --json
    t_status 0
    t_jq "$T_OUT" '.color' '"112233"'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'color:"#112233"'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'teamId:"T"'
}

test_label_create_of_one_that_exists_writes_nothing() {
    linear_board
    printf '{"data":{"team":{"labels":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[{"id":"l1","name":"Bug","color":"#EB5757","description":null}]}}}}' >"$FAKE_OVERRIDE/LabelList.json"
    t_run board label create bug --json
    t_status 0
    t_jq "$T_OUT" '.name' '"Bug"'
    t_eq "$(linear_mutations)" 0 mutations
}

test_comments_of_integrations_are_left_out_and_the_rest_sorted() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    cat >"$FAKE_OVERRIDE/CommentList.json" <<'EOF'
{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"id":"c2","body":"new","url":"u","createdAt":"2026-11-02T00:00:00.000Z","updatedAt":"2026-11-02T00:00:00.000Z","user":{"id":"u1","name":"A","displayName":"a"},"externalUser":null},
{"id":"c9","body":"bot","url":"u","createdAt":"2026-11-02T00:00:00.000Z","updatedAt":"2026-11-02T00:00:00.000Z","user":null,"externalUser":null},
{"id":"c1","body":"old","url":"u","createdAt":"2026-11-01T00:00:00.000Z","updatedAt":"2026-11-01T00:00:00.000Z","user":null,"externalUser":{"id":"x1","name":"Customer"}}]}}}}
EOF
    t_run board issue comment list 3KD-1 --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["c1","c2"]'
    t_jq "$T_OUT" '.[0].author.name' '"Customer"'
}

test_comments_of_one_second_keep_their_order() {
    linear_board
    linear_issue_answer "$linear_backlog" ''
    cat >"$FAKE_OVERRIDE/CommentList.json" <<'EOF'
{"data":{"issue":{"comments":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"id":"late","body":"b","url":"u","createdAt":"2026-11-01T10:00:00.900Z","updatedAt":"2026-11-01T10:00:00.900Z","user":{"id":"u1","name":"A","displayName":"a"},"externalUser":null},
{"id":"early","body":"a","url":"u","createdAt":"2026-11-01T10:00:00.100Z","updatedAt":"2026-11-01T10:00:00.100Z","user":{"id":"u1","name":"A","displayName":"a"},"externalUser":null}]}}}}
EOF
    t_run board issue comment list 3KD-1 --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["early","late"]'
}

linear_comment_answers() {
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"commentUpdate":{"comment":{"id":"c1","body":"new","url":"u","createdAt":"2026-11-01T10:00:00.100Z","updatedAt":"2026-11-01T10:00:00.100Z","user":{"id":"u1","name":"A","displayName":"a"},"externalUser":null}}}}' >"$FAKE_OVERRIDE/CommentUpdate.json"
    printf '{"data":{"commentDelete":{"success":true}}}' >"$FAKE_OVERRIDE/CommentDelete.json"
}

test_a_comment_on_another_issue_is_not_found() {
    linear_board
    linear_comment_answers
    printf '{"data":{"comment":{"issue":{"id":"other"}}}}' >"$FAKE_OVERRIDE/CommentIssue.json"
    t_run board issue comment edit 3KD-1 c1 --body new
    t_status 4
    t_run board issue comment delete 3KD-1 c1 --yes
    t_status 4
    t_eq "$(linear_mutations)" 0 mutations
}

test_a_comment_on_nothing_is_not_found() {
    linear_board
    linear_comment_answers
    printf '{"data":{"comment":{"issue":null}}}' >"$FAKE_OVERRIDE/CommentIssue.json"
    t_run board issue comment delete 3KD-1 c1 --yes
    t_status 4
}

test_a_comment_on_this_issue_is_written() {
    linear_board
    linear_comment_answers
    printf '{"data":{"comment":{"issue":{"id":"u1"}}}}' >"$FAKE_OVERRIDE/CommentIssue.json"
    t_run board issue comment edit 3KD-1 c1 --body new --json
    t_status 0
    t_jq "$T_OUT" '.body' '"new"'
    t_run board issue comment delete 3KD-1 c1 --yes
    t_status 0
}

test_the_help_says_an_issue_outside_the_project_is_reachable() {
    t_run board issue list --help
    t_contains "$T_OUT" 'stays reachable by id'
    t_run board issue view --help
    t_contains "$T_OUT" 'also outside [board.target] project'
}

test_a_project_name_says_which_setting_is_wrong() {
    t_workflow <<'EOF'
[board]
kind    = "linear"
url     = "https://linear.app/acme"
project = "3KD"

[board.target]
project = "Test"
EOF
    linear_answers
    linear_fails BoardMeta out '{"errors":[{"message":"Entity not found: Project","path":["project"],"extensions":{"code":"INPUT_ERROR","userError":true,"userPresentableMessage":"Could not find referenced Project."}}],"data":null}'
    t_run board status list
    t_status 4
    t_contains "$T_ERR" "project 'Test' was not found"
    t_contains "$T_ERR" '[board.target] project wants the slug'
}

test_a_wrong_team_says_which_setting_is_wrong() {
    linear_board
    linear_fails BoardMeta out '{"errors":[{"message":"Entity not found: Team","path":["team"],"extensions":{"code":"INPUT_ERROR","userError":true,"userPresentableMessage":"Could not find referenced Team."}}],"data":null}'
    t_run board status list
    t_status 4
    t_contains "$T_ERR" '[board] project wants the team key'
}

test_milestones_need_a_project() {
    linear_board
    t_run board milestone list
    t_status 3
    t_run board milestone create --name m
    t_status 3
    linear_issue_answer "$linear_backlog" ''
    t_run board issue edit 3KD-1 --milestone m
    t_status 3
}

test_milestone_state_comes_from_its_status() {
    linear_narrowed
    cat >"$FAKE_OVERRIDE/MilestoneList.json" <<'EOF'
{"data":{"project":{"projectMilestones":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"id":"m1","name":"Open","description":null,"status":"next","targetDate":"2027-02-01"},
{"id":"m2","name":"Shut","description":null,"status":"done","targetDate":null}]}}}}
EOF
    t_run board milestone list --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["m1"]'
    t_run board milestone list --state closed --json
    t_jq "$T_OUT" 'map(.id)' '["m2"]'
    t_run board milestone list --state all --json
    t_jq "$T_OUT" '.[0].due_date' '"2027-02-01"'
}

test_milestone_state_cannot_be_set() {
    linear_narrowed
    t_run board milestone edit m1 --state closed
    t_status 3
}

test_cycles_off_is_exit_3() {
    linear_board
    t_run board sprint list
    t_status 3
    t_run board sprint current
    t_status 3
    t_run board sprint view 1
    t_status 3
    t_run board issue list --sprint current
    t_status 3
    t_run board issue create --title t --sprint current
    t_status 3
    t_eq "$(linear_mutations)" 0 mutations
}

linear_cycles_on() {
    linear_meta_answer true ''
    cat >"$FAKE_OVERRIDE/CycleList.json" <<'EOF'
{"data":{"team":{"cycles":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"id":"cy1","number":1,"name":null,"startsAt":"2026-10-01T00:00:00.000Z","endsAt":"2026-10-15T00:00:00.000Z","isActive":false,"isFuture":false},
{"id":"cy3","number":3,"name":"Launch","startsAt":"2026-11-15T00:00:00.000Z","endsAt":"2026-11-29T00:00:00.000Z","isActive":false,"isFuture":true},
{"id":"cy2","number":2,"name":null,"startsAt":"2026-11-01T00:00:00.000Z","endsAt":"2026-11-15T00:00:00.000Z","isActive":true,"isFuture":false}]}}}}
EOF
}

test_cycles_become_sprints_newest_first() {
    linear_board
    linear_cycles_on
    t_run board sprint list --json
    t_status 0
    t_jq "$T_OUT" 'map(.id)' '["3","2","1"]'
    t_jq "$T_OUT" 'map(.state)' '["future","active","closed"]'
    t_jq "$T_OUT" '.[1].name' '"Cycle 2"'
    t_jq "$T_OUT" '.[0].start_date' '"2026-11-15"'
    t_run board sprint current --jq .id
    t_status 0
    t_eq "$T_OUT" 2
    t_run board sprint view 1 --jq .state
    t_eq "$T_OUT" closed
    t_run board sprint view 9
    t_status 4
}

test_sprint_list_says_when_the_limit_cuts_it() {
    linear_board
    linear_cycles_on
    t_run board sprint list --limit 1 --json
    t_status 0
    t_jq "$T_OUT" 'length' 1
    t_contains "$T_ERR" 'more exist'
    t_run board sprint list --limit 3 --json
    t_lacks "$T_ERR" 'more exist'
}

test_a_sprint_is_found_by_name_number_or_current() {
    linear_board
    linear_cycles_on
    linear_issue_answer "$linear_backlog" ''
    printf '{"data":{"issueUpdate":{"issue":{"updatedAt":"2026-11-01T14:02:59.396Z"}}}}' >"$FAKE_OVERRIDE/IssueUpdate.json"
    t_run board issue edit 3KD-1 --sprint launch
    t_status 0
    t_contains "$(cat "$FAKE_LOG.stdin")" 'cycleId:"cy3"'
    t_run board issue edit 3KD-1 --sprint 1
    t_contains "$(cat "$FAKE_LOG.stdin")" 'cycleId:"cy1"'
    t_run board issue edit 3KD-1 --sprint current
    t_contains "$(cat "$FAKE_LOG.stdin")" 'cycleId:"cy2"'
    t_run board issue edit 3KD-1 --sprint 'cycle 2'
    t_status 0
    t_run board issue edit 3KD-1 --sprint nope
    t_status 4
}

test_a_nameless_cycle_shows_its_number_on_an_issue() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"cycle":{"number":12,"name":null}'
    t_run board issue view 3KD-1 --jq .sprint
    t_status 0
    t_eq "$T_OUT" 'Cycle 12'
}

test_view_without_a_project_links_to_the_team() {
    linear_board
    t_run board view --json
    t_status 0
    t_jq "$T_OUT" '.url' '"https://linear.app/acme/team/3KD"'
    t_jq "$T_OUT" '.columns[0]' '{"name":"Backlog","statuses":["Backlog"]}'
}

test_no_team_key_is_wrong_usage() {
    t_workflow <<'EOF'
[board]
kind = "linear"
url  = "https://linear.app/acme"
EOF
    t_run board status list
    t_status 2
    t_contains "$T_ERR" 'team key'
}

# --- init ---------------------------------------------------------------------------------

linear_init_answers() {
    linear_answers
    printf '{"data":{"project":{"slugId":"982b67e1e776","teams":{"nodes":[{"key":"3KD"}]}}}}' >"$FAKE_OVERRIDE/ProjectTeams.json"
    WORKFLOW_FILE=$T_TMP/new.toml
    export WORKFLOW_FILE
}

test_init_from_a_project_url_narrows_the_board() {
    linear_init_answers
    t_run board init --url https://linear.app/3kd/project/some-long-name-982b67e1e776/overview --dry-run
    t_status 0
    t_contains "$T_OUT" 'url = "https://linear.app/3kd"'
    t_contains "$T_OUT" 'project = "3KD"'
    t_contains "$T_OUT" 'issue_uri = "/issue/{ticket}"'
    t_contains "$T_OUT" '[board.target]'
    t_contains "$T_OUT" 'project = "982b67e1e776"'
    t_contains "$T_OUT" '"In Progress" = "in_progress"'
    t_contains "$T_OUT" 'Duplicate = "canceled"'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'project(id: "982b67e1e776")'
    t_contains "$(cat "$FAKE_LOG")" '--workspace 3kd'
}

test_init_from_a_team_url_is_the_whole_team() {
    linear_init_answers
    t_run board init --url 'https://linear.app/3kd/team/3KD/active?x=1'
    t_status 0
    t_lacks "$(cat "$T_TMP/new.toml")" '[board.target]'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'team(id: "3KD")'
    t_contains "$(cat "$T_TMP/new.toml")" 'Backlog = "todo"'
}

test_init_written_file_reads_back() {
    linear_init_answers
    t_run board init --url https://linear.app/3kd/project/test-982b67e1e776/overview
    t_status 0
    t_run board config get target.project
    t_eq "$T_OUT" 982b67e1e776
    t_run board status list --jq '.[0].name'
    t_status 0
}

test_init_refuses_a_url_that_is_no_board() {
    linear_init_answers
    t_run board init --url https://linear.app/3kd/settings
    t_status 2
    t_run board init --url https://linear.app/3kd
    t_status 2
}

test_init_refuses_to_guess_a_team() {
    linear_init_answers
    printf '{"data":{"project":{"slugId":"a","teams":{"nodes":[{"key":"X"},{"key":"Y"}]}}}}' >"$FAKE_OVERRIDE/ProjectTeams.json"
    t_run board init --url https://linear.app/3kd/project/p-a
    t_status 2
    t_contains "$T_ERR" 'several teams'
}

# --- history -----------------------------------------------------------------------------

test_history_keeps_state_changes_from_every_page() {
    linear_board
    linear_issue_answer '{"id":"s-prog","name":"In Progress","type":"started"}' ''
    cat >"$FAKE_OVERRIDE/IssueHistory.1.json" <<'EOF2'
{"data":{"issue":{"history":{"pageInfo":{"hasNextPage":true,"endCursor":"h1"},"nodes":[
{"createdAt":"2026-11-03T00:00:00.000Z","fromState":{"id":"s-back","name":"Backlog","type":"backlog"},"toState":{"id":"s-prog","name":"In Progress","type":"started"},"actor":{"id":"u","name":"U"}},
{"createdAt":"2026-11-02T12:00:00.000Z","fromState":null,"toState":null,"actor":{"id":"u","name":"U"}}]}}}}
EOF2
    cat >"$FAKE_OVERRIDE/IssueHistory.2.json" <<'EOF2'
{"data":{"issue":{"history":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[
{"createdAt":"2026-11-02T00:00:00.000Z","fromState":{"id":"s-prog","name":"In Progress","type":"started"},"toState":{"id":"s-back","name":"Backlog","type":"backlog"},"actor":null}]}}}}
EOF2
    t_run board issue history 3KD-1 --json
    t_status 0
    t_jq "$T_OUT" '.moves | map(.to.name)' '["Backlog","In Progress"]'
    t_jq "$T_OUT" '.moves[0].by' null
    t_jq "$T_OUT" '.moves[1].from' '{"name":"Backlog","category":"todo"}'
    t_jq "$T_OUT" '.since' '"2026-11-03T00:00:00Z"'
    t_contains "$(cat "$FAKE_LOG.stdin")" 'after: "h1"'
}

test_history_of_a_trashed_issue_is_not_found() {
    linear_board
    linear_issue_answer "$linear_backlog" ',"trashed":true'
    t_run board issue history 3KD-1
    t_status 4
}

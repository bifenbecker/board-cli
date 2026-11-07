# shellcheck shell=sh

# The common model itself, with no adapter in between.

model_jq() {
    t_jq_cmd -L "$BOARD_TEST_ROOT/lib" "$@"
}

test_sparse_input_still_gives_every_key() {
    got=$(model_jq -nc --slurpfile spec "$BOARD_TEST_ROOT/lib/schema/issue.json" '
        include "jq/common"; include "jq/schema";
        {id: 1, kind: "github"} | make_issue({}) | [schema_problems($spec[0])]')
    t_eq "$got" '[]' problems
}

test_full_input_passes_the_schema() {
    got=$(model_jq -nc --slurpfile spec "$BOARD_TEST_ROOT/lib/schema/issue.json" '
        include "jq/common"; include "jq/schema";
        {id: "KAN-1", kind: "jira", url: "u", title: "t", description: "d", type: "Task",
         status: {name: "To Do", native: "todo"}, assignees: [{id: "a", name: "A"}], labels: ["x"],
         priority: "high", parent: "KAN-0", subtasks: ["KAN-2"], links: [{type: "blocks", id: "KAN-3"}],
         sprint: "s", milestone: "m", due_date: "2026-12-01", author: {id: 7, name: "B"},
         created_at: "2026-11-02T01:04:07.800+1100", updated_at: "2026-11-01T14:02:59.396Z"}
        | make_issue({}) | [schema_problems($spec[0])]')
    t_eq "$got" '[]' problems
}

test_schema_reports_a_bad_object() {
    got=$(model_jq -nc --slurpfile spec "$BOARD_TEST_ROOT/lib/schema/member.json" '
        include "jq/schema"; {id: 5, extra: 1} | [schema_problems($spec[0])] | length')
    t_eq "$got" 3 problems
}

test_utc_normalises_every_format() {
    t_jq_lib() { model_jq -nr "include \"jq/common\"; \"$1\" | utc"; }
    t_eq "$(t_jq_lib 2026-11-02T01:04:07.800+1100)" 2026-11-01T14:04:07Z offset
    t_eq "$(t_jq_lib 2026-11-01T14:02:59.396Z)" 2026-11-01T14:02:59Z millis
    t_eq "$(t_jq_lib 2026-11-01T14:02:59Z)" 2026-11-01T14:02:59Z plain
    t_eq "$(t_jq_lib 2026-11-01T14:02:59-05:30)" 2026-11-01T19:32:59Z colon
}

test_category_declaration_wins_over_the_board() {
    got=$(model_jq -nc 'include "jq/common";
        {name: "won'"'"'t do", native: "done"}
        | make_status({statuses: {"Won'"'"'t Do": "canceled"}}) | .category')
    t_eq "$got" '"canceled"' category
}

test_category_is_never_guessed() {
    got=$(model_jq -nc 'include "jq/common"; {name: "Готово"} | make_status({}) | .category')
    t_eq "$got" null category
}

test_name_comparison_ignores_cyrillic_case() {
    got=$(model_jq -nc 'include "jq/common"; "ГОТОВО" | ieq("готово")')
    t_eq "$got" true ieq
}

test_name_comparison_treats_regex_as_text() {
    got=$(model_jq -nc 'include "jq/common"; "a.c" | ieq("a(") ')
    t_eq "$got" false ieq
}

# --- history -----------------------------------------------------------------------------

# Usage: model_history <make_history input as jq>
model_history() {
    model_jq -nc "include \"jq/common\"; $1 | make_history({statuses: {Review: \"in_progress\"}})"
}

MODEL_ISSUE='{id: "1", status: {name: "Review", category: "in_progress"}, created_at: "2026-11-01T00:00:00Z"}'

test_history_since_is_the_last_move_into_the_status() {
    got=$(model_history "{issue: $MODEL_ISSUE, moves: [
        {from: {name: \"Todo\", native: \"todo\"}, to: {name: \"review\"}, at: \"2026-11-03T10:00:00.5+0100\", by: {id: 7, name: \"A\"}},
        {from: null, to: {name: \"Todo\", native: \"todo\"}, at: \"2026-11-02T00:00:00Z\", by: null}]}")
    t_jq "$got" .since '"2026-11-03T09:00:00Z"'
    t_jq "$got" '.moves | map(.at)' '["2026-11-02T00:00:00Z","2026-11-03T09:00:00Z"]'
    t_jq "$got" '.moves[1].to' '{"name":"review","category":"in_progress"}'
    t_jq "$got" '.moves[1].by' '{"id":"7","name":"A"}'
    t_jq "$got" '.moves[0].from' null
}

test_history_since_is_created_when_nothing_moved() {
    t_jq "$(model_history "{issue: $MODEL_ISSUE, moves: []}")" .since '"2026-11-01T00:00:00Z"'
    t_jq "$(model_history "{issue: $MODEL_ISSUE, moves: [], since: \"2026-11-05T00:00:00Z\"}")" .since '"2026-11-05T00:00:00Z"'
}

test_history_since_is_null_when_the_moves_end_elsewhere() {
    got=$(model_history "{issue: $MODEL_ISSUE, moves: [{from: null, to: {name: \"Old name\"}, at: \"2026-11-02T00:00:00Z\"}]}")
    t_jq "$got" .since null
}

test_history_with_no_status_name_matches_on_category() {
    got=$(model_history '{issue: {id: "1", status: {name: null, category: "todo"}}, moves: [
        {from: {name: "x"}, to: {name: null, native: "todo"}, at: "2026-11-02T00:00:00Z"}]}')
    t_jq "$got" .since '"2026-11-02T00:00:00Z"'
}

test_history_by_without_an_id_is_null() {
    got=$(model_history "{issue: $MODEL_ISSUE, moves: [{from: null, to: {name: \"Review\"}, at: null, by: {id: null, name: \"bot\"}}]}")
    t_jq "$got" '.moves[0].by' null
}

test_history_passes_the_schema() {
    got=$(model_jq -nc --slurpfile h "$BOARD_TEST_ROOT/lib/schema/history.json" \
        --slurpfile m "$BOARD_TEST_ROOT/lib/schema/move.json" "
        include \"jq/common\"; include \"jq/schema\";
        {issue: $MODEL_ISSUE, moves: [{from: {name: \"Todo\"}, to: {name: \"Review\"}, at: \"2026-11-02T00:00:00Z\", by: {id: 1, name: \"A\"}}]}
        | make_history({}) | [schema_problems(\$h[0]), (.moves[] | schema_problems(\$m[0]))]")
    t_eq "$got" '[]' problems
}

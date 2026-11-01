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

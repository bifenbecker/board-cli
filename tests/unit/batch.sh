# shellcheck shell=sh

# board batch against the fake glab. 'status list' reads only the declaration, and 'label create'
# needs two answers, so these two stand for a read and a write.

batch_board() {
    BOARD_TRUSTED_HOSTS=gitlab.example.com
    export BOARD_TRUSTED_HOSTS
    t_workflow <<'EOF'
[board]
kind = "gitlab"
cli  = "glab"
url  = "https://gitlab.example.com/a/b"

[board.statuses]
"todo" = "todo"
"done" = "done"
EOF
    FAKE_OVERRIDE=$T_TMP/answers
    export FAKE_OVERRIDE
    mkdir -p "$FAKE_OVERRIDE"
    printf '{"id":5,"username":"me","name":"Me"}' >"$FAKE_OVERRIDE/GET_user.json"
    printf '[]' >"$FAKE_OVERRIDE/GET_projects_a_2Fb_labels.json"
    printf '{"id":1,"name":"a","color":"#6699cc"}' >"$FAKE_OVERRIDE/POST_projects_a_2Fb_labels.json"
    printf '{"message":"404 Not found"}' >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues_9.json"
    printf 'glab: 404 Not Found (HTTP 404)\n' >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues_9.err"
    printf 1 >"$FAKE_OVERRIDE/GET_projects_a_2Fb_issues_9.status"
}

# Usage: batch_in <line>...  — writes the lines to stdin of the next batch.
batch_in() {
    printf '%s\n' "$@" >"$T_TMP/in"
}

batch() {
    t_run board batch "$@" <"$T_TMP/in"
}

test_batch_prints_one_entry_per_line() {
    batch_board
    batch_in '["status","list"]' '' '["label","create","a"]'
    batch --json
    t_status 0
    t_jq "$T_OUT" 'map(.exit)' '[0,0]'
    t_jq "$T_OUT" '.[0].args' '["status","list"]'
    t_jq "$T_OUT" '.[0].result | map(.name)' '["todo","done"]'
    t_jq "$T_OUT" '.[1].result.name' '"a"'
    t_jq "$T_OUT" '.[1].error' null
}

test_batch_stops_at_the_first_failure() {
    batch_board
    batch_in '["issue","view","9"]' '["status","list"]'
    batch --json
    t_status 4
    t_jq "$T_OUT" 'map(.exit)' '[4,null]'
    t_jq "$T_OUT" '.[0].error | test("404")' true
    t_jq "$T_OUT" '.[1].result' null
}

test_batch_keep_going_runs_the_rest() {
    batch_board
    batch_in '["issue","view","9"]' '["status","list"]'
    batch --keep-going --json
    t_status 4
    t_jq "$T_OUT" 'map(.exit)' '[4,0]'
}

test_batch_failure_after_a_write_is_partial() {
    batch_board
    batch_in '["label","create","a"]' '["issue","view","9"]' '["status","list"]'
    batch --json
    t_status 6
    t_jq "$T_OUT" 'map(.exit)' '[0,4,null]'
}

test_batch_checks_every_line_before_running() {
    batch_board
    batch_in '["label","create","a"]' '["status","list"]' 'issue view 1'
    batch
    t_status 2
    t_contains "$T_ERR" 'line 3: not a JSON array of words'
    [ ! -s "$FAKE_LOG" ] || t_fail "a line ran: $(cat "$FAKE_LOG")"
}

test_batch_refuses_an_unknown_command_and_its_own_kind() {
    batch_board
    batch_in '["nope"]'
    batch
    t_status 2
    t_contains "$T_ERR" "line 1: unknown command 'nope'"
    for batch_word in batch init api self; do
        batch_in '["status","list"]' "[\"$batch_word\"]"
        batch
        t_status 2
        t_contains "$T_ERR" "line 2: board $batch_word cannot run inside a batch"
    done
    [ ! -s "$FAKE_LOG" ] || t_fail "a line ran: $(cat "$FAKE_LOG")"
}

test_batch_passes_dry_run_to_every_line() {
    batch_board
    batch_in '["label","create","a"]'
    batch --dry-run --json
    t_status 0
    t_jq "$T_OUT" '.[0].result.dry_run' true
    t_lacks "$(cat "$FAKE_LOG" 2>/dev/null)" POST
}

test_batch_line_after_double_dash_still_gets_json() {
    batch_board
    batch_in '["status","list","--"]'
    batch --json
    t_jq "$T_OUT" '.[0].exit' 0
    t_jq "$T_OUT" '.[0].result | type' '"array"'
}

test_batch_body_file_dash_is_refused() {
    batch_board
    batch_in '["issue","comment","add","1","--body-file","-"]'
    batch --json
    t_status 2
    t_jq "$T_OUT" '.[0].error | test("cannot read stdin inside board batch")' true
}

test_batch_text_is_one_line_per_command() {
    batch_board
    batch_in '["label","create","a"]' '["issue","view","9"]' '["status","list"]'
    batch
    t_status 6
    t_eq "$(printf '%s\n' "$T_OUT" | sed -n 1p)" "$(printf '0\tlabel create a\t1')" 'first line'
    t_contains "$T_OUT" "$(printf '4\tissue view 9\tboard: 404')"
    t_contains "$T_OUT" "$(printf -- '-\tstatus list\tnot run')"
}

test_batch_with_no_lines_is_an_empty_array() {
    batch_board
    batch_in ''
    batch --json
    t_status 0
    t_jq "$T_OUT" . '[]'
}

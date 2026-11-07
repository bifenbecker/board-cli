# shellcheck shell=sh

help_batch() {
    cat <<'EOF'
NAME
  board batch - run several commands from stdin, one result each

USAGE
  board batch [--keep-going] < lines

DESCRIPTION
  Reads one command per line from stdin, as a JSON array of its words without "board":
  ["issue","move","KAN-1","Done","--from","To Do"]. There is no shell quoting: each string is one
  argument. Blank lines are skipped. Every line is checked before any runs: a line that is not
  such an array, names no command, or names batch, init, api or self is exit 2, and nothing runs.
  Lines then run in order, each as 'board --json <words>' would, and the first failure stops the
  rest. --dry-run passes to every line.
  A line cannot read stdin: --body-file - is exit 2. Put long text in a file.

FLAGS
  -k, --keep-going   Run every line, whatever fails

OUTPUT
  Text: one line per command, tab-separated: exit code (- when not run), the command, then the
        URL, id or name it gave, or the first line of its error.
  JSON: array of {args[], exit, result, error}, one per line in order, printed whatever the exit.
  result is what the command prints with --json: for exit 6 the id as a string, null when it
  prints nothing. error is its stderr when it failed, else null. exit is null for a line that did
  not run.
  Exit: 0 when every line succeeded. 6 when a line that changes the board succeeded and another
  failed, or when a line itself was 6: some changes are made, so do not repeat the batch; read
  the array and go on from the first failure. Otherwise the exit code of the first failure.

EXAMPLES
  printf '%s\n' '["issue","move","KAN-1","Done"]' '["issue","close","KAN-2"]' | board batch
  board batch --dry-run --json < moves.jsonl
  board batch --keep-going --jq 'map(select(.exit != 0))' < lines
EOF
}

# Usage: batch_set_args <line JSON>  — prints a 'set --' of its words, for eval.
batch_set_args() {
    printf '%s' "$1" | _jq -r '"set -- " + (.args | map(@sh) | join(" "))'
}

# Prints true when the command of a line changes the board, false when it does not. Dies when it
# names no command, or one a batch cannot run. The command is resolved in a subshell, so this
# batch keeps its own BOARD_PATH.
# Usage: batch_line_writes <line JSON> <line number>
batch_line_writes() {
    batch_lw_n=$2
    eval "$(batch_set_args "$1")"
    case $1 in
        batch | init | api | self) board_usage_die "line $batch_lw_n: board $1 cannot run inside a batch" ;;
    esac
    (
        board_resolve "$@" >/dev/null 2>&1 || exit 1
        board_fn_exists "cmd_$board_node" || exit 1
        if board_path_writes; then printf 'true'; else printf 'false'; fi
    ) || board_usage_die "line $batch_lw_n: unknown command '$*'"
}

# Checks every line before any runs, and writes the ones to run to $BOARD_TMP/batch.todo, each
# with whether it changes the board.
batch_check() {
    : >"$BOARD_TMP/batch.todo"
    while IFS= read -r batch_ck_line; do
        batch_ck_n=$(printf '%s' "$batch_ck_line" | _jq -r .n)
        if printf '%s' "$batch_ck_line" | _jq -e '.bad' >/dev/null; then
            board_usage_die "line $batch_ck_n: not a JSON array of words, such as [\"issue\",\"view\",\"1\"]"
        fi
        batch_ck_writes=$(batch_line_writes "$batch_ck_line" "$batch_ck_n") || exit $?
        printf '%s' "$batch_ck_line" | _jq -c --argjson w "$batch_ck_writes" '. + {writes: $w}' >>"$BOARD_TMP/batch.todo"
    done <"$BOARD_TMP/batch.lines"
}

# Runs one line as its own board, so nothing one line loaded or cached reaches the next.
# Appends its entry to $BOARD_TMP/batch.done. Sets batch_rn_status.
batch_run() {
    batch_rn_line=$1 batch_rn_n=$2
    eval "$(batch_set_args "$batch_rn_line")"
    batch_rn_status=0
    BOARD_NO_STDIN=1 sh "$BOARD_HOME/bin/board" --json ${BOARD_DRY_RUN:+--dry-run} "$@" </dev/null \
        >"$BOARD_TMP/batch.stdout" 2>"$BOARD_TMP/batch.stderr" || batch_rn_status=$?
    if [ "$batch_rn_status" = 0 ]; then
        sed "s/^board: /board: line $batch_rn_n: /" "$BOARD_TMP/batch.stderr" >&2
    fi
    _jq -Rsc --argjson line "$batch_rn_line" --argjson exit "$batch_rn_status" --arg err "$(cat "$BOARD_TMP/batch.stderr")" '
        rtrimstr("\n") as $out
        | {args: $line.args, exit: $exit,
           result: (if $out == "" then null
                    elif $exit == 6 and ($out | test("^[\\[{]") | not) then $out
                    else ($out | try fromjson catch $out) end),
           error: (if $exit == 0 or $err == "" then null else $err end)}' \
        <"$BOARD_TMP/batch.stdout" >>"$BOARD_TMP/batch.done"
}

cmd_batch() {
    batch_keep=''
    while [ $# -gt 0 ]; do
        case $1 in
            -k | --keep-going) batch_keep=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    _jq -nRc '[inputs] | to_entries[] | select(.value | test("\\S"))
        | (.value | try fromjson catch null) as $a
        | if ($a | type) == "array" and ($a | length) > 0 and all($a[]; type == "string")
             and ($a[0] | startswith("-") | not)
          then {n: (.key + 1), args: $a} else {n: (.key + 1), bad: true} end' \
        >"$BOARD_TMP/batch.lines" || board_usage_die "stdin cannot be read"
    batch_check

    batch_first=0 batch_wrote='' batch_stop=''
    : >"$BOARD_TMP/batch.done"
    while IFS= read -r batch_line; do
        if [ -n "$batch_stop" ]; then
            printf '%s' "$batch_line" | _jq -c '{args, exit: null, result: null, error: null}' >>"$BOARD_TMP/batch.done"
            continue
        fi
        batch_run "$batch_line" "$(printf '%s' "$batch_line" | _jq -r .n)"
        if [ "$batch_rn_status" = 0 ]; then
            if ! board_dry_run && printf '%s' "$batch_line" | _jq -e .writes >/dev/null; then
                batch_wrote=1
            fi
        else
            [ "$batch_rn_status" != "$BOARD_EXIT_PARTIAL" ] || batch_wrote=1
            [ "$batch_first" != 0 ] || batch_first=$batch_rn_status
            [ -n "$batch_keep" ] || batch_stop=1
        fi
    done <"$BOARD_TMP/batch.todo"

    _jq -sc . <"$BOARD_TMP/batch.done" | board_output text_batch
    if [ "$batch_first" = 0 ]; then
        return 0
    elif [ -n "$batch_wrote" ]; then
        exit "$BOARD_EXIT_PARTIAL"
    fi
    exit "$batch_first"
}

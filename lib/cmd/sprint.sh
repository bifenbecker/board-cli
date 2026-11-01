# shellcheck shell=sh

SPRINT_SHAPE='{id, name, state, start_date, end_date}
  state is active, future or closed. Dates are YYYY-MM-DD, or null.'

help_sprint() {
    cat <<'EOF'
board sprint - sprints and cycles

A sprint is a Cycle on Linear, a Sprint on Jira, and an Iteration on GitHub and GitLab. To put an
issue in one, use 'board issue edit --sprint'.

COMMANDS
  list      List the sprints
  view      Show one sprint
  current   Show the active sprint

Run 'board sprint <command> --help' for details.
EOF
}

help_sprint_list() {
    cat <<EOF
NAME
  board sprint list - list the sprints

USAGE
  board sprint list [--state <state>] [--limit <n|all>]

DESCRIPTION
  Lists the sprints of the board, newest first.

FLAGS
  -s, --state <state>   active, future, closed or all (default)
  -L, --limit <n|all>   At most this many (default 30)

OUTPUT
  Text: one sprint per line, tab-separated: id, state, name, dates.
  JSON: array of $SPRINT_SHAPE

PLATFORM NOTES
  Linear: cycles must be turned on for the team, else exit 3. id is the cycle number, and a cycle
          with no name reads as Cycle <number>. --sprint takes the name or the number.
  Jira: needs [board.target] board, and a board that has sprints, else exit 3.
  GitHub: needs [board.target] sprint_field, the name of the project's iteration field.
  GitLab: iterations need a Premium tier: exit 3 on Free.

EXAMPLES
  board sprint list
  board sprint list --state future --json
EOF
}

cmd_sprint_list() {
    opt_state=all opt_limit=30
    while [ $# -gt 0 ]; do
        case $1 in
            -s | --state) board_arg "$@"; opt_state=$2; shift 2 ;;
            -L | --limit) board_arg "$@"; opt_limit=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    board_require_one_of --state "$opt_state" active future closed all
    board_require_limit "$opt_limit"
    board_doc=$(board_call sprint_list "$opt_state" "$opt_limit") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_sprints
}

help_sprint_view() {
    cat <<EOF
NAME
  board sprint view - show one sprint

USAGE
  board sprint view <id>

DESCRIPTION
  Shows one sprint. To see its issues, use 'board issue list --sprint <name>'.

ARGUMENTS
  <id>        The sprint, as 'board sprint list' shows it

OUTPUT
  Text: id, state, name, dates.
  JSON: $SPRINT_SHAPE

EXAMPLES
  board sprint view 12
EOF
}

cmd_sprint_view() {
    [ $# -eq 1 ] || board_usage_die "<id> is required"
    board_require_id "$1"
    board_doc=$(board_call sprint_view "$1") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_sprint
}

help_sprint_current() {
    cat <<EOF
NAME
  board sprint current - show the active sprint

USAGE
  board sprint current

DESCRIPTION
  Shows the active sprint. Exit 4 when no sprint is active.

OUTPUT
  Text: id, state, name, dates.
  JSON: $SPRINT_SHAPE

EXAMPLES
  board sprint current --jq .name
EOF
}

cmd_sprint_current() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call sprint_current) || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_sprint
}

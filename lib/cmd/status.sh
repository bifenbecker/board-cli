# shellcheck shell=sh

STATUS_SHAPE='{id, name, category}
  category is todo, in_progress, done, canceled, or null when none is declared in [board.statuses].'

help_status() {
    cat <<'EOF'
board status - statuses of the board

A status is a step on the board, and a column on most of them. Its category is the part that means
the same on every board: todo, in_progress, done, canceled.

COMMANDS
  list      List the statuses
  add       Add a status
  rename    Rename a status
  delete    Delete a status

Run 'board status <command> --help' for details.
EOF
}

help_status_list() {
    cat <<EOF
NAME
  board status list - list the statuses

USAGE
  board status list

DESCRIPTION
  Lists the statuses of the board in board order. These are the names 'board issue move' takes.

OUTPUT
  Text: one status per line, tab-separated: name, category.
  JSON: array of $STATUS_SHAPE

PLATFORM NOTES
  GitLab: on Free the statuses are the keys of [board.statuses], which are labels.

EXAMPLES
  board status list
  board status list --jq '.[] | select(.category == "done") | .name'
EOF
}

cmd_status_list() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call status_list) || exit $?
    printf '%s\n' "$board_doc" | board_output text_statuses
}

help_status_add() {
    cat <<EOF
NAME
  board status add - add a status

USAGE
  board status add <name> --category <c>

DESCRIPTION
  Adds a status to the board. Adding one that exists succeeds and changes nothing.

ARGUMENTS
  <name>             Name of the status

FLAGS
  -c, --category <c> todo, in_progress, done or canceled. Required

OUTPUT
  Text: the name.
  JSON: $STATUS_SHAPE

PLATFORM NOTES
  GitHub, GitLab: also declare the status in [board.statuses]: the board has no category to store.
  Linear: the status is added to the team.
  Jira: not supported: statuses belong to workflows, which need an administrator.

EXAMPLES
  board status add "In Review" --category in_progress
EOF
}

cmd_status_add() {
    arg_name='' opt_category=''
    while [ $# -gt 0 ]; do
        case $1 in
            -c | --category) board_arg "$@"; opt_category=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_name" ] || board_unexpected "$1"
                arg_name=$1
                shift
                ;;
        esac
    done
    [ -n "$arg_name" ] || board_usage_die "<name> is required"
    [ -n "$opt_category" ] || board_usage_die "--category is required"
    board_require_one_of --category "$opt_category" todo in_progress done canceled
    board_doc=$(board_call status_add "$arg_name" "$opt_category") || exit $?
    printf '%s\n' "$board_doc" | board_output .name
}

help_status_rename() {
    cat <<EOF
NAME
  board status rename - rename a status

USAGE
  board status rename <name> <new-name>

DESCRIPTION
  Renames a status. Issues in it stay in it.

ARGUMENTS
  <name>       Current name
  <new-name>   New name

OUTPUT
  Text: the new name.
  JSON: $STATUS_SHAPE

PLATFORM NOTES
  GitHub, GitLab: also rename the key in [board.statuses].
  Jira: not supported: statuses belong to workflows, which need an administrator.

EXAMPLES
  board status rename "In Review" "Review"
EOF
}

cmd_status_rename() {
    [ $# -eq 2 ] || board_usage_die "<name> and <new-name> are required"
    [ -n "$1" ] && [ -n "$2" ] || board_usage_die "names must not be empty"
    board_doc=$(board_call status_rename "$1" "$2") || exit $?
    printf '%s\n' "$board_doc" | board_output .name
}

help_status_delete() {
    cat <<'EOF'
NAME
  board status delete - delete a status

USAGE
  board status delete <name> --yes

DESCRIPTION
  Deletes a status. Move the issues out of it first. Deleting needs --yes, so a slip cannot do it.

ARGUMENTS
  <name>       Name of the status

FLAGS
  -y, --yes    Really delete it

OUTPUT
  Text: nothing.
  JSON: {name, deleted}

PLATFORM NOTES
  GitHub: issues still in the status lose it.
  Linear: the status is archived, and that is refused while issues are in it: exit 1.
  Jira: not supported: statuses belong to workflows, which need an administrator.

EXAMPLES
  board status delete "In Review" --yes
EOF
}

cmd_status_delete() {
    arg_name='' opt_yes=''
    while [ $# -gt 0 ]; do
        case $1 in
            -y | --yes) opt_yes=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_name" ] || board_unexpected "$1"
                arg_name=$1
                shift
                ;;
        esac
    done
    [ -n "$arg_name" ] || board_usage_die "<name> is required"
    [ -n "$opt_yes" ] || board_usage_die "deleting needs --yes"
    board_call status_delete "$arg_name" || exit $?
    if board_json_mode; then
        _jq -n --arg name "$arg_name" '{name: $name, deleted: true}' | board_output .
    fi
}

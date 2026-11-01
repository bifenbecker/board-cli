# shellcheck shell=sh

MILESTONE_SHAPE='{id, name, description, state, due_date, url}
  state is open or closed. due_date is YYYY-MM-DD, or null.'

help_milestone() {
    cat <<'EOF'
board milestone - milestones and versions

A milestone is a Milestone on GitHub and GitLab, a Project Milestone on Linear, and a Version on
Jira. To put an issue in one, use 'board issue edit --milestone'.

COMMANDS
  list      List the milestones
  view      Show one milestone
  create    Create a milestone
  edit      Change a milestone
  delete    Delete a milestone

Run 'board milestone <command> --help' for details.
EOF
}

help_milestone_list() {
    cat <<EOF
NAME
  board milestone list - list the milestones

USAGE
  board milestone list [--state <state>] [--limit <n|all>]

DESCRIPTION
  Lists the milestones of the board.

FLAGS
  -s, --state <state>   open (default), closed or all
  -L, --limit <n|all>   At most this many (default 30)

OUTPUT
  Text: one milestone per line, tab-separated: id, state, name, due date.
  JSON: array of $MILESTONE_SHAPE

PLATFORM NOTES
  Linear: milestones belong to a project, so [board.target] project is required.
  GitHub: the milestones of the repository of [board] url.

EXAMPLES
  board milestone list
  board milestone list --state all --jq '.[].name'
EOF
}

cmd_milestone_list() {
    opt_state=open opt_limit=30
    while [ $# -gt 0 ]; do
        case $1 in
            -s | --state) board_arg "$@"; opt_state=$2; shift 2 ;;
            -L | --limit) board_arg "$@"; opt_limit=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    board_require_one_of --state "$opt_state" open closed all
    board_require_limit "$opt_limit"
    board_doc=$(board_call milestone_list "$opt_state" "$opt_limit") || exit $?
    printf '%s\n' "$board_doc" | board_output text_milestones
}

help_milestone_view() {
    cat <<EOF
NAME
  board milestone view - show one milestone

USAGE
  board milestone view <id>

DESCRIPTION
  Shows one milestone.

ARGUMENTS
  <id>        The milestone, as 'board milestone list' shows it

OUTPUT
  Text: id, state, name, due date.
  JSON: $MILESTONE_SHAPE

EXAMPLES
  board milestone view 3
EOF
}

cmd_milestone_view() {
    [ $# -eq 1 ] || board_usage_die "<id> is required"
    board_doc=$(board_call milestone_view "$1") || exit $?
    printf '%s\n' "$board_doc" | board_output text_milestone
}

# Reads --name, --description, --due and --state into the intent file.
milestone_intent() {
    opt_name='' opt_description='' opt_description_set='' opt_due='' opt_state=''
    while [ $# -gt 0 ]; do
        case $1 in
            -n | --name) board_arg "$@"; opt_name=$2; shift 2 ;;
            -d | --description) board_arg "$@"; opt_description=$2; opt_description_set=1; shift 2 ;;
            --due) board_arg "$@"; board_require_date --due "$2"; opt_due=$2; shift 2 ;;
            -s | --state)
                board_arg "$@"
                board_require_one_of --state "$2" open closed
                opt_state=$2
                shift 2
                ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    _jq -nc --arg name "$opt_name" --arg description "$opt_description" \
        --arg description_set "$opt_description_set" --arg due "$opt_due" --arg state "$opt_state" '
        def opt: if . == "" then null else . end;
        {name: ($name | opt), due: ($due | opt), state: ($state | opt),
         description: (if $description_set == "" then null else $description end)}' >"$BOARD_TMP/intent"
}

help_milestone_create() {
    cat <<EOF
NAME
  board milestone create - create a milestone

USAGE
  board milestone create --name <name> [--description <text>] [--due <YYYY-MM-DD>]

DESCRIPTION
  Creates a milestone.

FLAGS
  -n, --name <name>         Name. Required
  -d, --description <text>  Description
      --due <YYYY-MM-DD>    Due date

OUTPUT
  Text: the URL, or the id where the board gives no URL.
  JSON: $MILESTONE_SHAPE

PLATFORM NOTES
  Linear: created in [board.target] project, which is required.
  Jira: creating a version needs the Administer Projects permission.

EXAMPLES
  board milestone create --name v1.2 --due 2026-12-31
EOF
}

cmd_milestone_create() {
    milestone_intent "$@"
    [ -n "$opt_name" ] || board_usage_die "--name is required"
    board_doc=$(board_call milestone_create <"$BOARD_TMP/intent") || exit $?
    printf '%s\n' "$board_doc" | board_output text_url
}

help_milestone_edit() {
    cat <<EOF
NAME
  board milestone edit - change a milestone

USAGE
  board milestone edit <id> [--name <name>] [--description <text>] [--due <YYYY-MM-DD>]
                       [--state open|closed]

DESCRIPTION
  Changes the fields named and leaves the rest.

ARGUMENTS
  <id>                      The milestone, as 'board milestone list' shows it

FLAGS
  -n, --name <name>         New name
  -d, --description <text>  New description
      --due <YYYY-MM-DD>    New due date
  -s, --state <state>       open or closed

OUTPUT
  Text: the URL, or the id where the board gives no URL.
  JSON: $MILESTONE_SHAPE

PLATFORM NOTES
  Jira: closed releases the version.
  Linear: --state is not supported: a project milestone has none.

EXAMPLES
  board milestone edit 3 --state closed
EOF
}

cmd_milestone_edit() {
    [ $# -ge 1 ] || board_usage_die "<id> is required"
    arg_id=$1
    shift
    case $arg_id in
        -*) board_usage_die "<id> is required" ;;
    esac
    milestone_intent "$@"
    [ -n "$opt_name$opt_description_set$opt_due$opt_state" ] || board_usage_die "nothing to change: pass at least one flag"
    board_doc=$(board_call milestone_edit "$arg_id" <"$BOARD_TMP/intent") || exit $?
    printf '%s\n' "$board_doc" | board_output text_url
}

help_milestone_delete() {
    cat <<'EOF'
NAME
  board milestone delete - delete a milestone

USAGE
  board milestone delete <id> --yes

DESCRIPTION
  Deletes a milestone. Issues in it stay, without a milestone. Deleting needs --yes, so a slip
  cannot do it.

ARGUMENTS
  <id>         The milestone, as 'board milestone list' shows it

FLAGS
  -y, --yes    Really delete it

OUTPUT
  Text: nothing.
  JSON: {id, deleted}

EXAMPLES
  board milestone delete 3 --yes
EOF
}

cmd_milestone_delete() {
    arg_id='' opt_yes=''
    while [ $# -gt 0 ]; do
        case $1 in
            -y | --yes) opt_yes=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_id" ] || board_unexpected "$1"
                arg_id=$1
                shift
                ;;
        esac
    done
    [ -n "$arg_id" ] || board_usage_die "<id> is required"
    [ -n "$opt_yes" ] || board_usage_die "deleting needs --yes"
    board_call milestone_delete "$arg_id" || exit $?
    if board_json_mode; then
        _jq -n --arg id "$arg_id" '{id: $id, deleted: true}' | board_output .
    fi
}

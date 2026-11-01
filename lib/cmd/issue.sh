# shellcheck shell=sh

ISSUE_SHAPE='{id, kind, url, title, description, type, status{name, category}, assignees[{id, name}],
         labels[], priority, parent, subtasks[], links[{type, id}], sprint, milestone, due_date,
         author{id, name}, created_at, updated_at}
  id is a string and is what every command takes. category is todo, in_progress, done, canceled,
  or null when the status has none declared. priority is urgent, high, medium, low, none, or null.
  A value the board does not have is null or an empty list, never a missing key. Timestamps are
  UTC; due_date is YYYY-MM-DD.'

help_issue() {
    cat <<'EOF'
board issue - issues on the board

<id> is what the board shows: KAN-1 on Jira, 3KD-13 on Linear, 12 on GitHub and GitLab. On GitHub a
project item with no repository (a draft) has an id starting with PVTI_, and an issue from another
repository is owner/repo#12.

COMMANDS
  list      List issues
  view      Show one issue
  create    Create an issue
  edit      Change the fields of an issue
  move      Change the status of an issue
  close     Move an issue to a done or canceled status
  reopen    Move a closed issue back to a todo status
  delete    Delete an issue for good
  comment   Comments: list, add, edit, delete
  link      Links between issues: list, add, remove

Run 'board issue <command> --help' for details.
EOF
}

# Shared by create and edit. Handles one flag with its value. Returns 1 when it is not one of these.
issue_field_flag() {
    case $1 in
        -t | --title) board_arg "$@"; opt_title=$2; opt_title_set=1 ;;
        -b | --body) board_arg "$@"; BOARD_BODY=$2; BOARD_BODY_SET=1 ;;
        -F | --body-file) board_arg "$@"; board_read_body_file "$2" ;;
        -s | --status) board_arg "$@"; opt_status=$2 ;;
        -p | --priority)
            board_arg "$@"
            board_require_one_of --priority "$2" urgent high medium low none
            opt_priority=$2
            ;;
        --type) board_arg "$@"; opt_type=$2 ;;
        --parent) board_arg "$@"; opt_parent=$2 ;;
        --sprint) board_arg "$@"; opt_sprint=$2 ;;
        -m | --milestone) board_arg "$@"; opt_milestone=$2 ;;
        --due) board_arg "$@"; board_require_date --due "$2"; opt_due=$2 ;;
        *) return 1 ;;
    esac
}

issue_fields_reset() {
    opt_title='' opt_title_set='' opt_status='' opt_priority='' opt_type='' opt_parent=''
    opt_sprint='' opt_milestone='' opt_due='' opt_assignees='' opt_labels=''
    opt_add_labels='' opt_remove_labels='' opt_add_assignees='' opt_remove_assignees='' opt_clear=''
}

# Prints the intent an adapter reads: every key present, null when the flag was not given. The
# body travels on stdin so it never meets the argv limit.
issue_intent() {
    printf '%s' "$BOARD_BODY" | _jq -Rsc \
        --arg body_set "$BOARD_BODY_SET" --arg title "$opt_title" --arg title_set "$opt_title_set" \
        --arg status "$opt_status" --arg priority "$opt_priority" --arg type "$opt_type" \
        --arg parent "$opt_parent" --arg sprint "$opt_sprint" --arg milestone "$opt_milestone" \
        --arg due "$opt_due" --arg assignees "$opt_assignees" --arg labels "$opt_labels" \
        --arg add_labels "$opt_add_labels" --arg remove_labels "$opt_remove_labels" \
        --arg add_assignees "$opt_add_assignees" --arg remove_assignees "$opt_remove_assignees" \
        --arg clear "$opt_clear" '
        include "jq/common";
        def list: if . == "" then [] else split("\n") end;
        {title: (if $title_set == "" then null else $title end),
         body: (if $body_set == "" then null else . end),
         status: ($status | nullify), priority: ($priority | nullify), type: ($type | nullify),
         parent: ($parent | nullify), sprint: ($sprint | nullify), milestone: ($milestone | nullify),
         due: ($due | nullify), assignees: ($assignees | list), labels: ($labels | list),
         add_labels: ($add_labels | list), remove_labels: ($remove_labels | list),
         add_assignees: ($add_assignees | list), remove_assignees: ($remove_assignees | list),
         clear: ($clear | list)}'
}

# --- list --------------------------------------------------------------------------------

help_issue_list() {
    cat <<EOF
NAME
  board issue list - list issues

USAGE
  board issue list [--category <c>] [--status <name>] [--assignee <user>] [--label <name>]...
                   [--priority <p>] [--type <name>] [--sprint <name>] [--milestone <name>]
                   [--parent <id>] [--search <text>] [--limit <n|all>]

DESCRIPTION
  Lists the issues on the board, most recently updated first. Filters combine with AND; several
  --label flags mean the issue carries all of them. Without --category or --status, only open
  work is listed: every issue not in the done or canceled category.

FLAGS
  -c, --category <c>      todo, in_progress, done, canceled, open (default: neither done nor
                          canceled, so a status with no category shows) or all
  -s, --status <name>     In this status, by name. Overrides --category
  -a, --assignee <user>   Assigned to this member; @me for yourself; none for unassigned
  -l, --label <name>      Carrying this label; repeat for several
  -p, --priority <p>      urgent, high, medium, low, or none for issues without one
      --type <name>       Of this issue type
      --sprint <name>     In this sprint; current for the active one
  -m, --milestone <name>  In this milestone
      --parent <id>       Subtasks of this issue
  -S, --search <text>     Free-text search in title and description
  -L, --limit <n|all>     At most this many issues (default 30). A warning goes to stderr when
                          more exist

OUTPUT
  Text: one issue per line, tab-separated: id, status, title.
  JSON: array of $ISSUE_SHAPE
  An issue in a list has links and subtasks only where the board returns them cheaply. Use
  'board issue view' for the whole issue.

PLATFORM NOTES
  GitHub: lists the items of the project in project order, draft items included, pull requests
          left out. --search reads every page it has to, so it is slower on a big project.
  GitLab: --category needs [board.statuses]: an open issue with no status label has no category.
  Linear: --type is not supported; there are no issue types.

EXAMPLES
  board issue list
  board issue list --assignee @me --jq '.[].id'
  board issue list --category done --limit 5 --json
  board issue list --search "login timeout" --label bug --category all
EOF
}

cmd_issue_list() {
    opt_category='' opt_status='' opt_assignee='' opt_labels='' opt_priority='' opt_type=''
    opt_sprint='' opt_milestone='' opt_parent='' opt_search='' opt_limit=30
    while [ $# -gt 0 ]; do
        case $1 in
            -c | --category) board_arg "$@"; opt_category=$2; shift 2 ;;
            -s | --status) board_arg "$@"; opt_status=$2; shift 2 ;;
            -a | --assignee) board_arg "$@"; opt_assignee=$2; shift 2 ;;
            -l | --label) board_arg "$@"; opt_labels=$(board_list_add "$opt_labels" "$2"); shift 2 ;;
            -p | --priority) board_arg "$@"; opt_priority=$2; shift 2 ;;
            --type) board_arg "$@"; opt_type=$2; shift 2 ;;
            --sprint) board_arg "$@"; opt_sprint=$2; shift 2 ;;
            -m | --milestone) board_arg "$@"; opt_milestone=$2; shift 2 ;;
            --parent) board_arg "$@"; opt_parent=$2; shift 2 ;;
            -S | --search) board_arg "$@"; opt_search=$2; shift 2 ;;
            -L | --limit) board_arg "$@"; opt_limit=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    [ -z "$opt_category" ] || board_require_one_of --category "$opt_category" todo in_progress done canceled open all
    [ -z "$opt_priority" ] || board_require_one_of --priority "$opt_priority" urgent high medium low none
    board_require_limit "$opt_limit"
    [ -n "$opt_category" ] || opt_category=open
    [ -z "$opt_status" ] || opt_category=all
    _jq -nc --arg category "$opt_category" --arg status "$opt_status" --arg assignee "$opt_assignee" \
        --arg labels "$opt_labels" --arg priority "$opt_priority" --arg type "$opt_type" \
        --arg sprint "$opt_sprint" --arg milestone "$opt_milestone" --arg parent "$opt_parent" \
        --arg search "$opt_search" --arg limit "$opt_limit" '
        include "jq/common";
        {category: $category, status: ($status | nullify), assignee: ($assignee | nullify),
         labels: (if $labels == "" then [] else ($labels | split("\n")) end),
         priority: ($priority | nullify), type: ($type | nullify), sprint: ($sprint | nullify),
         milestone: ($milestone | nullify), parent: ($parent | nullify), search: ($search | nullify),
         limit: (if $limit == "all" then null else ($limit | tonumber) end)}' >"$BOARD_TMP/intent"
    board_doc=$(board_call issue_list <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_issues
}

# --- view --------------------------------------------------------------------------------

help_issue_view() {
    cat <<EOF
NAME
  board issue view - show one issue

USAGE
  board issue view <id> [--comments]

DESCRIPTION
  Shows every field of one issue. With --comments the comments come too, for one call instead of
  two.

ARGUMENTS
  <id>            The issue, as the board shows it

FLAGS
  -c, --comments  Include the comments, as a comments[] key after the usual ones

OUTPUT
  Text: the fields, then the description.
  JSON: $ISSUE_SHAPE
  With --comments, also comments[{id, author{id, name}, body, url, created_at, updated_at}].

EXAMPLES
  board issue view KAN-1
  board issue view 3KD-13 --comments
  board issue view 12 --jq .title
EOF
}

cmd_issue_view() {
    arg_id='' opt_comments=''
    while [ $# -gt 0 ]; do
        case $1 in
            -c | --comments) opt_comments=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_id" ] || board_unexpected "$1"
                arg_id=$1
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    board_doc=$(board_call issue_view "$arg_id") || board_fail "$?" "$board_doc"
    if [ -n "$opt_comments" ]; then
        board_cmt_status=0
        board_comments=$(board_call issue_comment_list "$arg_id" 2>/dev/null) || board_cmt_status=$?
        case $board_cmt_status in
            0) ;;
            "$BOARD_EXIT_UNSUPPORTED") board_comments='[]' ;;
            *) exit "$board_cmt_status" ;;
        esac
        printf '%s\n%s\n' "$board_doc" "$board_comments" | _jq -sc '.[0] + {comments: .[1]}' | board_output text_issue
    else
        printf '%s\n' "$board_doc" | board_output text_issue
    fi
}

# --- create ------------------------------------------------------------------------------

help_issue_create() {
    cat <<EOF
NAME
  board issue create - create an issue

USAGE
  board issue create --title <text> [--body <text> | --body-file <path|->] [--status <name>]
                     [--assignee <user>]... [--label <name>]... [--priority <p>] [--type <name>]
                     [--parent <id>] [--sprint <name>] [--milestone <name>] [--due <YYYY-MM-DD>]

DESCRIPTION
  Creates an issue on the board. Without --status it starts in the status the board gives new
  issues. Labels that do not exist yet are created where the board allows it.

FLAGS
  -t, --title <text>       Title. Required
  -b, --body <text>        Description, in markdown
  -F, --body-file <path|-> Read the description from a file, or stdin with -
  -s, --status <name>      Status to start in
  -a, --assignee <user>    Assign this member; @me for yourself; repeat where the board allows it
  -l, --label <name>       Add this label; repeat for several
  -p, --priority <p>       urgent, high, medium, low or none
      --type <name>        Issue type (default: [board.defaults] type, else the board's own)
      --parent <id>        Make it a subtask of this issue
      --sprint <name>      Put it in this sprint; current for the active one
  -m, --milestone <name>   Put it in this milestone
      --due <YYYY-MM-DD>   Due date

OUTPUT
  Text: the URL of the issue.
  JSON: $ISSUE_SHAPE
  Exit 6 means the issue exists but a later step failed: the id is on stdout.

PLATFORM NOTES
  GitHub: the issue is created in the repository of [board] url and added to the project. Issue
          types exist only in organisations: exit 3 for --type elsewhere.
  Jira: description is converted from markdown to wiki markup, best effort. One assignee only.
  Linear: one assignee only. --type is not supported.
  GitLab: on Free one assignee only.

EXAMPLES
  board issue create --title "Login fails" --label bug --priority high
  board issue create --title "Fix it" --body-file notes.md --assignee @me --json
  board issue create --title "Step one" --parent KAN-1 --type Subtask
EOF
}

cmd_issue_create() {
    issue_fields_reset
    while [ $# -gt 0 ]; do
        if issue_field_flag "$@"; then
            shift 2
            continue
        fi
        case $1 in
            -a | --assignee) board_arg "$@"; opt_assignees=$(board_list_add "$opt_assignees" "$2"); shift 2 ;;
            -l | --label) board_arg "$@"; opt_labels=$(board_list_add "$opt_labels" "$2"); shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    [ -n "$opt_title" ] || board_usage_die "--title is required"
    [ -n "$opt_type" ] || opt_type=$(board_config_get .defaults.type)
    issue_intent >"$BOARD_TMP/intent"
    board_doc=$(board_call issue_create <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

# --- edit --------------------------------------------------------------------------------

help_issue_edit() {
    cat <<EOF
NAME
  board issue edit - change the fields of an issue

USAGE
  board issue edit <id> [--title <text>] [--body <text> | --body-file <path|->] [--status <name>]
                   [--add-label <name>]... [--remove-label <name>]...
                   [--add-assignee <user>]... [--remove-assignee <user>]...
                   [--priority <p>] [--type <name>] [--parent <id>] [--sprint <name>]
                   [--milestone <name>] [--due <YYYY-MM-DD>] [--clear <field>]...

DESCRIPTION
  Changes the fields named and leaves the rest. Removing a label or assignee that is not there is
  not an error. At least one change is required.

ARGUMENTS
  <id>                       The issue, as the board shows it

FLAGS
  -t, --title <text>         New title
  -b, --body <text>          New description, in markdown
  -F, --body-file <path|->   Read the new description from a file, or stdin with -
  -s, --status <name>        New status, as 'board issue move' does
      --add-label <name>     Add this label; repeat for several
      --remove-label <name>  Remove this label; repeat for several
      --add-assignee <user>  Assign this member; @me for yourself; repeat where allowed
      --remove-assignee <user>  Unassign this member; repeat for several
  -p, --priority <p>         urgent, high, medium, low or none
      --type <name>          New issue type
      --parent <id>          Make it a subtask of this issue
      --sprint <name>        Move it to this sprint; current for the active one
  -m, --milestone <name>     Move it to this milestone
      --due <YYYY-MM-DD>     New due date
      --clear <field>        Empty a field: priority, parent, sprint, milestone or due. Repeat
                             for several

OUTPUT
  Text: the URL of the issue.
  JSON: $ISSUE_SHAPE

PLATFORM NOTES
  GitHub: a draft item takes only --title, --body and --status.
  Linear: one assignee only: --add-assignee replaces the current one. --type is not supported.

EXAMPLES
  board issue edit KAN-1 --title "A better title"
  board issue edit 12 --add-label bug --remove-label triage
  board issue edit 3KD-13 --body-file notes.md --clear due
EOF
}

cmd_issue_edit() {
    issue_fields_reset
    arg_id=''
    while [ $# -gt 0 ]; do
        if issue_field_flag "$@"; then
            shift 2
            continue
        fi
        case $1 in
            --add-label) board_arg "$@"; opt_add_labels=$(board_list_add "$opt_add_labels" "$2"); shift 2 ;;
            --remove-label) board_arg "$@"; opt_remove_labels=$(board_list_add "$opt_remove_labels" "$2"); shift 2 ;;
            --add-assignee) board_arg "$@"; opt_add_assignees=$(board_list_add "$opt_add_assignees" "$2"); shift 2 ;;
            --remove-assignee) board_arg "$@"; opt_remove_assignees=$(board_list_add "$opt_remove_assignees" "$2"); shift 2 ;;
            --clear)
                board_arg "$@"
                board_require_one_of --clear "$2" priority parent sprint milestone due
                opt_clear=$(board_list_add "$opt_clear" "$2")
                shift 2
                ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_id" ] || board_unexpected "$1"
                arg_id=$1
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    [ -n "$opt_title_set$BOARD_BODY_SET$opt_status$opt_priority$opt_type$opt_parent$opt_sprint$opt_milestone$opt_due$opt_add_labels$opt_remove_labels$opt_add_assignees$opt_remove_assignees$opt_clear" ] ||
        board_usage_die "nothing to change: pass at least one flag"
    [ -z "$opt_title_set" ] || [ -n "$opt_title" ] || board_usage_die "--title must not be empty"
    issue_intent >"$BOARD_TMP/intent"
    board_doc=$(board_call issue_edit "$arg_id" <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

# --- move --------------------------------------------------------------------------------

help_issue_move() {
    cat <<EOF
NAME
  board issue move - change the status of an issue

USAGE
  board issue move <id> <status>

DESCRIPTION
  Moves an issue to a status, named as 'board status list' shows it, ignoring case. Moving an issue
  that is already there succeeds. An unknown status is exit 2, and stderr lists the valid ones.

ARGUMENTS
  <id>        The issue, as the board shows it
  <status>    The status to move to

OUTPUT
  Text: the URL of the issue.
  JSON: $ISSUE_SHAPE

PLATFORM NOTES
  Jira: moves through a transition. When the workflow has none to that status, exit 1 names the
        ones it has.
  GitHub: the project's built-in workflows may act on the move a few seconds later: Done closes the
          issue, and closing sets Done. Read the issue again before relying on a final state.
  GitLab: on Free a status is a label. board removes the other status labels, and a status mapped
          to done also closes the issue.

EXAMPLES
  board issue move KAN-1 "In Progress"
  board issue move 12 done --jq .status
EOF
}

cmd_issue_move() {
    [ $# -eq 2 ] || board_usage_die "<id> and <status> are required"
    board_require_id "$1"
    [ -n "$2" ] || board_usage_die "<status> must not be empty"
    board_doc=$(board_call issue_move "$1" "$2") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

# --- close and reopen --------------------------------------------------------------------

help_issue_close() {
    cat <<EOF
NAME
  board issue close - move an issue to a done or canceled status

USAGE
  board issue close <id> [--reason done|canceled]

DESCRIPTION
  Moves the issue to the first status of the category. Closing a closed issue succeeds.

ARGUMENTS
  <id>                The issue, as the board shows it

FLAGS
  -r, --reason <r>    done (default) or canceled

OUTPUT
  Text: the URL of the issue.
  JSON: $ISSUE_SHAPE

PLATFORM NOTES
  Jira: --reason canceled needs a status declared canceled in [board.statuses].
  GitHub: --reason canceled closes the issue as not planned. The built-in workflow "Item closed"
          may then set the status to Done.

EXAMPLES
  board issue close KAN-1
  board issue close 12 --reason canceled
EOF
}

cmd_issue_close() {
    arg_id='' opt_reason=done
    while [ $# -gt 0 ]; do
        case $1 in
            -r | --reason) board_arg "$@"; opt_reason=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_id" ] || board_unexpected "$1"
                arg_id=$1
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    board_require_one_of --reason "$opt_reason" done canceled
    board_doc=$(board_call issue_close "$arg_id" "$opt_reason") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

help_issue_reopen() {
    cat <<EOF
NAME
  board issue reopen - move a closed issue back to a todo status

USAGE
  board issue reopen <id> [--status <name>]

DESCRIPTION
  Moves the issue to the first status in the todo category, or to the one named. Reopening an open
  issue succeeds and leaves it where it is, unless --status names another.

ARGUMENTS
  <id>                  The issue, as the board shows it

FLAGS
  -s, --status <name>   Status to reopen into

OUTPUT
  Text: the URL of the issue.
  JSON: $ISSUE_SHAPE

EXAMPLES
  board issue reopen KAN-1
  board issue reopen 12 --status "In Progress"
EOF
}

cmd_issue_reopen() {
    arg_id='' opt_status=''
    while [ $# -gt 0 ]; do
        case $1 in
            -s | --status) board_arg "$@"; opt_status=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_id" ] || board_unexpected "$1"
                arg_id=$1
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    board_doc=$(board_call issue_reopen "$arg_id" "$opt_status") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

# --- delete ------------------------------------------------------------------------------

help_issue_delete() {
    cat <<'EOF'
NAME
  board issue delete - delete an issue for good

USAGE
  board issue delete <id> --yes

DESCRIPTION
  Deletes the issue. This cannot be undone on most boards. Deleting needs --yes, so a slip cannot
  do it.

ARGUMENTS
  <id>        The issue, as the board shows it

FLAGS
  -y, --yes   Really delete it

OUTPUT
  Text: nothing.
  JSON: {id, deleted}

PLATFORM NOTES
  Linear: moves the issue to the trash, where it stays for 30 days. board treats it as gone.
  GitHub: deleting needs admin rights on the repository. A draft item is removed from the project.
  GitLab: deleting needs the Owner role.

EXAMPLES
  board issue delete KAN-1 --yes
EOF
}

cmd_issue_delete() {
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
    board_require_id "$arg_id"
    [ -n "$opt_yes" ] || board_usage_die "deleting needs --yes"
    board_call issue_delete "$arg_id" || exit $?
    if board_json_mode; then
        _jq -n --arg id "$arg_id" '{id: $id, deleted: true}' | board_output .
    fi
}

# --- comment -----------------------------------------------------------------------------

ISSUE_COMMENT_SHAPE='{id, author{id, name}, body, url, created_at, updated_at}
  body is markdown.'

help_issue_comment() {
    cat <<'EOF'
board issue comment - comments on an issue

COMMANDS
  list      List the comments
  add       Add a comment
  edit      Change a comment
  delete    Delete a comment

Run 'board issue comment <command> --help' for details.
EOF
}

help_issue_comment_list() {
    cat <<EOF
NAME
  board issue comment list - list the comments

USAGE
  board issue comment list <id>

DESCRIPTION
  Lists the comments people wrote, oldest first. Entries the board writes by itself are left out.

ARGUMENTS
  <id>        The issue, as the board shows it

OUTPUT
  Text: each comment with its id, author and date.
  JSON: array of $ISSUE_COMMENT_SHAPE

PLATFORM NOTES
  GitHub: a draft item has no comments: exit 3.
  Jira: bodies are converted from wiki markup to markdown, best effort.

EXAMPLES
  board issue comment list KAN-1
  board issue comment list 12 --jq '.[-1].body'
EOF
}

cmd_issue_comment_list() {
    [ $# -eq 1 ] || board_usage_die "<id> is required"
    board_require_id "$1"
    board_doc=$(board_call issue_comment_list "$1") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_comments
}

help_issue_comment_add() {
    cat <<EOF
NAME
  board issue comment add - add a comment

USAGE
  board issue comment add <id> (--body <text> | --body-file <path|->)

DESCRIPTION
  Adds a comment to the issue, written in markdown.

ARGUMENTS
  <id>                       The issue, as the board shows it

FLAGS
  -b, --body <text>          The comment
  -F, --body-file <path|->   Read the comment from a file, or stdin with -

OUTPUT
  Text: the URL of the comment, or its id where the board gives no URL.
  JSON: $ISSUE_COMMENT_SHAPE

PLATFORM NOTES
  GitHub: a draft item has no comments: exit 3.
  Jira: the body is converted from markdown to wiki markup, best effort.

EXAMPLES
  board issue comment add KAN-1 --body "Fixed in 1.2"
  board issue comment add 12 --body-file notes.md --jq .id
EOF
}

issue_comment_body_flags() {
    while [ $# -gt 0 ]; do
        case $1 in
            -b | --body) board_arg "$@"; BOARD_BODY=$2; BOARD_BODY_SET=1; shift 2 ;;
            -F | --body-file) board_arg "$@"; board_read_body_file "$2"; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    board_require_body "the comment"
    printf '%s' "$BOARD_BODY" | _jq -Rsc '{body: .}' >"$BOARD_TMP/intent"
}

cmd_issue_comment_add() {
    [ $# -ge 1 ] || board_usage_die "<id> is required"
    arg_id=$1
    shift
    board_require_id "$arg_id"
    issue_comment_body_flags "$@"
    board_doc=$(board_call issue_comment_add "$arg_id" <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

help_issue_comment_edit() {
    cat <<EOF
NAME
  board issue comment edit - change a comment

USAGE
  board issue comment edit <id> <comment-id> (--body <text> | --body-file <path|->)

DESCRIPTION
  Replaces the text of a comment. Comments of other people may be refused: exit 5.

ARGUMENTS
  <id>                       The issue, as the board shows it
  <comment-id>               The comment, as 'board issue comment list' shows it

FLAGS
  -b, --body <text>          The new text
  -F, --body-file <path|->   Read the new text from a file, or stdin with -

OUTPUT
  Text: the URL of the comment, or its id where the board gives no URL.
  JSON: $ISSUE_COMMENT_SHAPE

EXAMPLES
  board issue comment edit KAN-1 10000 --body "Fixed in 1.3"
EOF
}

cmd_issue_comment_edit() {
    [ $# -ge 2 ] || board_usage_die "<id> and <comment-id> are required"
    arg_id=$1
    arg_comment=$2
    shift 2
    board_require_id "$arg_id"
    board_require_id "$arg_comment"
    issue_comment_body_flags "$@"
    board_doc=$(board_call issue_comment_edit "$arg_id" "$arg_comment" <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

help_issue_comment_delete() {
    cat <<'EOF'
NAME
  board issue comment delete - delete a comment

USAGE
  board issue comment delete <id> <comment-id> --yes

DESCRIPTION
  Deletes a comment. Deleting needs --yes, so a slip cannot do it.

ARGUMENTS
  <id>            The issue, as the board shows it
  <comment-id>    The comment, as 'board issue comment list' shows it

FLAGS
  -y, --yes       Really delete it

OUTPUT
  Text: nothing.
  JSON: {id, deleted}

EXAMPLES
  board issue comment delete KAN-1 10000 --yes
EOF
}

cmd_issue_comment_delete() {
    arg_id='' arg_comment='' opt_yes=''
    while [ $# -gt 0 ]; do
        case $1 in
            -y | --yes) opt_yes=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *)
                if [ -z "$arg_id" ]; then
                    arg_id=$1
                elif [ -z "$arg_comment" ]; then
                    arg_comment=$1
                else
                    board_unexpected "$1"
                fi
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    board_require_id "$arg_comment"
    [ -n "$opt_yes" ] || board_usage_die "deleting needs --yes"
    board_call issue_comment_delete "$arg_id" "$arg_comment" || exit $?
    if board_json_mode; then
        _jq -n --arg id "$arg_comment" '{id: $id, deleted: true}' | board_output .
    fi
}

# --- link --------------------------------------------------------------------------------

ISSUE_LINK_SHAPE='{type, id}
  type is blocks, blocked-by, relates, duplicates or duplicated-by, read from the side of the
  issue asked about. id is the other issue.'

help_issue_link() {
    cat <<'EOF'
board issue link - links between issues

A link is typed: blocks, blocked-by, relates, duplicates. Parent and subtask are not links: they
are fields, set with 'board issue edit --parent'.

COMMANDS
  list      List the links of an issue
  add       Link two issues
  remove    Remove a link

Run 'board issue link <command> --help' for details.
EOF
}

help_issue_link_list() {
    cat <<EOF
NAME
  board issue link list - list the links of an issue

USAGE
  board issue link list <id>

DESCRIPTION
  Lists the links of an issue, in both directions.

ARGUMENTS
  <id>        The issue, as the board shows it

OUTPUT
  Text: one link per line, tab-separated: type, id.
  JSON: array of $ISSUE_LINK_SHAPE

EXAMPLES
  board issue link list KAN-1
EOF
}

cmd_issue_link_list() {
    [ $# -eq 1 ] || board_usage_die "<id> is required"
    board_require_id "$1"
    board_doc=$(board_call issue_link_list "$1") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_links
}

help_issue_link_add() {
    cat <<EOF
NAME
  board issue link add - link two issues

USAGE
  board issue link add <id> <other-id> --type <type>

DESCRIPTION
  Links <id> to <other-id>, read as "<id> blocks <other-id>". Linking twice succeeds.

ARGUMENTS
  <id>             The issue, as the board shows it
  <other-id>       The issue on the other side

FLAGS
  -t, --type <t>   blocks, blocked-by, relates or duplicates. Required

OUTPUT
  Text: the URL of <id>.
  JSON: $ISSUE_SHAPE

PLATFORM NOTES
  GitHub: duplicates also closes <id>.
  GitLab: on Free only relates works: exit 3 for blocks and blocked-by. duplicates is not
          available: exit 3.
  Linear: two issues hold one link at a time: a new link between them replaces the old one.
          duplicates also moves <id> to the Duplicate status; removing the link moves it back.

EXAMPLES
  board issue link add KAN-1 KAN-2 --type blocks
EOF
}

issue_link_args() {
    arg_id='' arg_other='' opt_type=''
    while [ $# -gt 0 ]; do
        case $1 in
            -t | --type) board_arg "$@"; opt_type=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *)
                if [ -z "$arg_id" ]; then
                    arg_id=$1
                elif [ -z "$arg_other" ]; then
                    arg_other=$1
                else
                    board_unexpected "$1"
                fi
                shift
                ;;
        esac
    done
    board_require_id "$arg_id"
    board_require_id "$arg_other"
    [ -n "$opt_type" ] || board_usage_die "--type is required"
    board_require_one_of --type "$opt_type" blocks blocked-by relates duplicates
}

cmd_issue_link_add() {
    issue_link_args "$@"
    board_doc=$(board_call issue_link_add "$arg_id" "$arg_other" "$opt_type") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

help_issue_link_remove() {
    cat <<EOF
NAME
  board issue link remove - remove a link

USAGE
  board issue link remove <id> <other-id> --type <type>

DESCRIPTION
  Removes the link. Removing a link that is not there succeeds.

ARGUMENTS
  <id>             The issue, as the board shows it
  <other-id>       The issue on the other side

FLAGS
  -t, --type <t>   blocks, blocked-by, relates or duplicates. Required

OUTPUT
  Text: the URL of <id>.
  JSON: $ISSUE_SHAPE

EXAMPLES
  board issue link remove KAN-1 KAN-2 --type blocks
EOF
}

cmd_issue_link_remove() {
    issue_link_args "$@"
    board_doc=$(board_call issue_link_remove "$arg_id" "$arg_other" "$opt_type") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_url
}

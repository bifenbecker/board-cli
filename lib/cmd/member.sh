# shellcheck shell=sh

help_member() {
    cat <<'EOF'
board member - people who can be assigned

COMMANDS
  list      List them

Run 'board member <command> --help' for details.
EOF
}

help_member_list() {
    cat <<'EOF'
NAME
  board member list - list the people who can be assigned

USAGE
  board member list [--search <text>]

DESCRIPTION
  Lists who can be assigned on this board. The id is what --assignee takes.

FLAGS
  -S, --search <text>   Only people whose name matches

OUTPUT
  Text: one person per line, tab-separated: id, name.
  JSON: array of {id, name}

PLATFORM NOTES
  GitHub: people who can be assigned in the repository of [board] url.
  Jira: id is the accountId on Cloud and the user name on Data Center.
  Linear: id is a UUID. --assignee also takes the full name or the display name.

EXAMPLES
  board member list
  board member list --search roman --jq '.[0].id'
EOF
}

cmd_member_list() {
    opt_search=''
    while [ $# -gt 0 ]; do
        case $1 in
            -S | --search) board_arg "$@"; opt_search=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    board_doc=$(board_call member_list "$opt_search") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_members
}

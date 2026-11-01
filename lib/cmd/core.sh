# shellcheck shell=sh

BOARD_CONFIG_SHAPE='{kind, cli, url, project, config, issue_uri, target, statuses, priority, labels, size}
  Keys of [board] in workflow.toml. A key the file does not set is absent here.'

help_root() {
    cat <<'EOF'
board - one command line for task boards: Linear, Jira, GitHub Projects, GitLab

The same commands, flags and JSON work on every board. The project declares its board in [board]
of workflow.toml, so changing the board changes that section and nothing else.

START HERE
  board doctor                 Is the board declared and reachable, and is login in place?
  board capabilities --json    What this board can and cannot do
  board issue list --json      The issues on the board

  Every command answers --help with its exact flags and its JSON shape. That help is the
  documentation: read it instead of guessing a flag.

COMMANDS
  issue        Issues: list, view, create, edit, move, close, reopen, delete, comment, link
  status       Statuses of the board: list, add, rename, delete
  label        Labels: list, create, edit, delete, sync
  member       People who can be assigned
  sprint       Sprints and cycles: list, view, current
  milestone    Milestones and versions: list, view, create, edit, delete

  init         Declare the board of this project from its URL
  list         Boards reachable with the current login
  view         This board: columns and statuses
  doctor       Check tools, the declaration and login
  capabilities What this board can and cannot do
  auth         Login state
  config       Show the declaration board reads
  api          Call the board's own API
  version      Print the version
  self         Update or remove board

WORKING WITH THE OUTPUT
  Act on results through --json or --jq <expr>: the keys and types are the same on every board,
  and a value the board does not have is null, never a missing key. Text output is for people,
  and may change.
  Long text goes through --body-file <path|->, never through an argument.
  After a change: text mode prints the URL, JSON mode prints the whole object as it now is.

EXIT CODES
  0  success
  1  the board or a tool failed. Read stderr; a retry may help
  2  wrong usage. Fix the call: run the command with --help
  3  this board cannot do it. Check 'board capabilities --json'. Do not retry
  4  not found. This is an answer, not a broken call
  5  not authenticated, or the token may not do this. Ask the user to log in; do not retry
  6  partial: a write went through and a later step failed. The id is on stdout.
     Do not repeat the write. Finish with 'board issue edit' or 'board issue move'

WHEN A COMMAND IS NOT ENOUGH
  Use 'board api' for what no command covers. It speaks the board's own API, so what it prints
  is not normalised and will not carry over to another board.

THE USER DECIDES
  Deleting issues, statuses and labels, and any other step that cannot be undone. Do not run
  these unless the user asked.

Run 'board <command> --help' for details.
EOF
}

# --- version ------------------------------------------------------------------------------

help_version() {
    cat <<'EOF'
NAME
  board version - print the version

USAGE
  board version

DESCRIPTION
  Prints the installed board version. board --version does the same.

OUTPUT
  Text: the version, e.g. 0.1.0
  JSON: {version}

EXAMPLES
  board version
  board version --jq .version
EOF
}

cmd_version() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_v=$(tr -d '\r\n' <"$BOARD_HOME/VERSION")
    if board_json_mode; then
        board_jq_probe
        _jq -n --arg v "$board_v" '{version: $v}' | board_output .
    else
        printf '%s\n' "$board_v"
    fi
}

# --- config -------------------------------------------------------------------------------

help_config() {
    cat <<'EOF'
board config - the declaration board reads

The board is declared in [board] of workflow.toml, found through WORKFLOW_FILE or the nearest
workflow.toml at or above the working directory. Secrets never go there.

COMMANDS
  show      Print the declaration
  get       Print one key
  path      Print the path of the file

Run 'board config <command> --help' for details.
EOF
}

help_config_show() {
    cat <<EOF
NAME
  board config show - print the declaration

USAGE
  board config show

DESCRIPTION
  Prints [board] and its subsections as board read them. Sections other than [board] are not
  read.

OUTPUT
  Text and JSON: $BOARD_CONFIG_SHAPE

EXAMPLES
  board config show
  board config show --jq .statuses
EOF
}

cmd_config_show() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_config_load
    printf '%s' "$BOARD_CONFIG_JSON" | { BOARD_JSON=1 board_output .; }
}

help_config_get() {
    cat <<'EOF'
NAME
  board config get - print one key

USAGE
  board config get <key>

DESCRIPTION
  Prints one value of the declaration. A subsection is reached with a dot: target.number.

ARGUMENTS
  <key>       Dotted key under [board]

OUTPUT
  Text: the value. Exit 4 when the key is not set.
  JSON: the value as JSON

EXAMPLES
  board config get kind
  board config get target.number
EOF
}

cmd_config_get() {
    [ $# -eq 1 ] || board_usage_die "<key> is required"
    case $1 in
        '' | *[!A-Za-z0-9_.-]*) board_usage_die "<key> must be a dotted key, got '$1'" ;;
    esac
    board_config_load
    board_cg_value=$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -c --arg k "$1" 'getpath($k | split(".")) // empty')
    [ -n "$board_cg_value" ] || board_not_found "no key $1 in [board] of $BOARD_CONFIG_FILE"
    printf '%s\n' "$board_cg_value" | board_output .
}

help_config_path() {
    cat <<'EOF'
NAME
  board config path - print the path of the file

USAGE
  board config path

DESCRIPTION
  Prints which workflow.toml board reads from here. Exit 2 when there is none.

OUTPUT
  Text: the path
  JSON: {path}

EXAMPLES
  board config path
EOF
}

cmd_config_path() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_config_load
    if board_json_mode; then
        _jq -n --arg p "$BOARD_CONFIG_FILE" '{path: $p}' | board_output .
    else
        printf '%s\n' "$BOARD_CONFIG_FILE"
    fi
}

# --- self ---------------------------------------------------------------------------------

help_self() {
    cat <<'EOF'
board self - update or remove board

COMMANDS
  update      Install another release over this one
  uninstall   Remove board

Run 'board self <command> --help' for details.
EOF
}


# The installer lays out <prefix>/share/board and <prefix>/bin/board, so the prefix is known from
# BOARD_HOME; a checkout has no marker and is left alone.
board_self_prefix() {
    [ -f "$BOARD_HOME/.board-install" ] || board_die "this board runs from a checkout, not from install.sh: update it with git"
    board_sp=${BOARD_HOME%/share/board}
    [ "$board_sp" != "$BOARD_HOME" ] || board_die "cannot tell the install prefix from $BOARD_HOME"
    printf '%s' "$board_sp"
}

help_self_update() {
    cat <<'EOF'
NAME
  board self update - install another release over this one

USAGE
  board self update [--version <tag>]

DESCRIPTION
  Downloads install.sh and runs it over the current install. Works only on a board installed by
  install.sh.

FLAGS
  --version <tag>   Release to install, e.g. v0.1.0 (default: the latest release)

OUTPUT
  Text: progress from install.sh
  JSON: not available

EXAMPLES
  board self update
  board self update --version v0.1.0
EOF
}

cmd_self_update() {
    opt_version=''
    while [ $# -gt 0 ]; do
        case $1 in
            --version) board_arg "$@"; opt_version=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    board_su_prefix=$(board_self_prefix)
    board_require curl "to download install.sh"
    board_su_script=$BOARD_TMP/install.sh
    curl -fsSL "$BOARD_INSTALL_URL" >"$board_su_script" || board_die "cannot download $BOARD_INSTALL_URL"
    set -- --prefix "$board_su_prefix"
    [ -z "$opt_version" ] || set -- "$@" --version "$opt_version"
    sh "$board_su_script" "$@"
}

help_self_uninstall() {
    cat <<'EOF'
NAME
  board self uninstall - remove board

USAGE
  board self uninstall

DESCRIPTION
  Removes what install.sh wrote. Works only on a board installed by install.sh.

OUTPUT
  Text: what was removed
  JSON: not available

EXAMPLES
  board self uninstall
EOF
}

cmd_self_uninstall() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_su_prefix=$(board_self_prefix)
    sh "$BOARD_HOME/install.sh" --prefix "$board_su_prefix" --uninstall
}

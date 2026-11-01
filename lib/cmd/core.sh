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
    board_cg_value=$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -c --arg k "$1" '(try getpath($k | split(".")) catch null) | if . == null then empty else . end')
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

# --- board ------------------------------------------------------------------------------

help_list() {
    cat <<'EOF'
NAME
  board list - boards reachable with the current login

USAGE
  board list

DESCRIPTION
  Lists the boards the login of this board kind can reach: the same service, not only the one
  declared in [board]. Use the URL with 'board init'.

OUTPUT
  Text: one board per line, tab-separated: id, name, URL.
  JSON: array of {id, name, url}

PLATFORM NOTES
  Linear: teams of the workspace.
  Jira: boards of the site.
  GitHub: projects of the owner in [board.target].
  GitLab: boards of the project in [board] url.

EXAMPLES
  board list
  board list --jq '.[].url'
EOF
}

cmd_list() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call board_list) || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_boards
}

help_view() {
    cat <<'EOF'
NAME
  board view - this board: columns and statuses

USAGE
  board view

DESCRIPTION
  Shows the board declared in [board]: its columns and the statuses in each.

OUTPUT
  Text: the name, then one column per line with its statuses.
  JSON: {id, name, kind, url, columns[{name, statuses[]}], statuses[{id, name, category}]}

PLATFORM NOTES
  Linear, GitHub: a column is a status.
  Jira: a column may hold several statuses.
  GitLab: the columns are the lists of the board, and the implicit Open and Closed are not shown.

EXAMPLES
  board view
  board view --jq '.columns[].name'
EOF
}

cmd_view() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call board_view) || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_board
}

# --- doctor -------------------------------------------------------------------------------

help_doctor() {
    cat <<'EOF'
NAME
  board doctor - check tools, the declaration and login

USAGE
  board doctor

DESCRIPTION
  One call that says whether board can work here: the tools it needs, the [board] declaration, the
  login, and what would make results wrong, such as a status with no category. Run it first.

OUTPUT
  Text: one finding per line.
  JSON: {version, ok, file, kind, url, authenticated, user, tools{<name>: bool},
         warnings[], errors[]}
  Exit 1 when ok is false: errors says why. A warning does not stop board from working.

PLATFORM NOTES
  GitHub: warns about project workflows that change a status or close an issue on their own.

EXAMPLES
  board doctor
  board doctor --jq .errors
EOF
}

cmd_doctor() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_d_version=$(tr -d '\r\n' <"$BOARD_HOME/VERSION")
    board_d_tools='{}'
    board_d_errors='[]'
    board_d_warnings='[]'
    for board_d_tool in jq curl; do
        board_d_has=false
        if command -v "$board_d_tool" >/dev/null 2>&1; then
            board_d_has=true
        fi
        board_d_tools=$(printf '%s' "$board_d_tools" | _jq -c --arg t "$board_d_tool" --argjson h "$board_d_has" '. + {($t): $h}')
    done
    board_d_kind='' board_d_url='' board_d_file='' board_d_auth='{}'
    if board_d_found=$(board_config_find 2>/dev/null); then
        board_d_file=$board_d_found
    fi
    if board_d_problem=$( (board_config_load) 2>&1); then
        board_config_load
        board_d_url=$BOARD_URL
        board_d_kind=$(board_config_get .kind)
        if [ -n "$BOARD_CLI" ]; then
            board_d_has=false
            if command -v "$BOARD_CLI" >/dev/null 2>&1; then
                board_d_has=true
            fi
            board_d_tools=$(printf '%s' "$board_d_tools" | _jq -c --arg t "$BOARD_CLI" --argjson h "$board_d_has" '. + {($t): $h}')
        fi
        board_d_status=0
        board_d_auth=$( (board_call auth_status) 2>"$BOARD_TMP/doctor.err") || board_d_status=$?
        if [ "$board_d_status" -ne 0 ]; then
            board_d_errors=$(printf '%s' "$board_d_errors" | _jq -c --arg e "login: $(sed -n 1p "$BOARD_TMP/doctor.err")" '. + [$e]')
            board_d_auth='{}'
        else
            if board_d_checks=$( (board_call doctor_checks) 2>"$BOARD_TMP/doctor.err"); then
                board_d_warnings=$(printf '%s' "$board_d_checks" | _jq -c '.warnings')
                board_d_errors=$(printf '%s\n%s\n' "$board_d_errors" "$board_d_checks" | _jq -sc '.[0] + .[1].errors')
            else
                board_d_errors=$(printf '%s' "$board_d_errors" | _jq -c --arg e "checks did not run: $(sed -n 1p "$BOARD_TMP/doctor.err")" '. + [$e]')
            fi
        fi
    else
        board_d_problem=$(printf '%s' "$board_d_problem" | sed -n 1p)
        board_d_errors=$(printf '%s' "$board_d_errors" | _jq -c --arg e "$board_d_problem" '. + [$e]')
    fi
    board_d_doc=$(printf '%s' "$board_d_auth" | _jq -c --arg version "$board_d_version" --arg file "$board_d_file" \
        --arg kind "$board_d_kind" --arg url "$board_d_url" --argjson tools "$board_d_tools" \
        --argjson errors "$board_d_errors" --argjson warnings "$board_d_warnings" '
        include "jq/common";
        ($errors + [$tools | to_entries[] | select(.value | not) | "tool \(.key) is missing"]) as $all
        | {version: $version,
           ok: ($all == [] and (.authenticated // false)),
           file: ($file | nullify), kind: ($kind | nullify), url: ($url | nullify),
           authenticated: (.authenticated // false), user: (.user // null),
           tools: $tools, warnings: $warnings, errors: $all}')
    printf '%s\n' "$board_d_doc" | board_output text_doctor
    printf '%s' "$board_d_doc" | _jq -e .ok >/dev/null || exit "$BOARD_EXIT_ERROR"
}

# --- capabilities -------------------------------------------------------------------------

help_capabilities() {
    cat <<'EOF'
NAME
  board capabilities - what this board can and cannot do

USAGE
  board capabilities

DESCRIPTION
  Lists the commands that work on the board declared in [board], and those that exit 3 with the
  reason. Ask this instead of trying a command to see if it fails. Some limits depend on the plan
  or the project, and those show up as exit 3 from the command itself.

OUTPUT
  Text: the two lists.
  JSON: {kind, supported[], unsupported[{command, reason}]}

EXAMPLES
  board capabilities --json
  board capabilities --jq '.unsupported[].command'
EOF
}

cmd_capabilities() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_config_load
    board_capabilities_json | board_output text_capabilities
}

# --- auth ---------------------------------------------------------------------------------

help_auth() {
    cat <<'EOF'
board auth - login state

board does not log in by itself: each board keeps the login of its own tool. Log in with that tool,
or for Jira set JIRA_API_TOKEN.

COMMANDS
  status    Show whether the login works

Run 'board auth <command> --help' for details.
EOF
}

help_auth_status() {
    cat <<'EOF'
NAME
  board auth status - show whether the login works

USAGE
  board auth status

DESCRIPTION
  Asks the board who the login belongs to. Exit 5 when there is no working login.

OUTPUT
  Text: one line.
  JSON: {kind, host, authenticated, user}

PLATFORM NOTES
  Linear: log in with 'linear auth login', or set LINEAR_API_KEY.
  Jira: needs login and server in the jira-cli config, and JIRA_API_TOKEN or ~/.netrc. The host of
        [board] url must equal the server there, so a file in a repository cannot send your token
        somewhere else.
  GitHub: log in with 'gh auth login'. The project scope is required.
  GitLab: log in with 'glab auth login --hostname <host>'.
  GitHub, GitLab: a host other than github.com or gitlab.com must be in BOARD_TRUSTED_HOSTS, a
        space-separated list in your environment, or exit 5: the host comes with a repository, and
        a token in your environment would go to it.

EXAMPLES
  board auth status
  board auth status --jq .user
EOF
}

cmd_auth_status() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call auth_status) || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_auth
}

# --- api ----------------------------------------------------------------------------------

help_api() {
    cat <<'EOF'
NAME
  board api - call the board's own API

USAGE
  board api <args...>

DESCRIPTION
  Passes the arguments to the board's tool, with the host of [board] filled in, and prints its
  answer unchanged. For what no command covers. What it prints is not normalised, so a call made
  here will not carry over to another board. A body is read from stdin.

ARGUMENTS
  <args...>   Linear: the query, or - for stdin
              Jira: METHOD and path
              GitHub: the arguments of 'gh api'
              GitLab: the arguments of 'glab api'

OUTPUT
  Text: the answer as the board gives it.
  JSON: the same; --jq filters it.

EXAMPLES
  board api '{ viewer { id } }'
  board api GET /rest/api/2/myself
  board api repos/bifenbecker/board-cli/labels
  board api projects/88364440/boards
EOF
}

cmd_api() {
    [ $# -gt 0 ] || board_usage_die "<args...> are required"
    if [ -n "${BOARD_JQ:-}" ]; then
        board_doc=$(board_call api_call "$@") || board_fail "$?" "$board_doc"
        printf '%s\n' "$board_doc" | board_output .
    else
        board_call api_call "$@" || exit $?
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

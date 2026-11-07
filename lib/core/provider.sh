# shellcheck shell=sh

# One adapter per board kind under lib/<kind>/. A command in lib/cmd calls board_call with a name
# from lib/contract.txt, and the adapter's function of that name, <kind>_<name>, does the work.

BOARD_LOADED_GROUPS=

# The model and this board's .jq files, prepended to an adapter's filters, shape.jq last. Not an
# include inside shape.jq: jq 1.8.0 aborts on a function an included module gets from another include.
board_lib_load() {
    [ -z "${BOARD_LIB:-}" ] || return 0
    set -- "$BOARD_HOME/lib/jq/common.jq"
    for board_ll_file in "$BOARD_HOME/lib/$BOARD_KIND"/*.jq; do
        case $board_ll_file in
            */shape.jq) ;;
            *) set -- "$@" "$board_ll_file" ;;
        esac
    done
    BOARD_LIB=$(cat "$@" "$BOARD_HOME/lib/$BOARD_KIND/shape.jq")
}

board_provider_load() {
    board_lib_load
    board_pl_file=$BOARD_HOME/lib/$BOARD_KIND/$1.sh
    case " $BOARD_LOADED_GROUPS " in
        *" $1 "*) return 0 ;;
    esac
    if [ -f "$board_pl_file" ]; then
        . "$board_pl_file"
    fi
    BOARD_LOADED_GROUPS="$BOARD_LOADED_GROUPS $1"
}

# Prints why this board does not do <name>, from lib/<kind>/unsupported.txt. Empty when it does.
board_unsupported_reason() {
    board_ur_file=$BOARD_HOME/lib/$BOARD_KIND/unsupported.txt
    [ -f "$board_ur_file" ] || return 0
    awk -v name="$1" '$1 == name { sub(/^[^ \t]+[ \t]+/, ""); print; exit }' "$board_ur_file"
}

# Usage: board_call <name> [args...]
# The adapter reads intent JSON from stdin where the command has one, prints normalised JSON and
# returns a board exit code.
board_call() {
    board_call_name=$1
    shift
    board_config_load
    # Decided here alone: a value inherited from the environment would turn a read into exit 6.
    BOARD_WRITE=''
    BOARD_WRITE_ID=''
    case $board_call_name in
        *_create | *_edit | *_move | *_close | *_reopen | *_delete | *_add | *_remove | *_rename) BOARD_WRITE=1 ;;
    esac
    # Exit 6 promises an id, and these calls know theirs before they start.
    case $board_call_name in
        issue_edit | issue_move | issue_close | issue_reopen | issue_link_add | issue_link_remove) BOARD_WRITE_ID=${1:-} ;;
    esac
    board_provider_load core
    board_provider_load "${board_call_name%%_*}"
    if board_fn_exists "${BOARD_KIND}_env"; then
        "${BOARD_KIND}_env"
    fi
    if ! board_fn_exists "${BOARD_KIND}_$board_call_name"; then
        board_call_why=$(board_unsupported_reason "$board_call_name")
        board_warn "board ${BOARD_PATH:-$board_call_name} is not supported on $BOARD_KIND${board_call_why:+: $board_call_why}"
        exit "$BOARD_EXIT_UNSUPPORTED"
    fi
    if [ -n "$BOARD_WRITE" ] && board_dry_run; then
        board_plan "$board_call_name" "$@"
        return $?
    fi
    "${BOARD_KIND}_$board_call_name" "$@"
}

# What a write would do, read and checked as far as the core can without writing:
# {dry_run, command, args, intent, issue, status}. Intent and issue go through stdin: a body can
# be longer than argv allows, and a native jq cannot open a temporary path.
# Usage: board_plan <name> [args...]
board_plan() {
    board_pn_name=$1
    shift
    case $board_pn_name in
        issue_create | issue_edit | issue_comment_add | issue_comment_edit | label_create | label_edit | label_sync | milestone_create | milestone_edit)
            _jq -c . >"$BOARD_TMP/plan.intent" || board_usage_die "the intent is not JSON"
            ;;
        *) printf 'null\n' >"$BOARD_TMP/plan.intent" ;;
    esac
    case $board_pn_name in
        issue_create | issue_list) printf 'null\n' >"$BOARD_TMP/plan.issue" ;;
        issue_*)
            board_pn_issue=$(board_call issue_view "$1") || return $?
            printf '%s\n' "$board_pn_issue" >"$BOARD_TMP/plan.issue"
            ;;
        *) printf 'null\n' >"$BOARD_TMP/plan.issue" ;;
    esac
    case $board_pn_name in
        issue_move) board_pn_status=$(board_plan_status name "$2") || return $? ;;
        # An issue already open, or already closed for this reason, stays where it is.
        issue_reopen)
            board_pn_now=$(_jq -r '.status.category // ""' <"$BOARD_TMP/plan.issue")
            if [ -n "${2:-}" ]; then
                board_pn_status=$(board_plan_status name "$2") || return $?
            elif [ "$board_pn_now" != done ] && [ "$board_pn_now" != canceled ]; then
                board_pn_status=$(_jq -c .status <"$BOARD_TMP/plan.issue")
            else
                board_pn_status=$(board_plan_status category todo) || return $?
            fi
            ;;
        issue_close)
            if [ "$(_jq -r '.status.category // ""' <"$BOARD_TMP/plan.issue")" = "$2" ]; then
                board_pn_status=$(_jq -c .status <"$BOARD_TMP/plan.issue")
            else
                board_pn_status=$(board_plan_status category "$2") || return $?
            fi
            ;;
        issue_edit | issue_create)
            board_pn_want=$(_jq -r '.status // ""' <"$BOARD_TMP/plan.intent")
            board_pn_status=null
            if [ -n "$board_pn_want" ]; then
                board_pn_status=$(board_plan_status name "$board_pn_want") || return $?
            fi
            ;;
        *) board_pn_status=null ;;
    esac
    printf '%s\n' "$board_pn_status" >"$BOARD_TMP/plan.status"
    cat "$BOARD_TMP/plan.intent" "$BOARD_TMP/plan.issue" "$BOARD_TMP/plan.status" |
        _jq -sc --arg command "${BOARD_PATH:-$board_pn_name}" \
            '{dry_run: true, command: $command, args: $ARGS.positional, intent: .[0], issue: .[1],
              status: .[2]}' --args "$@"
}

# The status a write would reach, as {name, category}, or null. By name, it must be there: a name
# nothing has is exit 2, as the write would be, and so is one that two statuses share. By
# category, the first of it, or null when there is none.
# Usage: board_plan_status name|category <value>
board_plan_status() {
    board_ps_list=$(board_call status_list) || return $?
    if [ "$1" = category ]; then
        printf '%s' "$board_ps_list" | _jq -c --arg c "$2" '[.[] | select(.category == $c) | {name, category}] | first // null'
        return 0
    fi
    board_ps_found=$(printf '%s' "$board_ps_list" | _jq -c --arg s "$2" 'include "jq/common";
        [.[] | select(.id == $s or (.name | ieq($s))) | {name, category}]')
    case $board_ps_found in
        '[]') board_usage_die "no status '$2'. Valid: $(printf '%s' "$board_ps_list" | _jq -r '[.[].name] | join(", ")')" ;;
        '[{'*'},{'*) board_usage_die "'$2' names more than one status: pass its id from 'board status list --json'" ;;
    esac
    printf '%s' "$board_ps_found" | _jq -c '.[0]'
}

# Which board a URL belongs to, or nothing when its host does not say.
board_kind_of_url() {
    board_ku_host=${1#*://}
    board_ku_host=${board_ku_host%%/*}
    case $board_ku_host in
        linear.app) printf linear ;;
        *.atlassian.net | jira.*) printf jira ;;
        github.com | *.ghe.com) printf github ;;
        gitlab.* | *.gitlab.*) printf gitlab ;;
    esac
}

# board_call for 'board init', which runs before there is a declaration: BOARD_KIND comes from
# the URL, and the adapter is told the rest.
# Usage: board_call_kind <name> [args...]
board_call_kind() {
    board_ck_name=$1
    shift
    BOARD_CONFIG_JSON='{}'
    board_provider_load core
    board_provider_load "${board_ck_name%%_*}"
    if board_fn_exists "${BOARD_KIND}_env"; then
        "${BOARD_KIND}_env"
    fi
    board_fn_exists "${BOARD_KIND}_$board_ck_name" || board_unsupported "board init"
    "${BOARD_KIND}_$board_ck_name" "$@"
}

# Sets BOARD_KIND for 'board init': the --kind given, or what the URL says.
# Usage: board_kind_select <kind|""> <url>
board_kind_select() {
    if [ -n "$1" ]; then
        board_require_one_of --kind "$1" linear jira github gitlab
        BOARD_KIND=$1
    else
        BOARD_KIND=$(board_kind_of_url "$2")
    fi
    [ -n "$BOARD_KIND" ] || board_usage_die "cannot tell the board from this URL: pass --kind"
}

# The commands of lib/contract.txt, split by lib/<kind>/unsupported.txt.
board_capabilities_json() {
    awk -v kind="$BOARD_KIND" -v outfile="$BOARD_HOME/lib/$BOARD_KIND/unsupported.txt" '
        function str(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
        BEGIN {
            while ((getline line < outfile) > 0) {
                n = line; sub(/[ \t].*/, "", n)
                r = line; sub(/^[^ \t]+[ \t]+/, "", r)
                if (n != "") why[n] = r
            }
        }
        {
            n = $1; c = $0; sub(/^[^ \t]+[ \t]+/, "", c)
            if (n in why) out = out (out == "" ? "" : ",") "{\"command\":" str(c) ",\"reason\":" str(why[n]) "}"
            else ok = ok (ok == "" ? "" : ",") str(c)
        }
        END { printf "{\"kind\":%s,\"supported\":[%s],\"unsupported\":[%s]}\n", str(kind), ok, out }
    ' "$BOARD_HOME/lib/contract.txt"
}

# Whether this board's work goes through [board] cli. Jira is reached over curl: its cli stays
# declared for the rest of a project's tooling, and board never runs it.
board_cli_needed() {
    [ -n "$BOARD_CLI" ] && [ "$BOARD_KIND" != jira ]
}

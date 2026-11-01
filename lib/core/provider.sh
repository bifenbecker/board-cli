# shellcheck shell=sh

# One adapter per board kind under lib/<kind>/. A command in lib/cmd calls board_call with a name
# from lib/contract.txt, and the adapter's function of that name, <kind>_<name>, does the work.

BOARD_LOADED_GROUPS=

# The model and this board's shapes, prepended to an adapter's filters. Not an include inside
# shape.jq: jq 1.8.0 aborts on a function that an included module gets from another include.
board_lib_load() {
    [ -z "${BOARD_LIB:-}" ] || return 0
    BOARD_LIB=$(cat "$BOARD_HOME/lib/jq/common.jq" "$BOARD_HOME/lib/$BOARD_KIND/shape.jq")
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
    case $board_call_name in
        *_create | *_edit | *_move | *_close | *_reopen | *_delete | *_add | *_remove | *_rename) BOARD_WRITE=1 ;;
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
    "${BOARD_KIND}_$board_call_name" "$@"
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

# shellcheck shell=sh

# One adapter per board kind under lib/<kind>/. A command in lib/cmd calls board_call with a name
# from lib/contract.txt, and the adapter's function of that name, <kind>_<name>, does the work.

BOARD_LOADED_GROUPS=

board_provider_load() {
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
    board_provider_load core
    board_provider_load "${board_call_name%%_*}"
    if ! board_fn_exists "${BOARD_KIND}_$board_call_name"; then
        board_call_why=$(board_unsupported_reason "$board_call_name")
        board_unsupported "board ${BOARD_PATH:-$board_call_name}${board_call_why:+: $board_call_why}; it is not supported on $BOARD_KIND"
    fi
    "${BOARD_KIND}_$board_call_name" "$@"
}

# shellcheck shell=sh

board_main() {
    BOARD_JSON=''
    BOARD_JQ=''
    BOARD_HELP=''
    BOARD_PATH=''
    BOARD_GROUP=''
    BOARD_BODY=''
    BOARD_BODY_SET=''
    BOARD_SHOW_VERSION=''

    # Pull global flags out of the argument list, wherever they are. The list is rotated:
    # each argument is shifted off the front and, unless it is global, appended to the back.
    # A value that equals a global flag must be written --flag=value; split pieces are not rescanned.
    board_n=$#
    board_kept=0
    while [ "$board_n" -gt 0 ]; do
        board_a=$1
        shift
        board_n=$((board_n - 1))
        case $board_a in
            --)
                while [ "$board_n" -gt 0 ]; do
                    set -- "$@" "$1"
                    shift
                    board_n=$((board_n - 1))
                done
                ;;
            --json) BOARD_JSON=1 ;;
            --jq)
                [ "$board_n" -gt 0 ] || board_usage_die "--jq needs a value"
                BOARD_JQ=$1 BOARD_JSON=1
                shift
                board_n=$((board_n - 1))
                ;;
            --jq=*) BOARD_JQ=${board_a#--jq=} BOARD_JSON=1 ;;
            -h | --help) BOARD_HELP=1 ;;
            # Global only before the command: "board self update --version v1" is the command's flag.
            --version | -V)
                if [ "$board_kept" -eq 0 ]; then
                    BOARD_SHOW_VERSION=1
                else
                    set -- "$@" "$board_a"
                fi
                ;;
            --*=*) set -- "$@" "${board_a%%=*}" "${board_a#*=}" ;;
            *)
                set -- "$@" "$board_a"
                board_kept=$((board_kept + 1))
                ;;
        esac
    done

    board_dispatch "$@"
}

board_token_ok() {
    case $1 in
        '' | *[!a-z0-9-]* | -*) return 1 ;;
    esac
    return 0
}

board_fn_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Help and usage errors need no probes, so a call that ends here spawns nothing.
board_runtime_init() {
    board_jq_probe
    board_timeout_probe
    board_require jq
    board_tmp_init
}

board_dispatch() {
    if [ -n "$BOARD_SHOW_VERSION" ]; then
        cmd_version
        return 0
    fi
    if [ $# -eq 0 ]; then
        help_root
        return 0
    fi

    board_group=$1
    board_token_ok "$board_group" || board_usage_die "unknown command '$1'"
    if [ -f "$BOARD_HOME/lib/cmd/$board_group.sh" ]; then
        . "$BOARD_HOME/lib/cmd/$board_group.sh"
    fi
    board_node=$(printf '%s' "$board_group" | tr '-' '_')
    board_fn_exists "help_$board_node" || board_usage_die "unknown command '$1'"
    BOARD_GROUP=$board_group
    BOARD_PATH=$board_group
    shift

    while [ $# -gt 0 ] && board_token_ok "$1"; do
        board_next="${board_node}_$(printf '%s' "$1" | tr '-' '_')"
        board_fn_exists "help_$board_next" || break
        board_node=$board_next
        BOARD_PATH="$BOARD_PATH $1"
        shift
    done

    if [ -n "$BOARD_HELP" ]; then
        board_show_help "$board_node"
        return 0
    fi
    if board_fn_exists "cmd_$board_node"; then
        board_runtime_init
        # Read here so the $(board_call ...) of a command inherits it. These work without one.
        case $board_group in
            init | version | self | doctor) ;;
            *) board_config_load ;;
        esac
        "cmd_$board_node" "$@"
        return
    fi
    if [ $# -gt 0 ]; then
        board_usage_die "unknown command 'board $BOARD_PATH $1'"
    fi
    board_show_help "$board_node"
}

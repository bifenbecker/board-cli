# shellcheck shell=sh

# Command help is NAME, USAGE, DESCRIPTION, [ARGUMENTS], [FLAGS], OUTPUT, [PLATFORM NOTES],
# EXAMPLES, written by the command. EXIT CODES and GLOBAL FLAGS are appended here.
BOARD_HELP_SECTIONS='NAME USAGE DESCRIPTION OUTPUT EXAMPLES'

board_show_help() {
    "help_$1"
    if board_fn_exists "cmd_$1"; then
        cat <<'EOF'

EXIT CODES
  0  success
  1  the board or a tool failed
  2  wrong usage: unknown flag, missing argument, no [board] section
  3  not supported on this board
  4  not found
  5  not authenticated, or the token may not do this
  6  partial: a write went through and a later step failed. The id is on stdout. Do not repeat it
  7  conflict: the issue is not in the --from status. Nothing was written

GLOBAL FLAGS
  --json        Print the normalised JSON described under OUTPUT
  --jq <expr>   Filter that JSON with a jq expression (implies --json)
  -h, --help    Show this help
EOF
    fi
}

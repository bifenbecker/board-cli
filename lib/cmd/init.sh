# shellcheck shell=sh

help_init() {
    cat <<'EOF'
NAME
  board init - declare the board of this project from its URL

USAGE
  board init --url <board-url> [--kind <kind>] [--repo <owner/repo>] [--dry-run]

DESCRIPTION
  Reads the board behind a URL and writes [board] of workflow.toml, so every other command knows
  it. The file is created when missing. An existing file keeps everything it has: sections are
  only added, and when [board] already says something else, nothing is written and exit 2 prints
  the section to merge by hand.

  Statuses found on the board are written to [board.statuses] with a category guessed from their
  name. Check them: a status board could not place stays commented out, and 'board doctor' fails
  until it has a category.

FLAGS
  -u, --url <board-url>   The board as a browser shows it. Required
      --kind <kind>       linear, jira, github or gitlab. Needed for a self-hosted board, whose
                          host name does not say
      --repo <owner/repo> Repository for new issues. Required for a GitHub project URL
      --dry-run           Print what would be written and write nothing

OUTPUT
  Text: the path of the file, or with --dry-run the section.
  JSON: {file, written, section}

PLATFORM NOTES
  Linear: a project URL narrows the board to that project.
  Jira: the host must equal server in the jira-cli config.

EXAMPLES
  board init --url https://linear.app/3kd/project/test-982b67e1e776/overview
  board init --url https://work-40585442.atlassian.net/jira/software/projects/KAN/boards/1
  board init --url https://github.com/users/bifenbecker/projects/5 --repo bifenbecker/board-cli
  board init --url https://gitlab.com/bulgakovra.w/test-board-cli/-/boards --dry-run
EOF
}

# The TOML of a discovered board. Input: the adapter's {board{}, target{}, statuses{}, unplaced[]}.
init_section() {
    _jq -r '
        def q: tojson;
        def toml_key: if test("^[A-Za-z0-9_-]+$") then . else tojson end;
        def table($name; $t): if ($t | length) > 0
            then "\n[board.\($name)]", ($t | to_entries[] | "\(.key | toml_key) = \(.value | tojson)")
            else empty end;
        "[board]",
        (.board | to_entries[] | "\(.key) = \(.value | q)"),
        table("target"; .target // {}),
        (if ((.statuses // {}) | length) > 0 or ((.unplaced // []) | length) > 0 then
            "\n[board.statuses]",
            ((.statuses // {}) | to_entries[] | "\(.key | toml_key) = \(.value | q)"),
            ((.unplaced // [])[] | "# \(. | toml_key) = \"\"  # todo, in_progress, done or canceled?")
         else empty end)'
}

# Prints the subsections of the discovered board that the file lacks.
init_missing_sections() {
    init_ms_have=$1
    printf '%s' "$init_doc" | _jq -c --argjson have "$init_ms_have" '
        {board: {}} + (if $have.target then {} else {target} end)
        + (if $have.statuses then {} else {statuses, unplaced} end)' | init_section | sed '1d'
}

cmd_init() {
    opt_url='' opt_kind='' opt_repo='' opt_dry_run=''
    while [ $# -gt 0 ]; do
        case $1 in
            -u | --url) board_arg "$@"; opt_url=$2; shift 2 ;;
            --kind) board_arg "$@"; opt_kind=$2; shift 2 ;;
            --repo) board_arg "$@"; opt_repo=$2; shift 2 ;;
            --dry-run) opt_dry_run=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *) board_unexpected "$1" ;;
        esac
    done
    [ -n "$opt_url" ] || board_usage_die "--url is required"
    case $opt_url in
        http://* | https://*) ;;
        *) board_usage_die "--url must start with http:// or https://, got '$opt_url'" ;;
    esac
    board_kind_select "$opt_kind" "$opt_url"

    init_doc=$(board_call_kind init_discover "$opt_url" "$opt_repo") || exit $?
    init_text=$(printf '%s' "$init_doc" | init_section)

    if init_file=$(board_config_find 2>/dev/null); then
        :
    else
        init_file=workflow.toml
    fi
    init_written=true
    if [ -n "$opt_dry_run" ]; then
        init_written=false
    elif [ ! -f "$init_file" ]; then
        printf '%s\n' "$init_text" >"$init_file"
    else
        init_have=$(board_toml_to_json <"$init_file")
        init_conflict=$(printf '%s\n%s\n' "$init_have" "$init_doc" | _jq -sr '
            .[0] as $have | .[1].board | to_entries
            | map(select($have[.key] != null and $have[.key] != .value) | .key) | join(", ")')
        if [ -n "$init_conflict" ]; then
            printf '%s\n' "$init_text"
            board_usage_die "$init_file declares another board ($init_conflict): nothing written, merge the section above by hand"
        fi
        if printf '%s' "$init_have" | _jq -e 'has("kind")' >/dev/null; then
            init_extra=$(init_missing_sections "$init_have")
        else
            init_extra=$(printf '\n%s' "$init_text")
        fi
        if [ -n "$(printf '%s' "$init_extra" | tr -d '[:space:]')" ]; then
            printf '%s\n' "$init_extra" >>"$init_file"
        else
            init_written=false
        fi
    fi

    if board_json_mode; then
        _jq -n --arg file "$init_file" --argjson written "$init_written" --arg section "$init_text" \
            '{file: $file, written: $written, section: $section}' | board_output .
    elif [ -n "$opt_dry_run" ]; then
        printf '%s\n' "$init_text"
    else
        printf '%s\n' "$init_file"
    fi
}

# shellcheck shell=sh

help_init() {
    cat <<'EOF'
NAME
  board init - declare the board of this project from its URL

USAGE
  board init --url <board-url> [--kind <kind>] [--repo <owner/repo>] [--dry-run]

DESCRIPTION
  Reads the board behind a URL and writes [board] of workflow.toml in the working directory, or of
  WORKFLOW_FILE, so every other command knows it. The file is created when missing. An existing
  file keeps everything it has: sections are only added, and when [board] already says something
  else, nothing is written and exit 2 prints the section to merge by hand, on stderr.

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
  Jira: the host must be one you named outside the repository: the host of server in
        JIRA_CONFIG_FILE or ~/.config/.jira/.config.yml, or a host in BOARD_JIRA_HOSTS
        (space-separated). Anything else is exit 5 with no request made. Statuses keep Jira's own
        categories, so only one that reads as canceled is written to [board.statuses].

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

# True when the file has this section, whether or not it holds a key: a second one would make the
# file invalid TOML. Asks the parser, which also knows [ board ] and statuses.Todo = "todo".
init_has_section() {
    printf '%s' "$init_have" | _jq -e --arg s "$1" '._sections | index($s) != null' >/dev/null
}

# Prints the subsections of the discovered board that the file lacks.
init_missing_sections() {
    init_ms_target=false
    init_ms_statuses=false
    if init_has_section target; then init_ms_target=true; fi
    if init_has_section statuses; then init_ms_statuses=true; fi
    printf '%s' "$init_doc" | _jq -c --argjson t "$init_ms_target" --argjson s "$init_ms_statuses" '
        {board: {}} + (if $t then {} else {target} end) + (if $s then {} else {statuses, unplaced} end)' |
        init_section | sed '1d'
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

    init_doc=$(board_call_kind init_discover "$opt_url" "$opt_repo") || board_fail "$?" "$init_doc"
    [ -n "$init_doc" ] || board_die "the board gave no answer"
    init_text=$(printf '%s' "$init_doc" | init_section) || board_die "the board gave an answer that cannot be read"

    init_file=${WORKFLOW_FILE:-workflow.toml}
    init_have='{"_sections":[]}'
    init_extra=$(printf '%s' "$init_text")
    if [ -f "$init_file" ]; then
        init_have=$(board_toml_to_json <"$init_file") || board_usage_die "$init_file cannot be read: nothing written"
        init_conflict=$(printf '%s\n%s\n' "$init_have" "$init_doc" | _jq -sr '
            .[0] as $have | .[1].board | to_entries
            | map(select($have[.key] != null and $have[.key] != .value) | .key) | join(", ")')
        if [ -z "$init_conflict" ] && init_has_section '' &&
            ! printf '%s' "$init_have" | _jq -e '.kind and .url' >/dev/null; then
            init_conflict='it lacks kind or url'
        fi
        if [ -n "$init_conflict" ]; then
            printf '%s\n' "$init_text" >&2
            board_usage_die "$init_file declares another board ($init_conflict): nothing written, merge the section above by hand"
        fi
        if init_has_section ''; then
            init_extra=$(init_missing_sections)
        else
            init_extra=$(printf '\n%s' "$init_text")
        fi
    fi

    init_written=false
    if [ -z "$opt_dry_run" ] && [ -n "$(printf '%s' "$init_extra" | tr -d '[:space:]')" ]; then
        printf '%s\n' "$init_extra" >>"$init_file"
        init_written=true
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

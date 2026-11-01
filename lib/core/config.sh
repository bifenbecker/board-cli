# shellcheck shell=sh

# The board is declared in [board] of workflow.toml. Nothing is guessed from the environment: an
# identifier looks much the same on every board, and a git remote does not say which one a
# project keeps its tasks on.

# Prints the path of workflow.toml, from WORKFLOW_FILE or the nearest one at or above the cwd.
board_config_find() {
    if [ -n "${WORKFLOW_FILE:-}" ]; then
        [ -f "$WORKFLOW_FILE" ] || board_usage_die "WORKFLOW_FILE names no file: $WORKFLOW_FILE"
        printf '%s' "$WORKFLOW_FILE"
        return 0
    fi
    board_cf_dir=$(pwd)
    while :; do
        if [ -f "$board_cf_dir/workflow.toml" ]; then
            printf '%s' "$board_cf_dir/workflow.toml"
            return 0
        fi
        board_cf_up=${board_cf_dir%/*}
        [ -n "$board_cf_up" ] || board_cf_up=/
        [ "$board_cf_up" != "$board_cf_dir" ] || return 1
        board_cf_dir=$board_cf_up
    done
}

# Turns the [board] and [board.*] sections of the TOML on stdin into one JSON object. Other
# sections may hold anything, so they are skipped unread. Values stay on one line, the same
# rule as scripts/workflow.sh, which the rest of the project reads this file with.
board_toml_to_json() {
    awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function strip_comment(s,    out, i, c, q) {
        out = ""; q = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (q == "" && (c == "\"" || c == "\047")) q = c
            else if (c == q) q = ""
            else if (c == "#" && q == "") break
            out = out c
        }
        return trim(out)
    }
    function equals_at(s,    i, c, q) {
        q = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (q == "" && (c == "\"" || c == "\047")) q = c
            else if (c == q) q = ""
            else if (c == "=" && q == "") return i
        }
        return 0
    }
    function json_string(s) {
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
        return "\"" s "\""
    }
    function unquote(s) {
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
        return s
    }
    function value(v) {
        if (v ~ /^".*"$/) return v                       # TOML basic strings escape as JSON does
        if (v ~ /^\047.*\047$/) return json_string(substr(v, 2, length(v) - 2))
        if (v ~ /^-?[0-9]+$/ || v == "true" || v == "false") return v
        return json_string(v)
    }
    function add(sub_name, pair) {
        if (!(sub_name in body)) { order[++count] = sub_name; body[sub_name] = pair }
        else body[sub_name] = body[sub_name] "," pair
    }
    { line = trim($0) }
    line == "" || line ~ /^#/ { next }
    line ~ /^\[/ {
        section = strip_comment(line); gsub(/^\[+|\]+$/, "", section); section = trim(section)
        if (section == "board") { inside = 1; name = "" }
        else if (index(section, "board.") == 1) { inside = 1; name = substr(section, 7) }
        else inside = 0
        next
    }
    !inside { next }
    {
        at = equals_at(line)
        if (at == 0) next
        key = unquote(trim(substr(line, 1, at - 1)))
        add(name, json_string(key) ":" value(strip_comment(substr(line, at + 1))))
    }
    END {
        printf "{"
        printed = 0
        if ("" in body) { printf "%s", body[""]; printed = 1 }
        for (i = 1; i <= count; i++) {
            if (order[i] == "") continue
            if (printed) printf ","
            printf "%s:{%s}", json_string(order[i]), body[order[i]]
            printed = 1
        }
        print "}"
    }'
}

# Loads the declaration into BOARD_KIND, BOARD_CLI, BOARD_URL, BOARD_PROJECT, BOARD_ISSUE_URI,
# BOARD_CLI_CONFIG (absolute), BOARD_ROOT and BOARD_CONFIG_JSON.
board_config_load() {
    [ -z "${BOARD_CONFIG_LOADED:-}" ] || return 0
    BOARD_CONFIG_FILE=$(board_config_find) ||
        board_usage_die "no workflow.toml here or above; run 'board init --url <board-url>'"
    BOARD_CONFIG_JSON=$(board_toml_to_json <"$BOARD_CONFIG_FILE") ||
        board_die "cannot read $BOARD_CONFIG_FILE"
    printf '%s' "$BOARD_CONFIG_JSON" | _jq -e . >/dev/null 2>&1 ||
        board_usage_die "[board] in $BOARD_CONFIG_FILE is not valid: check its quoting"
    # @sh quotes every value, so the file's content cannot run as code here.
    eval "$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -r '
        @sh "BOARD_KIND=\(.kind // "") BOARD_CLI=\(.cli // "") BOARD_URL=\(.url // "") BOARD_PROJECT=\(.project // "") BOARD_ISSUE_URI=\(.issue_uri // "") BOARD_CLI_CONFIG=\(.config // "")"')"
    case $BOARD_KIND in
        linear | jira | github | gitlab) ;;
        '') board_usage_die "no [board] kind in $BOARD_CONFIG_FILE; run 'board init --url <board-url>'" ;;
        *) board_usage_die "unknown [board] kind '$BOARD_KIND' in $BOARD_CONFIG_FILE: expected linear, jira, github or gitlab" ;;
    esac
    # workflow.toml comes with a repository, and a repository must not choose what runs here.
    case $BOARD_KIND:$BOARD_CLI in
        linear: | linear:linear | jira: | jira:jira | github: | github:gh | gitlab: | gitlab:glab) ;;
        *) board_usage_die "[board] cli '$BOARD_CLI' is not the tool of a $BOARD_KIND board: remove it, or set the usual one" ;;
    esac
    [ -n "$BOARD_URL" ] || board_usage_die "no [board] url in $BOARD_CONFIG_FILE"
    case $BOARD_CONFIG_FILE in
        */*) BOARD_ROOT=${BOARD_CONFIG_FILE%/*} ;;
        *) BOARD_ROOT=. ;;
    esac
    case $BOARD_CLI_CONFIG in
        '' | /* | [A-Za-z]:*) ;;
        *) BOARD_CLI_CONFIG=$BOARD_ROOT/$BOARD_CLI_CONFIG ;;
    esac
    BOARD_HOST=${BOARD_URL#*://}
    BOARD_HOST=${BOARD_HOST%%/*}
    BOARD_CONFIG_LOADED=1
}

# Reads one key of a [board.<section>] table, or "" when absent.
# Usage: board_config_get <jq path, e.g. .target.number>
board_config_get() {
    printf '%s' "$BOARD_CONFIG_JSON" | _jq -r "($1) // empty"
}

# shellcheck shell=sh

# The board is declared in [board] of workflow.toml. Nothing is guessed from the environment: an
# identifier looks much the same on every board, and a git remote does not say which one a
# project keeps its tasks on.

# Prints the path of workflow.toml, from WORKFLOW_FILE or the nearest one at or above the cwd.
board_config_find() {
    if [ -n "${WORKFLOW_FILE:-}" ]; then
        WORKFLOW_FILE=$(printf '%s' "$WORKFLOW_FILE" | tr '\134' '/')
        [ -f "$WORKFLOW_FILE" ] || return 1
        printf '%s' "$WORKFLOW_FILE"
        return 0
    fi
    board_cf_dir=$(pwd)
    while :; do
        if [ -f "${board_cf_dir%/}/workflow.toml" ]; then
            printf '%s' "${board_cf_dir%/}/workflow.toml"
            return 0
        fi
        board_cf_up=${board_cf_dir%/*}
        [ -n "$board_cf_up" ] || board_cf_up=/
        [ "$board_cf_up" != "$board_cf_dir" ] || return 1
        board_cf_dir=$board_cf_up
    done
}

# Turns the [board] and [board.*] sections of the TOML on stdin into one JSON object. Other
# sections may hold anything, so they are skipped. Values stay on one line, the same rule as
# scripts/workflow.sh, and anything else in [board] is refused rather than misread. _sections lists
# the sections seen, keys or not.
board_toml_to_json() {
    awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function fail(msg) { printf "board: line %d: %s\n", NR, msg > "/dev/stderr"; failed = 1; exit 3 }
    # Walks a line outside its strings. A backslash escapes the next character in a basic string.
    function scan(s, stop_at,    i, c, q, out) {
        out = ""; q = ""; found_at = 0
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (q == "\"" && c == "\\") { out = out c substr(s, i + 1, 1); i++; continue }
            if (q == "" && (c == "\"" || c == "\047")) q = c
            else if (c == q) q = ""
            else if (q == "" && c == stop_at) { found_at = i; break }
            out = out c
        }
        return out
    }
    function strip_comment(s) { return trim(scan(s, "#")) }
    function equals_at(s) { scan(s, "="); return found_at }
    function json_string(s) {
        gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s)
        return "\"" s "\""
    }
    function unquote(s) {
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
        return s
    }
    # One complete basic string: its closing quote is the last character, unescaped.
    function is_basic(v,    i, c) {
        if (length(v) < 2 || substr(v, 1, 1) != "\"") return 0
        for (i = 2; i < length(v); i++) {
            c = substr(v, i, 1)
            if (c == "\\") { i++; continue }
            if (c == "\"") return 0
        }
        return i == length(v) && substr(v, i, 1) == "\""
    }
    function value(v) {
        if (is_basic(v)) return v                        # TOML basic strings escape as JSON does
        if (v ~ /^\047[^\047]*\047$/) return json_string(substr(v, 2, length(v) - 2))
        if (v ~ /^-?[0-9]+$/ || v == "true" || v == "false") return v
        fail("a [board] value must be one string, number or boolean: " v)
    }
    function add(sub_name, key, val,    pair, id) {
        id = sub_name SUBSEP key
        if (id in seen) fail("key " key " is set twice")
        seen[id] = 1
        pair = json_string(key) ":" val
        if (!(sub_name in body)) { order[++count] = sub_name; body[sub_name] = pair }
        else body[sub_name] = body[sub_name] "," pair
    }
    function mark(sub_name) {
        if (!(sub_name in marked)) { marked[sub_name] = 1; sections[++section_count] = sub_name }
    }
    function count_of(s, pattern,    t) { t = s; return gsub(pattern, "", t) }
    NR == 1 { sub(/^\357\273\277/, "") }
    { line = trim($0) }
    # A multi-line string may hold anything, a line that looks like [board] included.
    multi != "" {
        if (count_of(line, multi) % 2 == 1) multi = ""
        next
    }
    line == "" || line ~ /^#/ { next }
    line ~ /^\[\[/ { inside = 0; next }
    line ~ /^\[/ {
        section = strip_comment(line); gsub(/^\[|\]$/, "", section); gsub(/[ \t]/, "", section)
        if (section == "board") { inside = 1; name = ""; mark("") }
        else if (index(section, "board.") == 1) { inside = 1; name = substr(section, 7); mark(name) }
        else inside = 0
        next
    }
    {
        if (count_of(line, "\"\"\"") % 2 == 1) { multi = "\"\"\""; if (!inside) next; fail("multi-line strings are not supported in [board]") }
        if (count_of(line, "\047\047\047") % 2 == 1) { multi = "\047\047\047"; if (!inside) next; fail("multi-line strings are not supported in [board]") }
    }
    !inside { next }
    {
        at = equals_at(line)
        if (at == 0) next
        raw = trim(substr(line, 1, at - 1))
        key = unquote(raw)
        target = name
        # statuses.Todo = "todo" under [board] is the same as a key of [board.statuses].
        if (raw !~ /^["\047]/ && index(raw, ".") > 0 && name == "") {
            target = substr(raw, 1, index(raw, ".") - 1)
            key = unquote(substr(raw, index(raw, ".") + 1))
            mark(target)
        }
        add(target, key, value(strip_comment(substr(line, at + 1))))
    }
    END {
        if (failed) exit 3
        printf "{"
        printed = 0
        if ("" in body) { printf "%s", body[""]; printed = 1 }
        for (i = 1; i <= section_count; i++) {
            if (sections[i] == "") continue
            if (printed) printf ","
            printf "%s:{%s}", json_string(sections[i]), body[sections[i]]
            printed = 1
        }
        if (printed) printf ","
        printf "\"_sections\":["
        for (i = 1; i <= section_count; i++) printf "%s%s", (i > 1 ? "," : ""), json_string(sections[i])
        print "]}"
    }'
}

# Loads the declaration into BOARD_KIND, BOARD_CLI, BOARD_URL, BOARD_HOST, BOARD_PROJECT,
# BOARD_ISSUE_URI, BOARD_CLI_CONFIG (absolute), BOARD_ROOT and BOARD_CONFIG_JSON.
board_config_load() {
    [ -z "${BOARD_CONFIG_LOADED:-}" ] || return 0
    BOARD_CONFIG_FILE=$(board_config_find) ||
        board_usage_die "no ${WORKFLOW_FILE:-workflow.toml here or above}; run 'board init --url <board-url>'"
    BOARD_CONFIG_JSON=$(board_toml_to_json <"$BOARD_CONFIG_FILE") ||
        board_usage_die "[board] in $BOARD_CONFIG_FILE cannot be read"
    # Only strings reach the eval: @sh renders an array as separate words, which would run.
    board_cl_vars=$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -r '
        def s($k): .[$k] // "" | if type == "object" or type == "array" then error("\($k) is not a value") else tostring end;
        @sh "BOARD_KIND=\(s("kind")) BOARD_CLI=\(s("cli")) BOARD_URL=\(s("url")) BOARD_PROJECT=\(s("project")) BOARD_ISSUE_URI=\(s("issue_uri")) BOARD_CLI_CONFIG=\(s("config"))"' 2>/dev/null) ||
        board_usage_die "[board] in $BOARD_CONFIG_FILE is not valid"
    eval "$board_cl_vars"
    BOARD_CONFIG_JSON=$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -c 'del(._sections)')
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
    case $BOARD_URL in
        http://* | https://*) ;;
        *) board_usage_die "[board] url must start with http:// or https://, got '$BOARD_URL'" ;;
    esac
    BOARD_HOST=${BOARD_URL#*://}
    BOARD_HOST=${BOARD_HOST%%/*}
    # A userinfo part would pass the checks made on the host and send requests elsewhere.
    case $BOARD_HOST in
        '' | *[!A-Za-z0-9.:-]*) board_usage_die "[board] url has a bad host: '$BOARD_HOST'" ;;
    esac
    case $BOARD_CONFIG_FILE in
        */*) BOARD_ROOT=${BOARD_CONFIG_FILE%/*} ;;
        *) BOARD_ROOT=. ;;
    esac
    case $BOARD_CLI_CONFIG in
        '' | /* | [A-Za-z]:*) ;;
        \~/*) BOARD_CLI_CONFIG=$HOME/${BOARD_CLI_CONFIG#\~/} ;;
        *) BOARD_CLI_CONFIG=$BOARD_ROOT/$BOARD_CLI_CONFIG ;;
    esac
    BOARD_CONFIG_LOADED=1
}

# The host in [board] url comes with a repository, and gh and glab send a token from the environment
# (GH_ENTERPRISE_TOKEN, GITLAB_TOKEN) to whatever host they are told. So a host other than the
# service's own must be named by the user, outside any repository.
# Usage: board_require_trusted_host <the service's own host>
board_require_trusted_host() {
    [ "$BOARD_HOST" != "$1" ] || return 0
    case " ${BOARD_TRUSTED_HOSTS:-} " in
        *" $BOARD_HOST "*) return 0 ;;
    esac
    board_auth_die "host $BOARD_HOST comes from workflow.toml and is not trusted: add it to BOARD_TRUSTED_HOSTS"
}

# Reads one key of a [board.<section>] table, or "" when absent.
# Usage: board_config_get <jq path, e.g. .target.number>
board_config_get() {
    printf '%s' "$BOARD_CONFIG_JSON" | _jq -r "($1) // empty"
}

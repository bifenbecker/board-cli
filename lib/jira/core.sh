# shellcheck shell=sh

# Jira adapter: REST v2 over curl, on Cloud and Data Center. jira-cli is not called: it has no raw
# API and hides failures behind "No result found". Only its config file is read.

JIRA_FIELDS=summary,description,issuetype,status,assignee,labels,priority,parent,subtasks,issuelinks,fixVersions,duedate,reporter,creator,created,updated
JIRA_CR=$(printf '\r')

# Inherited values would skip the steps they stand for: a set JIRA_TRUSTED is no trust check at all.
JIRA_READY='' JIRA_TRUSTED='' JIRA_BODY='' JIRA_MOVE_ID='' JIRA_PARENT_EDIT='' JIRA_PARENT_MOVE=''

jira_env() {
    [ -z "${JIRA_READY:-}" ] || return 0
    JIRA_PROJECT=${BOARD_PROJECT:-}
    JIRA_BOARD=$(board_config_get .target.board)
    if [ -n "${BOARD_URL:-}" ]; then
        jira_site "$BOARD_URL"
    fi
    JIRA_READY=1
}

# Without the case a run spawns tr a dozen times, and on Windows a spawn is slow.
jira_lower() {
    case $1 in
        *[A-Z]*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;;
        *) printf '%s' "$1" ;;
    esac
}

# The host of a URL, port included, in lower case.
jira_host_of() {
    jira_ho_host=${1#*://}
    jira_lower "${jira_ho_host%%/*}"
}

# A top-level scalar of a jira-cli config. The anchor at column 0 keeps a server nested under
# another key from counting as the server.
# Usage: jira_yaml <file> <key>
jira_yaml() {
    [ -f "$1" ] || return 0
    while IFS= read -r jira_ym_line || [ -n "$jira_ym_line" ]; do
        case $jira_ym_line in
            "$2":*) ;;
            *) continue ;;
        esac
        jira_ym_value=${jira_ym_line#*:}
        jira_ym_value=${jira_ym_value%"$JIRA_CR"}
        jira_ym_value=${jira_ym_value%%[ 	]\#*}
        jira_ym_value=${jira_ym_value#"${jira_ym_value%%[! 	]*}"}
        jira_ym_value=${jira_ym_value%"${jira_ym_value##*[! 	]}"}
        case $jira_ym_value in
            \"*\" | \'*\')
                jira_ym_value=${jira_ym_value#?}
                jira_ym_value=${jira_ym_value%?}
                ;;
        esac
        printf '%s' "$jira_ym_value"
        return 0
    done <"$1"
}

# A setting from [board] config, else from the user's config when that describes this site: a
# config for another server says nothing about this one. Neither may ever add trust.
jira_setting() {
    jira_st_value=$(jira_yaml "${BOARD_CLI_CONFIG:-}" "$1")
    if [ -z "$jira_st_value" ] && [ "$JIRA_USER_HOST" = "$(jira_lower "$JIRA_HOST")" ]; then
        jira_st_value=$(jira_yaml "$JIRA_USER_FILE" "$1")
    fi
    printf '%s' "$jira_st_value"
}

# Reads who to log in as on <url>. Sets JIRA_HOST, JIRA_BASE, JIRA_CLOUD, JIRA_LOGIN and JIRA_AUTH.
jira_site() {
    JIRA_SCHEME=${1%%://*}
    JIRA_HOST=${1#*://}
    JIRA_HOST=${JIRA_HOST%%/*}
    JIRA_USER_FILE=${JIRA_CONFIG_FILE:-${HOME:-}/.config/.jira/.config.yml}
    JIRA_USER_SERVER=$(jira_yaml "$JIRA_USER_FILE" server)
    # A relative path is read from where board runs, which is inside a repository: no vouching.
    case $JIRA_USER_FILE in
        /* | [A-Za-z]:[\\/]*) JIRA_USER_NOTE='' ;;
        *)
            JIRA_USER_SERVER=''
            JIRA_USER_NOTE=' (a relative JIRA_CONFIG_FILE does not count)'
            ;;
    esac
    JIRA_USER_HOST=$(jira_host_of "$JIRA_USER_SERVER")
    JIRA_LOGIN=$(jira_setting login)
    # A login is who you are, not what the site is, and it goes only to a host already trusted.
    [ -n "$JIRA_LOGIN" ] || JIRA_LOGIN=$(jira_yaml "$JIRA_USER_FILE" login)
    JIRA_AUTH=$(jira_setting auth_type)
    case $(jira_setting installation) in
        [Cc]loud) JIRA_CLOUD=1 ;;
        '')
            case $JIRA_HOST in
                *.atlassian.net) JIRA_CLOUD=1 ;;
                *) JIRA_CLOUD='' ;;
            esac
            ;;
        *) JIRA_CLOUD='' ;;
    esac
    case $JIRA_AUTH in
        basic | bearer) ;;
        *)
            JIRA_AUTH=bearer
            [ -z "$JIRA_CLOUD" ] || JIRA_AUTH=basic
            ;;
    esac
    # Data Center may live under a path; on Cloud a path is only where a browser was.
    JIRA_BASE=${1%%[?#]*}
    JIRA_BASE=${JIRA_BASE%/}
    [ -z "$JIRA_CLOUD" ] || JIRA_BASE=$JIRA_SCHEME://$JIRA_HOST
}

# workflow.toml and any config beside it come with a repository, so neither may choose where the
# token goes. A request leaves only for a host the user named outside the repository, and this is
# the one place every request passes. It exits rather than returns, so no caller can ignore it.
jira_trust() {
    [ -z "${JIRA_TRUSTED:-}" ] || return 0
    jira_tr_host=$(jira_lower "$JIRA_HOST")
    jira_tr_named=''
    jira_tr_clear=''
    if [ "$JIRA_USER_HOST" = "$jira_tr_host" ]; then
        jira_tr_named=1
        case $JIRA_USER_SERVER in
            http://*) jira_tr_clear=1 ;;
        esac
    fi
    case " $(jira_lower "${BOARD_JIRA_HOSTS:-}") " in
        *" $jira_tr_host "*) jira_tr_named=1 ;;
    esac
    [ -n "$jira_tr_named" ] ||
        board_auth_die "$JIRA_HOST is not a trusted Jira host, so no request was made: add it to BOARD_JIRA_HOSTS (space-separated), or name it as server in $JIRA_USER_FILE$JIRA_USER_NOTE"
    # Naming a host does not let a repository strip TLS from the way there.
    [ "$JIRA_SCHEME" = https ] || [ -n "$jira_tr_clear" ] ||
        board_auth_die "the token would go to $JIRA_HOST in clear over http, so no request was made: use https, or name http:// in server of $JIRA_USER_FILE"
    JIRA_TRUSTED=1
}

jira_curl_config() {
    if [ -z "${JIRA_API_TOKEN:-}" ]; then
        printf 'netrc-optional\n'
    elif [ "$JIRA_AUTH" = bearer ]; then
        printf 'header = %s\n' "$(printf 'Authorization: Bearer %s' "$JIRA_API_TOKEN" | board_http_quote)"
    else
        printf 'user = %s\n' "$(printf '%s:%s' "$JIRA_LOGIN" "$JIRA_API_TOKEN" | board_http_quote)"
    fi
    printf 'globoff\nrequest = "%s"\nheader = "Accept: application/json"\n' "$JIRA_METHOD"
    if [ -n "$JIRA_BODY" ]; then
        printf 'header = "Content-Type: application/json"\ndata-binary = %s\n' "$JIRA_BODY"
    fi
}

# One request. Leaves the answer in $BOARD_OUT and BOARD_HTTP_STATUS, and returns non-zero only when
# no answer came. Usage: jira_request <method> <path>
jira_request() {
    jira_trust
    if [ -n "${JIRA_API_TOKEN:-}" ] && [ "$JIRA_AUTH" = basic ] && [ -z "$JIRA_LOGIN" ]; then
        board_auth_die "no login for $JIRA_HOST: set login in $JIRA_USER_FILE, or in the file [board] config names"
    fi
    JIRA_METHOD=$1
    jira_rq_status=0
    board_http jira_curl_config "$JIRA_BASE$2" || jira_rq_status=$?
    JIRA_BODY=''
    [ "$jira_rq_status" != 0 ] || return 0
    # A read wrote nothing, even in a command that goes on to write.
    [ "$1" != GET ] || BOARD_WRITE=''
    if [ "$jira_rq_status" = "$BOARD_EXIT_TIMEOUT" ]; then
        board_timed_out
        return $?
    fi
    case $jira_rq_status in
        # No request can have arrived: a bad URL, no DNS, no connection, no TLS, or no curl.
        1 | 2 | 3 | 4 | 5 | 6 | 7 | 35 | 58 | 60 | 77 | 126 | 127) ;;
        *)
            if [ -n "${BOARD_WRITE:-}" ]; then
                jira_unknown "the connection to $JIRA_HOST broke (curl exit $jira_rq_status): the write may have gone through. Check before repeating it"
                return $?
            fi
            ;;
    esac
    board_warn "cannot reach $JIRA_HOST: curl exit $jira_rq_status $(board_err_line)"
    return "$BOARD_EXIT_ERROR"
}

# A write that may have arrived: exit 6, with the id when it is known. board_print_id reaches past
# the $(...) the step runs in, so jira_stop must not print the id again.
jira_unknown() {
    [ -z "${BOARD_WRITE_ID:-}" ] || board_print_id "$BOARD_WRITE_ID"
    board_warn "$1"
    return "$BOARD_EXIT_PARTIAL"
}

# The answer of a write that went through: prints one field of it, or exit 6. A 2xx that says nothing
# usable is not a failed write, and the word null is no id. Usage: jira_written <answer> <field>
jira_written() {
    jira_wr_value=$(printf '%s' "$1" | _jq -r --arg f "$2" '.[$f] // empty | tostring' 2>/dev/null) || jira_wr_value=''
    case $jira_wr_value in
        '' | null | *[!A-Za-z0-9_-]*)
            jira_unknown "Jira took the write, but its answer gives no $2: check the board before repeating it"
            return $?
            ;;
    esac
    printf '%s' "$jira_wr_value"
}

# What Jira said, on one line. An answer that is not JSON is cut, not trusted to be short.
jira_error_line() {
    jira_el_line=$(_jq -r '
        [(.errorMessages? // [])[], ((.errors? // {}) | to_entries[] | "\(.key): \(.value)"), (.message? // empty)]
        | map(select(. != "")) | join("; ")' <"$BOARD_OUT" 2>/dev/null) || jira_el_line=''
    [ -n "$jira_el_line" ] || jira_el_line=$(sed -n 1p "$BOARD_OUT" | cut -c1-200)
    printf '%s' "$jira_el_line"
}

# Cloud does not say a token is bad: a read answers 404, a write 400, and a search an empty 200. Only
# /myself tells. Usage: jira_login_check — returns 0 when the login works.
jira_login_check() {
    BOARD_WRITE=''
    jira_request GET /rest/api/2/myself || return $?
    case $BOARD_HTTP_STATUS in
        200)
            board_record "$(board_rest_key GET /rest/api/2/myself)"
            return 0
            ;;
        401 | 403)
            board_warn "Jira refused the login on $JIRA_HOST (HTTP $BOARD_HTTP_STATUS): check JIRA_API_TOKEN"
            return "$BOARD_EXIT_AUTH"
            ;;
    esac
    board_warn "Jira did not say who is logged in on $JIRA_HOST (HTTP $BOARD_HTTP_STATUS)"
    return "$BOARD_EXIT_ERROR"
}

# Only here an answer becomes an exit code. Usage: jira_check <path>
jira_check() {
    case $BOARD_HTTP_STATUS in
        2??) return 0 ;;
    esac
    jira_ck_http=$BOARD_HTTP_STATUS
    jira_ck_line=$(jira_error_line)
    case $jira_ck_http in
        401 | 403)
            board_warn "${jira_ck_line:-Jira refused the request} (HTTP $jira_ck_http)"
            return "$BOARD_EXIT_AUTH"
            ;;
        404 | 400)
            case $1 in
                /rest/api/2/myself*)
                    board_warn "Jira did not say who is logged in on $JIRA_HOST (HTTP $jira_ck_http)"
                    return "$BOARD_EXIT_ERROR"
                    ;;
            esac
            jira_login_check || return $?
            board_warn "${jira_ck_line:-HTTP $jira_ck_http}"
            [ "$jira_ck_http" = 400 ] || return "$BOARD_EXIT_NOT_FOUND"
            return "$BOARD_EXIT_ERROR"
            ;;
        429)
            board_warn "Jira is limiting the rate of calls (HTTP 429): wait, then retry"
            return "$BOARD_EXIT_ERROR"
            ;;
        # A gateway answered, so the write may have reached Jira behind it.
        502 | 503 | 504)
            if [ "$JIRA_METHOD" != GET ] && [ -n "${BOARD_WRITE:-}" ]; then
                jira_unknown "HTTP $jira_ck_http from $JIRA_HOST: the write may have gone through. Check before repeating it"
                return $?
            fi
            ;;
    esac
    board_warn "Jira answered HTTP $jira_ck_http: $jira_ck_line"
    return "$BOARD_EXIT_ERROR"
}

# Usage: jira_call <method> <path>  — prints the answer of a call with no body.
jira_call() {
    jira_request "$1" "$2" || return $?
    jira_check "$2" || return $?
    # A file: each step runs in its own $(...), and a search is a POST that writes nothing.
    if [ "$1" != GET ] && [ -n "${BOARD_WRITE:-}" ]; then
        : >"$BOARD_TMP/jira.wrote"
    fi
    board_record "$(board_rest_key "$1" "$2")"
    cat "$BOARD_OUT"
}

# After a failed step: exit 6 with the id once a write went through, else the step's own status. An
# exit 6 from the step has given the id already.
# Usage: step || jira_stop "$?" <id> <message> || return $?
jira_stop() {
    [ "$1" = "$BOARD_EXIT_PARTIAL" ] || [ ! -f "$BOARD_TMP/jira.wrote" ] || board_partial "$2" "$3"
    return "$1"
}

# Usage: <JSON body on stdin> | jira_send <method> <path>
jira_send() {
    JIRA_BODY=$(board_http_quote)
    jira_call "$1" "$2"
}

jira_require_project() {
    [ -n "$JIRA_PROJECT" ] || board_usage_die "no [board] project: the key of the Jira project, e.g. KAN"
    jira_safe "[board] project" "$JIRA_PROJECT"
}

# Anything put in a URL path. Usage: jira_safe <what> <value>
jira_safe() {
    case $2 in
        '' | *[!A-Za-z0-9_-]*) board_usage_die "$1 must look like KAN-1 or 10001, got '$2'" ;;
    esac
}

# Usage: jira_paged_url <path> <cursor> <page size>  — a path that pages by startAt.
jira_paged_url() {
    case $1 in
        *\?*) printf '%s&startAt=%s&maxResults=%s' "$1" "${2:-0}" "$3" ;;
        *) printf '%s?startAt=%s&maxResults=%s' "$1" "${2:-0}" "$3" ;;
    esac
}

# A project: its issue types, and its name. Read once a run. An issue may live outside the project
# the board declares, and its own project is the one that decides.
# Usage: jira_project [key]
jira_project() {
    jira_pj_key=${1:-$JIRA_PROJECT}
    jira_safe "the project" "$jira_pj_key"
    if [ -f "$BOARD_TMP/jira.project.$jira_pj_key" ]; then
        cat "$BOARD_TMP/jira.project.$jira_pj_key"
        return 0
    fi
    jira_pj_doc=$(jira_call GET "/rest/api/2/project/$jira_pj_key") || return $?
    printf '%s' "$jira_pj_doc" >"$BOARD_TMP/jira.project.$jira_pj_key"
    printf '%s' "$jira_pj_doc"
}

jira_auth_status() {
    jira_as_doc=$(jira_call GET /rest/api/2/myself) || return $?
    printf '%s' "$jira_as_doc" | _jq -c --arg host "$JIRA_HOST" \
        '{kind: "jira", host: $host, authenticated: true, user: (.displayName // .name // .accountId)}'
}

jira_doctor_checks() {
    board_provider_load status
    jira_dc_statuses=$(jira_status_list) || return $?
    printf '%s' "$jira_dc_statuses" | _jq -c --arg board "$JIRA_BOARD" '
        {warnings: (if $board == "" then ["no [board.target] board: sprints and board columns are not available"] else [] end),
         errors: [.[] | select(.category == null)
                  | "status \"\(.name)\" has no category: declare it in [board.statuses]"]}'
}

jira_board_page() {
    jira_bp_doc=$(jira_call GET "$(jira_paged_url /rest/agile/1.0/board "$1" 50)") || return $?
    printf '%s' "$jira_bp_doc" | _jq -c --arg base "$JIRA_BASE" --arg cloud "$JIRA_CLOUD" '
        '"$BOARD_LIB"'
        {has_next: (.isLast == false), end_cursor: ((.startAt // 0) + (.values | length)),
         nodes: [.values[] | jira_board($base; $cloud)]}'
}

jira_board_list() {
    board_paged jira_board_page all
}

# A column may hold several statuses. With no board declared, a column is a status.
jira_board_view() {
    jira_require_project
    board_provider_load status
    jira_bv_statuses=$(jira_status_list) || return $?
    if [ -n "$JIRA_BOARD" ]; then
        board_require_int "[board.target] board" "$JIRA_BOARD"
        jira_bv_doc=$(jira_call GET "/rest/agile/1.0/board/$JIRA_BOARD/configuration") || return $?
        printf '%s' "$jira_bv_doc" | _jq -c --argjson s "$jira_bv_statuses" --arg base "$JIRA_BASE" \
            --arg cloud "$JIRA_CLOUD" --arg project "$JIRA_PROJECT" '
            '"$BOARD_LIB"'
            jira_board($base; $cloud) as $b
            | (.columnConfig.columns | map({name, statuses: [.statuses[].id as $i | $s[] | select(.id == $i) | .name]})) as $c
            | {id: $b.id, name: $b.name, kind: "jira",
               url: (if $cloud == "1" then "\($base)/jira/software/projects/\($project)/boards/\($b.id)" else $b.url end),
               columns: $c, statuses: $s}'
        return 0
    fi
    jira_bv_doc=$(jira_project "$JIRA_PROJECT") || return $?
    printf '%s' "$jira_bv_doc" | _jq -c --argjson s "$jira_bv_statuses" --arg base "$JIRA_BASE" '
        {id: .key, name, kind: "jira", url: "\($base)/browse/\(.key)",
         columns: ($s | map({name, statuses: [.name]})), statuses: $s}'
}

# Usage: jira_api_call <METHOD> <path>  — a body comes from stdin.
jira_api_call() {
    [ $# -eq 2 ] || board_usage_die "Jira takes METHOD and path: board api GET /rest/api/2/myself"
    case $1 in
        GET) ;;
        DELETE) BOARD_WRITE=1 ;;
        POST | PUT | PATCH)
            BOARD_WRITE=1
            jira_ac_body=$(_jq -c .) || board_usage_die "the body on stdin must be JSON"
            [ -z "$jira_ac_body" ] || JIRA_BODY=$(printf '%s' "$jira_ac_body" | board_http_quote)
            ;;
        *) board_usage_die "Jira takes METHOD and path: GET, POST, PUT, PATCH or DELETE, got '$1'" ;;
    esac
    # Glued to the base, anything but a path would rewrite the host: https://site@elsewhere.
    case $2 in
        /*) ;;
        *) board_usage_die "the path must start with /, got '$2'" ;;
    esac
    jira_call "$1" "$2"
}

# Where a browser URL says the project is. Sets JIRA_ID_KEY and JIRA_ID_BOARD.
jira_url_target() {
    jira_ut_path=${1#*://}
    jira_ut_path=/${jira_ut_path#*/}
    jira_ut_query=''
    case $1 in
        *\?*) jira_ut_query=\&${1#*\?} ;;
    esac
    jira_ut_path=${jira_ut_path%%[?#]*}
    JIRA_ID_KEY='' JIRA_ID_BOARD=''
    case $jira_ut_path in
        */browse/*)
            JIRA_ID_KEY=${jira_ut_path##*/browse/}
            JIRA_ID_KEY=${JIRA_ID_KEY%%/*}
            JIRA_ID_KEY=${JIRA_ID_KEY%-[0-9]*}
            ;;
        */projects/*)
            JIRA_ID_KEY=${jira_ut_path##*/projects/}
            JIRA_ID_KEY=${JIRA_ID_KEY%%/*}
            ;;
    esac
    case $jira_ut_path in
        */boards/*)
            JIRA_ID_BOARD=${jira_ut_path##*/boards/}
            JIRA_ID_BOARD=${JIRA_ID_BOARD%%/*}
            ;;
    esac
    case $jira_ut_query in
        *'&rapidView='*)
            JIRA_ID_BOARD=${jira_ut_query##*\&rapidView=}
            JIRA_ID_BOARD=${JIRA_ID_BOARD%%[&#]*}
            ;;
    esac
    case $jira_ut_query in
        *'&projectKey='*)
            JIRA_ID_KEY=${jira_ut_query##*\&projectKey=}
            JIRA_ID_KEY=${JIRA_ID_KEY%%[&#]*}
            ;;
    esac
}

# Usage: jira_init_discover <url> <repo>  — repo means nothing here.
jira_init_discover() {
    jira_id_host=${1#*://}
    jira_id_host=${jira_id_host%%/*}
    # The same rule as [board] url: a userinfo part would pass the trust check and go elsewhere.
    case $jira_id_host in
        '' | *[!A-Za-z0-9.:-]*) board_usage_die "--url has a bad host: '$jira_id_host'" ;;
    esac
    jira_url_target "$1"
    jira_id_base=${1%%[?#]*}
    jira_id_base=${jira_id_base%%/browse/*}
    jira_id_base=${jira_id_base%%/projects/*}
    jira_id_base=${jira_id_base%%/secure/*}
    jira_site "$jira_id_base"
    jira_trust
    [ -z "$JIRA_ID_BOARD" ] || board_require_int "the board in --url" "$JIRA_ID_BOARD"
    if [ -z "$JIRA_ID_KEY" ] && [ -n "$JIRA_ID_BOARD" ]; then
        jira_id_doc=$(jira_call GET "/rest/agile/1.0/board/$JIRA_ID_BOARD") || return $?
        JIRA_ID_KEY=$(printf '%s' "$jira_id_doc" | _jq -r '.location.projectKey // ""')
    fi
    [ -n "$JIRA_ID_KEY" ] ||
        board_usage_die "--url must name a project or a board: https://$jira_id_host/jira/software/projects/<KEY>/boards/<n> or https://$jira_id_host/browse/<KEY>"
    JIRA_ID_KEY=$(printf '%s' "$JIRA_ID_KEY" | tr '[:lower:]' '[:upper:]')
    jira_safe "the project in --url" "$JIRA_ID_KEY"
    jira_id_doc=$(jira_call GET "/rest/api/2/project/$JIRA_ID_KEY/statuses") || return $?
    # Jira has its own categories, so only what it cannot say goes in [board.statuses]: canceled.
    printf '%s' "$jira_id_doc" | _jq -c --arg url "$JIRA_BASE" --arg key "$JIRA_ID_KEY" --arg board "$JIRA_ID_BOARD" '
        '"$BOARD_LIB"'
        ([.[].statuses[].name] | unique) as $names
        | {board: {kind: "jira", url: $url, project: $key, issue_uri: "/browse/{ticket}"},
           target: (if $board == "" then {} else {board: ($board | tonumber)} end),
           statuses: ([$names[] | select(guess_category == "canceled") | {key: ., value: "canceled"}] | from_entries),
           unplaced: []}'
}

# shellcheck shell=sh

# GitHub adapter: transport, classification and the board-level calls. The board is a Projects v2
# project; [board] url names the repository new issues go to.

github_env() {
    [ -z "${GH_READY:-}" ] || return 0
    GH_CLI=gh
    if [ -n "${BOARD_URL:-}" ]; then
        GH_REPO=${BOARD_URL#*://}
        GH_REPO=${GH_REPO#*/}
        GH_REPO=${GH_REPO%/}
        GH_REPO=${GH_REPO%.git}
        if [ "$BOARD_HOST" != github.com ]; then
            GH_HOST=$BOARD_HOST
            export GH_HOST
        fi
        eval "$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -r '
            def s($d): . // $d | tostring;
            .target as $t
            | @sh "GH_OWNER=\($t.owner | s("")) GH_NUMBER=\($t.number | s(""))",
              @sh "GH_PRIORITY_FIELD=\($t.priority_field | s("Priority")) GH_DUE_FIELD=\($t.due_field | s("Due date")) GH_SPRINT_FIELD=\($t.sprint_field | s(""))"')"
    fi
    GH_READY=1
}

github_require_project() {
    github_env
    [ -n "$GH_OWNER" ] && [ -n "$GH_NUMBER" ] ||
        board_usage_die "[board.target] needs owner and number: the GitHub project this board is"
    board_require_int "[board.target] number" "$GH_NUMBER"
}

# What a failed call means. stdout holds the JSON answer, stderr the tool's own line.
github_check() {
    if [ "$1" = "$BOARD_EXIT_TIMEOUT" ]; then
        board_timed_out
        return $?
    fi
    github_ck_type=$(_jq -r '[(.errors? // [])[] | objects | .type // empty] | first // empty' <"$BOARD_OUT" 2>/dev/null) || github_ck_type=''
    if [ "$1" = 0 ] && [ -z "$github_ck_type" ]; then
        return 0
    fi
    github_ck_line=$(_jq -r '[(.errors? // [])[] | objects | .message // empty] | first // .message // empty' <"$BOARD_OUT" 2>/dev/null) || github_ck_line=''
    [ -n "$github_ck_line" ] || github_ck_line=$(board_err_line)
    board_warn "$github_ck_line"
    case $github_ck_type in
        NOT_FOUND) return "$BOARD_EXIT_NOT_FOUND" ;;
        FORBIDDEN | INSUFFICIENT_SCOPES) return "$BOARD_EXIT_AUTH" ;;
    esac
    case $(board_err_line) in
        *'HTTP 401'* | *'gh auth login'* | *'HTTP 403'*) return "$BOARD_EXIT_AUTH" ;;
        *'HTTP 404'* | *'HTTP 410'*) return "$BOARD_EXIT_NOT_FOUND" ;;
    esac
    return "$BOARD_EXIT_ERROR"
}

# A GraphQL request on stdin; prints .data.
github_gql() {
    github_gq_status=0
    board_exec "$GH_CLI" api graphql --input - || github_gq_status=$?
    github_check "$github_gq_status" || return $?
    board_record "$1"
    _jq -c .data <"$BOARD_OUT"
}

# Usage: <variables JSON on stdin> | github_query <Name>
# The name is a file in lib/github/queries. Variables stay on stdin, so a body fits.
github_query() {
    _jq -c --rawfile q "$BOARD_HOME/lib/github/queries/$1.graphql" \
        --rawfile f "$BOARD_HOME/lib/github/queries/fragments.graphql" \
        '{query: ($q + (if ($q | test("\\.\\.\\.(Issue|Item)Fields")) then $f else "" end)), variables: .}' |
        github_gql "$1"
}

# Field names for the queries that read project fields, merged into the variables. A name that no
# field has reads as null, so an undeclared one is harmless.
github_field_vars() {
    _jq -c --arg p "$GH_PRIORITY_FIELD" --arg d "$GH_DUE_FIELD" --arg s "${GH_SPRINT_FIELD:-Sprint}" \
        '. + {priorityField: $p, dueField: $d, sprintField: $s}'
}

# Usage: github_rest <method> <path>  — no body.
github_rest() {
    github_rs_status=0
    board_exec "$GH_CLI" api -X "$1" "$2" </dev/null || github_rs_status=$?
    github_check "$github_rs_status" || return $?
    board_record "$(board_rest_key "$1" "$2")"
    cat "$BOARD_OUT"
}

# Usage: <JSON body on stdin> | github_rest_body <method> <path>
github_rest_body() {
    github_rs_status=0
    board_exec "$GH_CLI" api -X "$1" "$2" --input - || github_rs_status=$?
    github_check "$github_rs_status" || return $?
    cat "$BOARD_OUT"
}

# Usage: github_rest_all <path>  — every page, as one array.
github_rest_all() {
    github_rs_status=0
    board_exec "$GH_CLI" api "$1" --paginate --slurp </dev/null || github_rs_status=$?
    github_check "$github_rs_status" || return $?
    board_record "$(board_rest_key GET "$1")"
    _jq -c 'add // []' <"$BOARD_OUT"
}

# Everything about the project that does not change between calls of one run.
github_meta() {
    if [ -f "$BOARD_TMP/github.meta" ]; then
        cat "$BOARD_TMP/github.meta"
        return 0
    fi
    github_require_project
    github_mt_doc=$(_jq -nc --arg owner "$GH_OWNER" --argjson number "$GH_NUMBER" \
        '{owner: $owner, number: $number}' | github_query ProjectMeta) || return $?
    github_mt_doc=$(printf '%s' "$github_mt_doc" | _jq -c '.repositoryOwner.projectV2 // empty')
    if [ -z "$github_mt_doc" ]; then
        board_warn "no project $GH_NUMBER under $GH_OWNER"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$github_mt_doc" >"$BOARD_TMP/github.meta"
    printf '%s' "$github_mt_doc"
}

# Usage: github_option <field name> <option name>  — prints {field, option}.
github_option() {
    github_op_meta=$(github_meta) || return $?
    github_op_doc=$(printf '%s' "$github_op_meta" | _jq -c --arg f "$1" --arg o "$2" '
        '"$BOARD_LIB"'
        [.fields.nodes[] | select(.name != null) | select(.name | ieq($f))] | first
        | if . == null then {missing: "field"}
          else . as $field
          | ([($field.options // [])[] | select(.name | ieq($o))] | first) as $hit
          | if $hit then {field: $field.id, option: $hit.id, name: $hit.name}
            else {missing: "option", have: [($field.options // [])[].name]} end
          end')
    case $(printf '%s' "$github_op_doc" | _jq -r '.missing // ""') in
        field) board_usage_die "this project has no field '$1'" ;;
        option)
            board_usage_die "no $1 '$2': the project has $(printf '%s' "$github_op_doc" | _jq -r '.have | join(", ")')"
            ;;
    esac
    printf '%s' "$github_op_doc"
}

github_viewer() {
    github_env
    github_vw_doc=$(printf '{}' | github_query Viewer) || return $?
    printf '%s' "$github_vw_doc" | _jq -r .viewer.login
}

github_auth_status() {
    github_env
    github_as_user=$(github_viewer) || return $?
    _jq -nc --arg host "$BOARD_HOST" --arg user "$github_as_user" \
        '{kind: "github", host: $host, authenticated: true, user: $user}'
}

github_doctor_checks() {
    github_env
    github_dc_meta=$(github_meta) || return $?
    printf '%s\n' "$github_dc_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        ([.fields.nodes[] | select(.name == "Status") | .options[].name]) as $statuses
        | {warnings: [.workflows.nodes[] | select(.enabled)
                      | select(.name == "Auto-close issue" or .name == "Item closed")
                      | "project workflow \"\(.name)\" is on: it changes issues on its own after a move or close"],
           errors: ([$statuses[] | . as $n | select({name: $n} | make_status($cfg) | .category == null)
                     | "status \"\(.)\" has no category: declare it in [board.statuses]"])}'
}

github_status_field() {
    github_meta | _jq -c '[.fields.nodes[] | select(.name == "Status")] | first // empty'
}

github_board_list() {
    github_require_project
    github_bl_doc=$(_jq -nc --arg owner "$GH_OWNER" '{owner: $owner}' | github_query OwnerProjects) || return $?
    printf '%s' "$github_bl_doc" | _jq -c '
        '"$BOARD_LIB"'
        [.repositoryOwner.projectsV2.nodes[] | select(.closed | not)
         | {id: .number, name: .title, url} | make_board]'
}

github_board_view() {
    github_bv_meta=$(github_meta) || return $?
    printf '%s' "$github_bv_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg number "$GH_NUMBER" '
        '"$BOARD_LIB"'
        ([.fields.nodes[] | select(.name == "Status") | .options[] | {id, name} | make_status($cfg)]) as $s
        | {id: $number, name: .title, kind: "github", url,
           columns: ($s | map({name, statuses: [.name]})), statuses: $s}'
}

github_api_call() {
    github_env
    github_ac_status=0
    board_exec "$GH_CLI" api "$@" || github_ac_status=$?
    github_check "$github_ac_status" || return $?
    cat "$BOARD_OUT"
}

# Usage: github_init_discover <url> <repo>
github_init_discover() {
    github_id_path=${1#*://}
    github_id_host=${github_id_path%%/*}
    github_id_path=${github_id_path#*/}
    case $github_id_path in
        users/*/projects/* | orgs/*/projects/*)
            github_id_rest=${github_id_path#*/}
            GH_OWNER=${github_id_rest%%/*}
            github_id_rest=${github_id_rest#*/projects/}
            GH_NUMBER=${github_id_rest%%/*}
            GH_NUMBER=${GH_NUMBER%%\?*}
            ;;
        *) board_usage_die "--url must be a project URL: https://$github_id_host/users/<owner>/projects/<number>" ;;
    esac
    board_require_int "the project number in --url" "$GH_NUMBER"
    [ -n "$2" ] || board_usage_die "--repo <owner/repo> is required: the repository new issues go to"
    case $2 in
        */*) ;;
        *) board_usage_die "--repo must be owner/repo, got '$2'" ;;
    esac
    GH_PRIORITY_FIELD=Priority GH_DUE_FIELD='Due date' GH_SPRINT_FIELD=
    GH_READY=1
    github_id_meta=$(github_meta) || return $?
    printf '%s' "$github_id_meta" | _jq -c --arg owner "$GH_OWNER" --argjson number "$GH_NUMBER" \
        --arg url "https://$github_id_host/$2" '
        '"$BOARD_LIB"'
        ([.fields.nodes[] | select(.name == "Status") | .options[].name]) as $names
        | {board: {kind: "github", cli: "gh", url: $url, project: "#", issue_uri: "/issues/{ticket}"},
           target: {owner: $owner, number: $number},
           statuses: ([$names[] | select(guess_category != null) | {key: ., value: guess_category}] | from_entries),
           unplaced: [$names[] | select(guess_category == null)]}'
}

# shellcheck shell=sh

# GitLab adapter: transport, classification and the board-level calls. The board is a project with
# an issue board: [board] url names the project and [board.target] board picks one of its boards.

# Sets GL_PATH, GL_ID, GL_WEB and GL_ISSUES from a project URL or the URL of one of its pages.
gitlab_project_of() {
    gitlab_po_rest=${1#*://}
    gitlab_po_host=${gitlab_po_rest%%/*}
    case $gitlab_po_rest in
        */*) gitlab_po_rest=${gitlab_po_rest#*/} ;;
        *) gitlab_po_rest='' ;;
    esac
    gitlab_po_rest=${gitlab_po_rest%%\?*}
    gitlab_po_rest=${gitlab_po_rest%%/-/*}
    gitlab_po_rest=${gitlab_po_rest%/}
    GL_PATH=${gitlab_po_rest%.git}
    GL_ID=$(board_urlencode "$GL_PATH")
    GL_WEB=${1%%://*}://$gitlab_po_host/$GL_PATH
    GL_ISSUES=projects/$GL_ID/issues
}

gitlab_env() {
    [ -z "${GL_READY:-}" ] || return 0
    GL_CLI=glab
    GL_BOARD=''
    GL_CFG=$BOARD_CONFIG_JSON
    if [ -n "${BOARD_URL:-}" ]; then
        board_require_trusted_host gitlab.com
        gitlab_project_of "$BOARD_URL"
        [ -n "$GL_PATH" ] || board_usage_die "[board] url must name a project: https://$BOARD_HOST/<group>/<project>"
        GL_BOARD=$(printf '%s' "$BOARD_CONFIG_JSON" | _jq -r '.target.board // "" | tostring')
        [ -z "$GL_BOARD" ] || board_require_int "[board.target] board" "$GL_BOARD"
    fi
    GL_READY=1
}

# glab's own line, without its prefix and the frame it draws around some errors.
gitlab_err_line() {
    sed 's/\x1b\[[0-9;]*m//g; s/^glab: //; /^[[:space:]]*ERROR[[:space:]]*$/d; /^[[:space:]]*$/d; s/^[[:space:]]*//; s/[[:space:]]*$//' \
        "$BOARD_ERR" | head -n 1
}

gitlab_login_works() {
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" -X GET user </dev/null
}

# What a failed call means, from the HTTP code on stderr. glab drops the code for a GraphQL error
# and for a host it has no login for, so those two are told apart here.
gitlab_check() {
    [ "$1" != 0 ] || return 0
    if [ "$1" = "$BOARD_EXIT_TIMEOUT" ]; then
        board_timed_out
        return $?
    fi
    gitlab_ck_line=$(_jq -r ''"$BOARD_LIB"' gl_message' <"$BOARD_OUT" 2>/dev/null) || gitlab_ck_line=''
    [ -n "$gitlab_ck_line" ] || gitlab_ck_line=$(gitlab_err_line)
    board_warn "$gitlab_ck_line"
    case $(sed -n 's/.*HTTP \([0-9][0-9][0-9]\).*/\1/p' "$BOARD_ERR" | head -n 1) in
        401) return "$BOARD_EXIT_AUTH" ;;
        403)
            case $gitlab_ck_line in
                *[Ll]icense*) return "$BOARD_EXIT_UNSUPPORTED" ;;
            esac
            return "$BOARD_EXIT_AUTH"
            ;;
        404)
            gitlab_login_works || return "$BOARD_EXIT_AUTH"
            return "$BOARD_EXIT_NOT_FOUND"
            ;;
        '')
            if grep -q Unauthenticated "$BOARD_ERR"; then
                return "$BOARD_EXIT_AUTH"
            fi
            # An answer with errors and no code: a bad token reads the same as a bad query.
            if _jq -e '.errors' <"$BOARD_OUT" >/dev/null 2>&1; then
                gitlab_login_works || return "$BOARD_EXIT_AUTH"
            fi
            ;;
    esac
    return "$BOARD_EXIT_ERROR"
}

# Usage: gitlab_query <Name> [-f|-F name=value]...
# The name is a file in lib/gitlab/queries. Prints the whole answer.
gitlab_query() {
    gitlab_gq_name=$1
    shift
    gitlab_gq_status=0
    # A timed-out read is a plain failure even in a command that writes.
    IFS=' (' read -r gitlab_gq_kind _ <"$BOARD_HOME/lib/gitlab/queries/$gitlab_gq_name.graphql"
    BOARD_WRITE=''
    [ "$gitlab_gq_kind" != mutation ] || BOARD_WRITE=1
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" graphql -F query=@- "$@" \
        <"$BOARD_HOME/lib/gitlab/queries/$gitlab_gq_name.graphql" || gitlab_gq_status=$?
    gitlab_check "$gitlab_gq_status" || return $?
    # A missing or private project is exit 0 with a null.
    if _jq -e '(.data | has("project")) and .data.project == null' <"$BOARD_OUT" >/dev/null 2>&1; then
        board_warn "no project $GL_PATH on $BOARD_HOST"
        gitlab_login_works || return "$BOARD_EXIT_AUTH"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    board_record "$gitlab_gq_name"
    cat "$BOARD_OUT"
}

# Usage: gitlab_refused <answer> <mutation>  — prints why a mutation changed nothing. A refusal is
# exit 0 with text in the payload's errors.
gitlab_refused() {
    printf '%s' "$1" | _jq -r --arg m "$2" '.data[$m].errors // [] | join("; ")'
}

# Usage: gitlab_rest <method> <path>  — no body.
gitlab_rest() {
    gitlab_rs_status=0
    BOARD_WRITE=''
    [ "$1" = GET ] || BOARD_WRITE=1
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" -X "$1" "$2" </dev/null || gitlab_rs_status=$?
    gitlab_check "$gitlab_rs_status" || return $?
    board_record "$(board_rest_key "$1" "$2")"
    cat "$BOARD_OUT"
}

# Usage: gitlab_rest_page <path>  — one page of a list. -i is the only way to learn whether another
# page follows: a full page may be the last. The headers go to gitlab.head, and gitlab_next_page
# reads them.
gitlab_rest_page() {
    gitlab_rs_status=0
    BOARD_WRITE=''
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" -X GET -i "$1" </dev/null || gitlab_rs_status=$?
    : >"$BOARD_TMP/gitlab.head"
    if [ "$(head -c 5 "$BOARD_OUT")" = HTTP/ ]; then
        awk '/^\r?$/ { exit } { print }' "$BOARD_OUT" >"$BOARD_TMP/gitlab.head"
        awk 'body { print } /^\r?$/ { body = 1 }' "$BOARD_OUT" >"$BOARD_OUT.body"
        mv "$BOARD_OUT.body" "$BOARD_OUT"
    fi
    gitlab_check "$gitlab_rs_status" || return $?
    board_record "$(board_rest_key GET "$1")"
    cat "$BOARD_OUT"
}

# The number of the next page, or nothing on the last one.
gitlab_next_page() {
    sed -n 's/^[Xx]-[Nn]ext-[Pp]age: *\([0-9]*\).*/\1/p' "$BOARD_TMP/gitlab.head" | head -n 1
}

# Usage: <JSON body on stdin> | gitlab_rest_body <method> <path>
gitlab_rest_body() {
    gitlab_rs_status=0
    BOARD_WRITE=1
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" -X "$1" "$2" \
        -H 'Content-Type: application/json' --input - || gitlab_rs_status=$?
    gitlab_check "$gitlab_rs_status" || return $?
    cat "$BOARD_OUT"
}

# Usage: gitlab_rest_all <path with per_page=100>  — every page, as one array. A short page is the
# last one, so no headers have to be read.
gitlab_rest_all() {
    gitlab_ra_page=1
    : >"$BOARD_TMP/gitlab.pages"
    while :; do
        gitlab_ra_doc=$(gitlab_rest GET "$1&page=$gitlab_ra_page") || return $?
        printf '%s\n' "$gitlab_ra_doc" >>"$BOARD_TMP/gitlab.pages"
        [ "$(printf '%s' "$gitlab_ra_doc" | _jq length)" -ge 100 ] || break
        gitlab_ra_page=$((gitlab_ra_page + 1))
    done
    _jq -sc 'add // []' <"$BOARD_TMP/gitlab.pages"
}

gitlab_viewer() {
    gitlab_rest GET user
}

# A step failed. Once GL_WROTE is set the board has changed, so that is exit 6 with the id; before
# that the step's own code stands. A write that timed out has printed its id through board_print_id.
# Usage: gitlab_step_failed <status> <id> <message> || return $?
gitlab_step_failed() {
    [ -z "${GL_WROTE:-}" ] || board_partial "$2" "$3"
    return "$1"
}

# Usage: gitlab_has_id <answer> <what>  — a write that answers with no id did something else, and a
# quick action is the known way to get there.
gitlab_has_id() {
    if printf '%s' "$1" | _jq -e '.id != null' >/dev/null 2>&1; then
        return 0
    fi
    board_warn "the board gave no $2 back: the write may not have done what was asked"
    return "$BOARD_EXIT_ERROR"
}

# Prints a file of this run, filling it the first time with what the command prints.
# Usage: gitlab_once <name> <command...>
gitlab_once() {
    gitlab_on_file=$BOARD_TMP/gitlab.$1
    shift
    if [ ! -f "$gitlab_on_file" ]; then
        gitlab_on_doc=$("$@") || return $?
        printf '%s\n' "$gitlab_on_doc" >"$gitlab_on_file"
    fi
    cat "$gitlab_on_file"
}

gitlab_read_label_names() {
    gitlab_rl_doc=$(gitlab_rest_all "projects/$GL_ID/labels?per_page=100") || return $?
    printf '%s' "$gitlab_rl_doc" | _jq -c 'map(.name)'
}

# The names of the project's labels, as a JSON array.
gitlab_label_names() {
    gitlab_once labels gitlab_read_label_names
}

gitlab_work_item_types() {
    gitlab_once types gitlab_query WorkItemTypes -f "path=$GL_PATH"
}

# A label as the project spells it, or as given when it has no such label.
gitlab_label_real() {
    gitlab_lr_names=$(gitlab_label_names) || return $?
    printf '%s' "$gitlab_lr_names" | _jq -r --arg l "$1" ''"$BOARD_LIB"' . as $n | gl_spelled($n; $l)'
}

# Points GL_CFG at the declaration as the project spells it. For this shell, so not in $(...).
gitlab_use_real_cfg() {
    gitlab_uc_names=$(gitlab_label_names) || return $?
    GL_CFG=$(printf '%s\n%s\n' "$BOARD_CONFIG_JSON" "$gitlab_uc_names" |
        _jq -sc ''"$BOARD_LIB"' .[1] as $names | .[0] | gl_real_cfg($names)')
}

# Prints {name, category} of a declared status, or nothing. Names are compared with ieq.
gitlab_status_find() {
    printf '%s' "$GL_CFG" | _jq -c --arg s "$1" '
        '"$BOARD_LIB"'
        [(.statuses // {}) | to_entries[] | select(.key | ieq($s)) | {name: .key, category: .value}]
        | first // empty'
}

# The same, for a status that has to exist: an unknown one is a mistake in the call.
gitlab_status_named() {
    gitlab_sn_hit=$(gitlab_status_find "$1")
    if [ -z "$gitlab_sn_hit" ]; then
        board_usage_die "no Status '$1': the project has $(printf '%s' "$GL_CFG" |
            _jq -r '(.statuses // {}) | keys_unsorted | join(", ")')"
    fi
    printf '%s' "$gitlab_sn_hit"
}

# The first status of a category, in declared order, or nothing.
gitlab_status_in() {
    printf '%s' "$GL_CFG" | _jq -r --arg c "$1" \
        '[(.statuses // {}) | to_entries[] | select(.value == $c) | .key] | first // ""'
}

# Prints the label of a priority. Nothing for none, and exit 3 when it has no declared label.
gitlab_priority_label() {
    case $1 in
        '' | none) return 0 ;;
    esac
    gitlab_pl_label=$(printf '%s' "$GL_CFG" | _jq -r --arg p "$1" '.priority[$p] // "" | tostring')
    if [ -z "$gitlab_pl_label" ]; then
        board_warn "priority $1 is not declared: add it to [board.priority]"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    printf '%s' "$gitlab_pl_label"
}

# The board of [board.target], or the first one. Prints it with its lists.
gitlab_board_doc() {
    if [ -n "$GL_BOARD" ]; then
        gitlab_rest GET "projects/$GL_ID/boards/$GL_BOARD"
        return $?
    fi
    gitlab_bd_list=$(gitlab_rest GET "projects/$GL_ID/boards?per_page=1") || return $?
    gitlab_bd_doc=$(printf '%s' "$gitlab_bd_list" | _jq -c 'first // empty')
    if [ -z "$gitlab_bd_doc" ]; then
        board_warn "project $GL_PATH has no board"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$gitlab_bd_doc"
}

gitlab_auth_status() {
    gitlab_env
    gitlab_as_doc=$(gitlab_viewer) || return $?
    printf '%s' "$gitlab_as_doc" | _jq -c --arg host "$BOARD_HOST" \
        '{kind: "gitlab", host: $host, authenticated: true, user: .username}'
}

gitlab_doctor_checks() {
    gitlab_env
    gitlab_dc_labels=$(gitlab_rest_all "projects/$GL_ID/labels?per_page=100") || return $?
    gitlab_dc_board=$(gitlab_board_doc) || return $?
    printf '%s\n%s\n' "$gitlab_dc_labels" "$gitlab_dc_board" | _jq -sc --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        (.[0] | map(.name)) as $labels
        | [.[1].lists[] | .label.name | values] as $lists
        | gl_status_names($cfg) as $statuses
        | {warnings: ((if ($statuses | length) == 0
                       then ["[board.statuses] declares nothing: issue move cannot work"] else [] end)
                      + [$statuses[] | . as $s | select($labels | gl_has($s) | not)
                         | "status \"\(.)\" has no label: run board status add"]
                      + [$statuses[] | . as $s | select(($labels | gl_has($s)) and ($lists | gl_has($s) | not))
                         | "status \"\(.)\" has no list on the board: run board status add"]
                      + [gl_priority_names($cfg)[] | . as $p | select($labels | gl_has($p) | not)
                         | "priority label \"\(.)\" does not exist yet: the first use creates it"]
                      + [($statuses + gl_priority_names($cfg))[] as $d | $labels[] | select(ieq($d) and . != $d)
                         | "label \"\($d)\" is spelled \"\(.)\" on the board: board writes that spelling"]),
           errors: ([$lists[] | . as $l | select($statuses | gl_has($l) | not)
                     | "status \"\(.)\" has no category: declare it in [board.statuses]"]
                    + [($cfg.statuses // {}) | to_entries[]
                       | select(.value as $c | ["todo", "in_progress", "done", "canceled"] | index($c) | not)
                       | "status \"\(.key)\" has category \"\(.value)\": expected todo, in_progress, done or canceled"])}'
}

gitlab_board_list() {
    gitlab_env
    gitlab_bl_doc=$(gitlab_rest_all "projects/$GL_ID/boards?per_page=100") || return $?
    printf '%s' "$gitlab_bl_doc" | _jq -c --arg web "$GL_WEB" ''"$BOARD_LIB"' map(gl_board($web))'
}

gitlab_board_view() {
    gitlab_env
    gitlab_bv_doc=$(gitlab_board_doc) || return $?
    printf '%s' "$gitlab_bv_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg web "$GL_WEB" '
        '"$BOARD_LIB"'
        (.lists | sort_by(.position) | map(.label.name | values)) as $lists
        | {id: (.id | tostring), name, kind: "gitlab", url: "\($web)/-/boards/\(.id)",
           columns: ($lists | map({name: ., statuses: [.]})),
           statuses: [gl_status_names($cfg)[] | {name: .} | make_status($cfg)]}'
}

gitlab_api_call() {
    gitlab_env
    gitlab_ac_status=0
    board_exec "$GL_CLI" api --hostname "$BOARD_HOST" "$@" || gitlab_ac_status=$?
    gitlab_check "$gitlab_ac_status" || return $?
    cat "$BOARD_OUT"
}

# Usage: gitlab_init_discover <url> <repo>
# Any page of a project will do: the part before /-/ is the project, on any host.
gitlab_init_discover() {
    BOARD_HOST=${1#*://}
    BOARD_HOST=${BOARD_HOST%%/*}
    case $BOARD_HOST in
        '' | *[!A-Za-z0-9.:-]*) board_usage_die "--url has a bad host: '$BOARD_HOST'" ;;
    esac
    gitlab_project_of "$1"
    [ -n "$GL_PATH" ] || board_usage_die "--url must be a project URL: https://$BOARD_HOST/<group>/<project>"
    case $1 in
        */-/boards/*)
            GL_BOARD=${1##*/-/boards/}
            GL_BOARD=${GL_BOARD%%[/?]*}
            board_require_int "the board in --url" "$GL_BOARD"
            ;;
    esac
    gitlab_id_doc=$(gitlab_board_doc) || return $?
    printf '%s' "$gitlab_id_doc" | _jq -c --arg url "$GL_WEB" '
        '"$BOARD_LIB"'
        (.lists | sort_by(.position) | map(.label.name | values)) as $names
        | {board: {kind: "gitlab", cli: "glab", url: $url, project: "#", issue_uri: "/-/work_items/{ticket}"},
           target: {board: .id},
           statuses: ([$names[] | select(guess_category != null) | {key: ., value: guess_category}] | from_entries),
           unplaced: [$names[] | select(guess_category == null)]}'
}

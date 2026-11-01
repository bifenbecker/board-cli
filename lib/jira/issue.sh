# shellcheck shell=sh

# The sprint is a custom field whose id differs per site, so it is found by what it is, not by its
# name. Sets JIRA_SPRINT_FIELD, empty on a site with no sprints.
jira_sprint_field() {
    if [ ! -f "$BOARD_TMP/jira.sprint" ]; then
        jira_sf_doc=$(jira_call GET /rest/api/2/field) || return $?
        printf '%s' "$jira_sf_doc" | _jq -r '
            [.[] | select(.schema.custom? == "com.pyxis.greenhopper.jira:gh-sprint") | .id] | first // ""' \
            >"$BOARD_TMP/jira.sprint"
    fi
    JIRA_SPRINT_FIELD=$(cat "$BOARD_TMP/jira.sprint")
}

# Usage: jira_fetch <id> [fields]  — the raw issue.
jira_fetch() {
    jira_safe "<id>" "$1"
    jira_call GET "/rest/api/2/issue/$1?fields=${2:-$JIRA_FIELDS}"
}

jira_normalise() {
    _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg base "$JIRA_BASE" --arg sprint "$JIRA_SPRINT_FIELD" '
        '"$BOARD_LIB"' jira_issue($cfg; $base; $sprint)'
}

jira_issue_view() {
    jira_safe "<id>" "$1"
    jira_sprint_field || return $?
    jira_iv_doc=$(jira_fetch "$1" "$JIRA_FIELDS${JIRA_SPRINT_FIELD:+,$JIRA_SPRINT_FIELD}") || return $?
    printf '%s' "$jira_iv_doc" | jira_normalise
}

# The answer that ends a write. The write is done whatever happens to this read: a plain failure
# here would invite a second one.
jira_final_view() {
    jira_issue_view "$1" || jira_stop "$?" "$1" "the change went through, but the issue could not be read back"
}

# Usage: jira_step <id> <what> <command...>  — a step after the first write.
jira_step() {
    jira_sp_id=$1
    jira_sp_what=$2
    shift 2
    "$@" || jira_stop "$?" "$jira_sp_id" "the rest went through, $jira_sp_what did not"
}

# --- people --------------------------------------------------------------------------------

jira_me() {
    jira_me_doc=$(jira_call GET /rest/api/2/myself) || return $?
    printf '%s' "$jira_me_doc" | _jq -r '.accountId // .name'
}

# An accountId is opaque and no search takes it, so what looks like one is used as it is.
jira_looks_like_account() {
    case $1 in
        *:*) return 0 ;;
    esac
    [ "${#1}" = 24 ] && case $1 in *[!0-9a-f]*) false ;; esac
}

# Usage: jira_user_id <@me|name|id>  — what the assignee field takes on this installation.
jira_user_id() {
    if [ "$1" = @me ]; then
        jira_me
        return $?
    fi
    jira_require_project
    if [ -n "$JIRA_CLOUD" ]; then
        if jira_looks_like_account "$1"; then
            printf '%s' "$1"
            return 0
        fi
        jira_ui_param=query
    else
        jira_ui_param=username
    fi
    jira_ui_doc=$(jira_call GET "/rest/api/2/user/assignable/search?project=$JIRA_PROJECT&$jira_ui_param=$(board_urlencode "$1")&maxResults=50") || return $?
    # An exact match wins, so a search for Ann does not stop at Anna.
    jira_ui_hit=$(printf '%s' "$jira_ui_doc" | _jq -c --arg q "$1" '
        '"$BOARD_LIB"'
        def exact: [.accountId, .name, .displayName, .emailAddress] | any(.[]; ieq($q));
        (map(select(exact))) as $exact
        | (if ($exact | length) == 1 then $exact else . end)
        | map(jira_user)')
    case $(printf '%s' "$jira_ui_hit" | _jq -r length) in
        0)
            board_warn "no member '$1' can be assigned in $JIRA_PROJECT"
            return "$BOARD_EXIT_NOT_FOUND"
            ;;
        1) printf '%s' "$jira_ui_hit" | _jq -r '.[0].id' ;;
        *)
            board_warn "'$1' matches several members: $(printf '%s' "$jira_ui_hit" | _jq -r 'map("\(.name) (\(.id))") | join(", ")')"
            return "$BOARD_EXIT_ERROR"
            ;;
    esac
}

# Usage: jira_user_ids <JSON array of names>  — the same array of ids.
jira_user_ids() {
    jira_us_names=$(printf '%s' "$1" | _jq -r '.[]') || return 1
    jira_us_ids=''
    while IFS= read -r jira_us_name; do
        [ -n "$jira_us_name" ] || continue
        jira_us_id=$(jira_user_id "$jira_us_name") || return $?
        jira_us_ids=$(board_list_add "$jira_us_ids" "$jira_us_id")
    done <<EOF
$jira_us_names
EOF
    printf '%s' "$jira_us_ids" | _jq -Rsc 'split("\n") | map(select(. != ""))'
}

# --- list ----------------------------------------------------------------------------------

jira_list_page() {
    jira_lp_doc=$(printf '%s' "$JIRA_SEARCH" | _jq -c --arg c "$1" --arg cloud "$JIRA_CLOUD" '
        if $c == "" then . elif $cloud == "1" then .nextPageToken = $c else .startAt = ($c | tonumber) end' |
        jira_send POST "$JIRA_SEARCH_PATH") || return $?
    if [ -z "$1" ] && printf '%s' "$jira_lp_doc" | _jq -e '.issues == []' >/dev/null; then
        jira_login_check || return $?
    fi
    printf '%s' "$jira_lp_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg base "$JIRA_BASE" \
        --arg sprint "$JIRA_SPRINT_FIELD" --argjson f "$JIRA_FILTER" '
        '"$BOARD_LIB"' jira_search_page($cfg; $base; $sprint; $f)'
}

jira_issue_list() {
    jira_require_project
    JIRA_FILTER=$(cat)
    jira_il_who=$(printf '%s' "$JIRA_FILTER" | _jq -r '.assignee // ""')
    case $jira_il_who in
        '' | @me | none) ;;
        *)
            jira_il_id=$(jira_user_id "$jira_il_who") || return $?
            JIRA_FILTER=$(printf '%s' "$JIRA_FILTER" | _jq -c --arg id "$jira_il_id" '.assignee = $id')
            ;;
    esac
    # Nothing is canceled by Jira itself: with no status declared, no issue can be.
    if [ "$(printf '%s\n%s\n' "$JIRA_FILTER" "$BOARD_CONFIG_JSON" | _jq -sr \
        '.[0].category == "canceled" and ((.[1].statuses // {}) | length == 0) and .[0].status == null')" = true ]; then
        printf '[]'
        return 0
    fi
    jira_sprint_field || return $?
    JIRA_SEARCH_PATH=/rest/api/2/search
    [ -z "$JIRA_CLOUD" ] || JIRA_SEARCH_PATH=/rest/api/2/search/jql
    # A page no larger than the limit, unless issues are dropped here after it is read.
    JIRA_SEARCH=$(printf '%s' "$JIRA_FILTER" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        --arg project "$JIRA_PROJECT" --arg fields "$JIRA_FIELDS${JIRA_SPRINT_FIELD:+,$JIRA_SPRINT_FIELD}" '
        '"$BOARD_LIB"'
        {jql: jira_jql($cfg; $project), fields: ($fields | split(",")),
         maxResults: (if .limit == null or (($cfg.statuses // {}) | length > 0) then 100
                      else ([.limit, 100] | min) end)}')
    jira_il_limit=$(printf '%s' "$JIRA_FILTER" | _jq -r '.limit // "all"')
    board_paged jira_list_page "$jira_il_limit"
}

# --- status --------------------------------------------------------------------------------

# Exit 2 before a write, so a bad name cannot leave half an edit behind.
jira_status_exists() {
    board_provider_load status
    jira_se_doc=$(jira_status_list) || return $?
    printf '%s' "$jira_se_doc" | _jq -e --arg s "$1" ''"$BOARD_LIB"' any(.[]; .name | ieq($s))' >/dev/null ||
        board_usage_die "no status '$1': the board has $(printf '%s' "$jira_se_doc" | _jq -r 'map(.name) | join(", ")')"
}

jira_transitions() {
    jira_call GET "/rest/api/2/issue/$1/transitions"
}

# Usage: jira_transition <id> <transition id>
jira_transition() {
    _jq -nc --arg t "$2" '{transition: {id: $t}}' |
        jira_send POST "/rest/api/2/issue/$1/transitions" >/dev/null
}

# Decides a move before anything is written. Sets JIRA_MOVE_ID to the transition, empty when the
# issue is already there. Usage: jira_move_plan <id> <status>
jira_move_plan() {
    JIRA_MOVE_ID=''
    jira_mv_doc=$(jira_fetch "$1" status) || return $?
    if printf '%s' "$jira_mv_doc" | _jq -e --arg s "$2" ''"$BOARD_LIB"' .fields.status.name | ieq($s)' >/dev/null; then
        return 0
    fi
    jira_mv_list=$(jira_transitions "$1") || return $?
    JIRA_MOVE_ID=$(printf '%s' "$jira_mv_list" | _jq -r --arg s "$2" '
        '"$BOARD_LIB"' [.transitions[] | select(.to.name | ieq($s)) | .id] | first // ""')
    if [ -z "$JIRA_MOVE_ID" ]; then
        jira_status_exists "$2" || return $?
        board_warn "the workflow has no transition from here to '$2': it has $(printf '%s' "$jira_mv_list" | _jq -r '[.transitions[].to.name] | join(", ")')"
        return "$BOARD_EXIT_ERROR"
    fi
}

# Usage: jira_move <id> <status>  — a move to where it already is succeeds.
jira_move() {
    jira_move_plan "$1" "$2" || return $?
    [ -z "$JIRA_MOVE_ID" ] || jira_transition "$1" "$JIRA_MOVE_ID"
}

# The first status of a category the workflow can reach from here. Usage: jira_move_to <id> <category>
jira_move_to() {
    jira_mt_list=$(jira_transitions "$1") || return $?
    jira_mt_id=$(printf '%s' "$jira_mt_list" | _jq -r --arg c "$2" --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        [.transitions[] | select((.to | jira_status | make_status($cfg) | .category) == $c) | .id] | first // ""')
    if [ -z "$jira_mt_id" ]; then
        board_provider_load status
        jira_mt_all=$(jira_status_list) || return $?
        printf '%s' "$jira_mt_all" | _jq -e --arg c "$2" 'any(.[]; .category == $c)' >/dev/null ||
            board_usage_die "no status has category $2: declare one in [board.statuses]"
        board_warn "the workflow has no transition from here to a $2 status: it has $(printf '%s' "$jira_mt_list" | _jq -r '[.transitions[].to.name] | join(", ")')"
        return "$BOARD_EXIT_ERROR"
    fi
    jira_transition "$1" "$jira_mt_id"
}

# Usage: jira_category <id>  — the category of the status the issue is in.
jira_category() {
    jira_ca_doc=$(jira_fetch "$1" status) || return $?
    printf '%s' "$jira_ca_doc" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"' .fields.status | jira_status | make_status($cfg) | .category // ""'
}

jira_issue_move() {
    jira_move "$1" "$2" || return $?
    jira_final_view "$1"
}

jira_issue_close() {
    jira_ic_cat=$(jira_category "$1") || return $?
    if [ "$jira_ic_cat" != "$2" ]; then
        jira_move_to "$1" "$2" || return $?
    fi
    jira_final_view "$1"
}

jira_issue_reopen() {
    if [ -n "$2" ]; then
        jira_move "$1" "$2" || return $?
    else
        jira_ir_cat=$(jira_category "$1") || return $?
        case $jira_ir_cat in
            'done' | canceled) jira_move_to "$1" todo || return $? ;;
        esac
    fi
    jira_final_view "$1"
}

# --- parent --------------------------------------------------------------------------------

# Usage: jira_type_id <name>  — an issue type of the project by name, or nothing.
jira_type_id() {
    jira_ti_doc=$(jira_project) || return $?
    printf '%s' "$jira_ti_doc" | _jq -r --arg n "$1" '
        '"$BOARD_LIB"' [.issueTypes[] | select(.name | ieq($n)) | .id] | first // ""'
}

# The name of the project's subtask type, or exit 3.
jira_subtask_type() {
    jira_su_doc=$(jira_project) || return $?
    jira_su_name=$(printf '%s' "$jira_su_doc" | _jq -r '[.issueTypes[] | select(.subtask) | .name] | first // ""')
    [ -n "$jira_su_name" ] || {
        board_warn "project $JIRA_PROJECT has no subtask type"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    printf '%s' "$jira_su_name"
}

jira_default_type() {
    jira_dt_type=$(board_config_get .defaults.type)
    printf '%s' "${jira_dt_type:-Task}"
}

# Usage: jira_bulk_move <id> <target>  — target is KEY,typeId or KEY,typeId,parent. Only this API
# changes an issue between levels, and it runs as a task to wait for.
jira_bulk_move() {
    jira_bm_first=1
    [ ! -f "$BOARD_TMP/jira.wrote" ] || jira_bm_first=''
    jira_bm_doc=$(_jq -nc --arg id "$1" --arg target "$2" '
        {sendBulkNotification: false,
         targetToSourcesMapping: {($target): {
             inferClassificationDefaults: true, inferFieldDefaults: true, inferStatusDefaults: true,
             inferSubtaskTypeDefault: true, issueIdsOrKeys: [$id]}}}' |
        jira_send POST /rest/api/2/bulk/issues/move) || return $?
    jira_bm_task=$(printf '%s' "$jira_bm_doc" | _jq -r '.taskId | tostring')
    jira_safe "the task of a move" "$jira_bm_task"
    jira_bm_left=$BOARD_TIMEOUT
    while [ "$jira_bm_left" -gt 0 ]; do
        jira_bm_doc=$(jira_call GET "/rest/api/2/task/$jira_bm_task") || return $?
        case $(printf '%s' "$jira_bm_doc" | _jq -r '.status | tostring') in
            COMPLETE)
                printf '%s' "$jira_bm_doc" | _jq -e '(.result.failedIssues // {}) == {}' >/dev/null && return 0
                board_warn "Jira did not move $1: $(printf '%s' "$jira_bm_doc" | _jq -c '.result.failedIssues')"
                ;;
            ENQUEUED | RUNNING)
                sleep 1
                jira_bm_left=$((jira_bm_left - 1))
                continue
                ;;
            *) board_warn "Jira did not move $1: $(printf '%s' "$jira_bm_doc" | _jq -r '.message // .status | tostring')" ;;
        esac
        # Accepted, then refused: nothing changed, so the request does not count as a write.
        [ -z "$jira_bm_first" ] || rm -f "$BOARD_TMP/jira.wrote"
        return "$BOARD_EXIT_ERROR"
    done
    board_timed_out
}

# Decides what a --parent asks for, before anything is written. A plain edit takes a parent one
# level up. Between issues of one level, the child must become a subtask, which is a change of type.
# Sets JIRA_PARENT_EDIT to true for a plain edit, and JIRA_PARENT_MOVE to a target of jira_bulk_move.
# Usage: jira_parent_plan <id> <parent>
jira_parent_plan() {
    JIRA_PARENT_EDIT='' JIRA_PARENT_MOVE=''
    jira_pp_child=$(jira_fetch "$1" issuetype) || return $?
    jira_pp_parent=$(jira_fetch "$2" issuetype) || return $?
    jira_pp_step=$(printf '%s\n%s\n' "$jira_pp_child" "$jira_pp_parent" | _jq -sr '
        map(.fields.issuetype) as [$c, $p]
        | if ($c.hierarchyLevel == null) then (if $c.subtask then "edit" elif $p.subtask then "none" else "move" end)
          elif $c.hierarchyLevel == $p.hierarchyLevel - 1 then "edit"
          elif $c.hierarchyLevel == 0 and $p.hierarchyLevel == 0 then "move"
          else "none" end')
    case $jira_pp_step in
        edit) JIRA_PARENT_EDIT=true ;;
        move)
            [ -n "$JIRA_CLOUD" ] || {
                board_warn "Data Center has no API to turn $1 into a subtask: move it in the browser"
                return "$BOARD_EXIT_UNSUPPORTED"
            }
            jira_pp_type=$(jira_subtask_type) || return $?
            jira_pp_id=$(jira_type_id "$jira_pp_type") || return $?
            JIRA_PARENT_MOVE=$JIRA_PROJECT,$jira_pp_id,$2
            ;;
        *)
            board_warn "Jira has no way to put $1 under $2: $(printf '%s\n%s\n' "$jira_pp_child" "$jira_pp_parent" |
                _jq -sr 'map(.fields.issuetype.name) | "a \(.[0]) cannot be a child of a \(.[1])"')"
            return "$BOARD_EXIT_UNSUPPORTED"
            ;;
    esac
}

# The same for --clear parent. A subtask must have a parent, so it first stops being a subtask.
# Usage: jira_parent_clear_plan <id>
jira_parent_clear_plan() {
    JIRA_PARENT_EDIT='' JIRA_PARENT_MOVE=''
    jira_pc_doc=$(jira_fetch "$1" issuetype,parent) || return $?
    case $(printf '%s' "$jira_pc_doc" | _jq -r '
        if .fields.parent == null then "none" elif .fields.issuetype.subtask then "move" else "edit" end') in
        none) ;;
        edit) JIRA_PARENT_EDIT=true ;;
        move)
            [ -n "$JIRA_CLOUD" ] || {
                board_warn "Data Center has no API to turn subtask $1 into an issue: move it in the browser"
                return "$BOARD_EXIT_UNSUPPORTED"
            }
            jira_pc_type=$(jira_default_type)
            jira_pc_id=$(jira_type_id "$jira_pc_type") || return $?
            [ -n "$jira_pc_id" ] || {
                board_warn "project $JIRA_PROJECT has no type '$jira_pc_type' to turn subtask $1 into: set [board.defaults] type"
                return "$BOARD_EXIT_UNSUPPORTED"
            }
            JIRA_PARENT_MOVE=$JIRA_PROJECT,$jira_pc_id
            ;;
    esac
}

# --- write ---------------------------------------------------------------------------------

# Cloud refuses to empty a priority: Specify the Priority (id or name).
jira_check_priority() {
    [ -n "$JIRA_CLOUD" ] || return 0
    if printf '%s' "$1" | _jq -e '.priority == "none" or ((.clear // []) | index("priority") != null)' >/dev/null; then
        board_warn "Jira Cloud keeps a priority on every issue: set another one instead of none"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
}

# Usage: jira_milestone_id <name>  — a version of the project, or exit 4.
jira_milestone_id() {
    jira_mi_doc=$(jira_call GET "/rest/api/2/project/$JIRA_PROJECT/versions") || return $?
    jira_mi_id=$(printf '%s' "$jira_mi_doc" | _jq -r --arg m "$1" '
        '"$BOARD_LIB"' [.[] | select(.name | ieq($m)) | .id] | first // ""')
    [ -n "$jira_mi_id" ] || {
        board_warn "no milestone '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$jira_mi_id"
}

# Merges one key into a JSON object of resolved ids. Usage: jira_ids_set <object> <key> <JSON value>
jira_ids_set() {
    printf '%s' "$1" | _jq -c --arg k "$2" --argjson v "$3" '. + {($k): $v}'
}

# What is left after the issue itself: a move between levels, a sprint.
# Usage: jira_finish <id> <intent> <sprint id>
jira_finish() {
    if [ -n "${JIRA_PARENT_MOVE:-}" ]; then
        jira_step "$1" "the parent" jira_bulk_move "$1" "$JIRA_PARENT_MOVE" || return $?
    fi
    if [ -n "$3" ]; then
        jira_step "$1" "the sprint" jira_sprint_assign "$1" "$3" || return $?
    elif printf '%s' "$2" | _jq -e '(.clear // []) | index("sprint") != null' >/dev/null; then
        jira_step "$1" "the sprint" jira_sprint_clear "$1" || return $?
    fi
}

jira_issue_create() {
    jira_require_project
    jira_cr_intent=$(cat)
    jira_check_priority "$jira_cr_intent" || return $?
    if printf '%s' "$jira_cr_intent" | _jq -e '.assignees | length > 1' >/dev/null; then
        board_warn "Jira has one assignee on an issue"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    eval "$(printf '%s' "$jira_cr_intent" | _jq -r '
        def s: . // "" | tostring;
        @sh "jira_cr_status=\(.status | s) jira_cr_type=\(.type | s) jira_cr_parent=\(.parent | s) jira_cr_sprint=\(.sprint | s) jira_cr_milestone=\(.milestone | s) jira_cr_who=\(.assignees[0] | s)"')"
    [ -z "$jira_cr_status" ] || jira_status_exists "$jira_cr_status" || return $?
    jira_cr_ids='{}'
    if [ -n "$jira_cr_who" ]; then
        jira_cr_id=$(jira_user_id "$jira_cr_who") || return $?
        jira_cr_ids=$(jira_ids_set "$jira_cr_ids" assignee "$(_jq -n --arg v "$jira_cr_id" '$v')")
    fi
    if [ -n "$jira_cr_milestone" ]; then
        jira_cr_id=$(jira_milestone_id "$jira_cr_milestone") || return $?
        jira_cr_ids=$(jira_ids_set "$jira_cr_ids" milestone "$(_jq -n --arg v "$jira_cr_id" '$v')")
    fi
    if [ -n "$jira_cr_parent" ]; then
        jira_cr_ids=$(jira_ids_set "$jira_cr_ids" parent "$(_jq -n --arg v "$jira_cr_parent" '$v')")
        # The command puts the declared default in the intent, so that type is not a choice here:
        # the default is an ordinary type, which Jira refuses under anything but an epic.
        if [ -z "$jira_cr_type" ] || [ "$jira_cr_type" = "$(board_config_get .defaults.type)" ]; then
            jira_cr_doc=$(jira_fetch "$jira_cr_parent" issuetype) || return $?
            # Under an epic a child is an ordinary issue; under anything else it is a subtask.
            if [ "$(printf '%s' "$jira_cr_doc" | _jq -r '.fields.issuetype.hierarchyLevel // 0 | tostring')" -gt 0 ]; then
                jira_cr_type=$(jira_default_type)
            else
                jira_cr_type=$(jira_subtask_type) || return $?
            fi
        fi
    fi
    [ -n "$jira_cr_type" ] || jira_cr_type=$(jira_default_type)
    jira_cr_sprint_id=''
    if [ -n "$jira_cr_sprint" ]; then
        board_provider_load sprint
        jira_cr_sprint_id=$(jira_sprint_id "$jira_cr_sprint") || return $?
    fi
    jira_cr_doc=$(printf '%s' "$jira_cr_intent" | _jq -c --arg project "$JIRA_PROJECT" --arg type "$jira_cr_type" \
        --arg cloud "$JIRA_CLOUD" --argjson ids "$jira_cr_ids" '
        '"$BOARD_LIB"'
        {fields: (jira_fields($cloud; $ids) + {project: {key: $project}, issuetype: {name: $type}, labels})}' |
        jira_send POST /rest/api/2/issue) || return $?
    jira_cr_key=$(printf '%s' "$jira_cr_doc" | _jq -r .key)
    if [ -n "$jira_cr_status" ]; then
        jira_step "$jira_cr_key" "the status" jira_move "$jira_cr_key" "$jira_cr_status" || return $?
    fi
    jira_finish "$jira_cr_key" "$jira_cr_intent" "$jira_cr_sprint_id" || return $?
    jira_final_view "$jira_cr_key"
}

# Who the issue should be assigned to after an edit. Prints the ids object with assignee set, or
# as it came when nothing changes. Usage: jira_edit_assignee <id> <intent> <ids>
jira_edit_assignee() {
    if printf '%s' "$2" | _jq -e '(.add_assignees + .remove_assignees) | length == 0' >/dev/null; then
        printf '%s' "$3"
        return 0
    fi
    jira_ea_add=$(jira_user_ids "$(printf '%s' "$2" | _jq -c .add_assignees)") || return $?
    jira_ea_del=$(jira_user_ids "$(printf '%s' "$2" | _jq -c .remove_assignees)") || return $?
    jira_ea_doc=$(jira_fetch "$1" assignee) || return $?
    jira_ea_now=$(printf '%s' "$jira_ea_doc" | _jq -c '[.fields.assignee | select(. != null) | .accountId // .name]')
    jira_ea_new=$(_jq -nc --argjson now "$jira_ea_now" --argjson add "$jira_ea_add" --argjson del "$jira_ea_del" \
        '($now + $add | unique) - $del')
    if [ "$(printf '%s' "$jira_ea_new" | _jq -r length)" -gt 1 ]; then
        board_warn "Jira has one assignee on an issue: remove the current one in the same call"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    if [ "$jira_ea_new" = "$jira_ea_now" ]; then
        printf '%s' "$3"
        return 0
    fi
    jira_ids_set "$3" assignee "$(printf '%s' "$jira_ea_new" | _jq -c '.[0]')"
}

jira_issue_edit() {
    jira_safe "<id>" "$1"
    jira_require_project
    jira_ie_intent=$(cat)
    jira_check_priority "$jira_ie_intent" || return $?
    eval "$(printf '%s' "$jira_ie_intent" | _jq -r '
        def s: . // "" | tostring;
        @sh "jira_ie_status=\(.status | s) jira_ie_parent=\(.parent | s) jira_ie_sprint=\(.sprint | s) jira_ie_milestone=\(.milestone | s) jira_ie_clear_parent=\((.clear | index("parent")) != null | tostring)"')"
    JIRA_MOVE_ID=''
    [ -z "$jira_ie_status" ] || jira_move_plan "$1" "$jira_ie_status" || return $?
    jira_ie_ids=$(jira_edit_assignee "$1" "$jira_ie_intent" '{}') || return $?
    if [ -n "$jira_ie_milestone" ]; then
        jira_ie_id=$(jira_milestone_id "$jira_ie_milestone") || return $?
        jira_ie_ids=$(jira_ids_set "$jira_ie_ids" milestone "$(_jq -n --arg v "$jira_ie_id" '$v')")
    fi
    JIRA_PARENT_EDIT='' JIRA_PARENT_MOVE=''
    if [ -n "$jira_ie_parent" ]; then
        jira_parent_plan "$1" "$jira_ie_parent" || return $?
        if [ -n "$JIRA_PARENT_EDIT" ]; then
            jira_ie_ids=$(jira_ids_set "$jira_ie_ids" parent "$(_jq -n --arg v "$jira_ie_parent" '$v')")
        fi
    elif [ "$jira_ie_clear_parent" = true ]; then
        jira_parent_clear_plan "$1" || return $?
        if [ -n "$JIRA_PARENT_EDIT" ]; then
            jira_ie_ids=$(jira_ids_set "$jira_ie_ids" parent null)
        fi
    fi
    jira_ie_sprint_id=''
    if [ -n "$jira_ie_sprint" ]; then
        board_provider_load sprint
        jira_ie_sprint_id=$(jira_sprint_id "$jira_ie_sprint") || return $?
    elif printf '%s' "$jira_ie_intent" | _jq -e '.clear | index("sprint") != null' >/dev/null; then
        board_provider_load sprint
        jira_sprints active >/dev/null || return $?
    fi
    jira_ie_patch=$(printf '%s' "$jira_ie_intent" | _jq -c --arg cloud "$JIRA_CLOUD" --argjson ids "$jira_ie_ids" '
        '"$BOARD_LIB"'
        jira_fields($cloud; $ids) as $fields
        | jira_label_update as $labels
        | (if $fields == {} then {} else {fields: $fields} end)
          + (if $labels == [] then {} else {update: {labels: $labels}} end)')
    if [ "$jira_ie_patch" != '{}' ]; then
        printf '%s' "$jira_ie_patch" | jira_send PUT "/rest/api/2/issue/$1" >/dev/null || return $?
    fi
    if [ -n "$JIRA_MOVE_ID" ]; then
        jira_step "$1" "the status" jira_transition "$1" "$JIRA_MOVE_ID" || return $?
    fi
    jira_finish "$1" "$jira_ie_intent" "$jira_ie_sprint_id" || return $?
    jira_final_view "$1"
}

jira_issue_delete() {
    jira_safe "<id>" "$1"
    jira_call DELETE "/rest/api/2/issue/$1" >/dev/null
}

# --- comments ------------------------------------------------------------------------------

jira_comment_page() {
    jira_cp_doc=$(jira_call GET "$(jira_paged_url "/rest/api/2/issue/$JIRA_COMMENT_KEY/comment" "$1" 100)") || return $?
    printf '%s' "$jira_cp_doc" | _jq -c --arg base "$JIRA_BASE" --arg key "$JIRA_COMMENT_KEY" '
        '"$BOARD_LIB"'
        (.startAt + (.comments | length)) as $next
        | {nodes: [.comments[] | jira_comment($base; $key)],
           has_next: ((.comments | length) > 0 and $next < .total), end_cursor: $next}'
}

jira_issue_comment_list() {
    jira_safe "<id>" "$1"
    JIRA_COMMENT_KEY=$1
    board_paged jira_comment_page all
}

# Usage: jira_comment_write <method> <path> <key>  — the intent on stdin.
jira_comment_write() {
    jira_cw_doc=$(_jq -c ''"$BOARD_LIB"' {body: (.body | md2wiki)}' | jira_send "$1" "$2") || return $?
    printf '%s' "$jira_cw_doc" | _jq -c --arg base "$JIRA_BASE" --arg key "$3" ''"$BOARD_LIB"' jira_comment($base; $key)'
}

jira_issue_comment_add() {
    jira_safe "<id>" "$1"
    jira_comment_write POST "/rest/api/2/issue/$1/comment" "$1"
}

jira_issue_comment_edit() {
    jira_safe "<id>" "$1"
    jira_safe "<comment-id>" "$2"
    jira_comment_write PUT "/rest/api/2/issue/$1/comment/$2" "$1"
}

jira_issue_comment_delete() {
    jira_safe "<id>" "$1"
    jira_safe "<comment-id>" "$2"
    jira_call DELETE "/rest/api/2/issue/$1/comment/$2" >/dev/null
}

# --- links ---------------------------------------------------------------------------------

jira_issue_link_list() {
    jira_ll_doc=$(jira_fetch "$1" issuelinks) || return $?
    printf '%s' "$jira_ll_doc" | _jq -c ''"$BOARD_LIB"' .fields.issuelinks | jira_links | map({type, id})'
}

# The link types of the site are the source: a site may have renamed or removed one.
# Usage: jira_link_type_name <blocks|blocked-by|relates|duplicates>
jira_link_type_name() {
    case $1 in
        blocks | blocked-by) jira_lt_want=Blocks ;;
        duplicates) jira_lt_want=Duplicate ;;
        *) jira_lt_want=Relates ;;
    esac
    jira_lt_doc=$(jira_call GET /rest/api/2/issueLinkType) || return $?
    jira_lt_name=$(printf '%s' "$jira_lt_doc" | _jq -r --arg n "$jira_lt_want" '
        '"$BOARD_LIB"' [.issueLinkTypes[] | select(.name | ieq($n)) | .name] | first // ""')
    [ -n "$jira_lt_name" ] || {
        board_warn "this site has no link type '$jira_lt_want'"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    printf '%s' "$jira_lt_name"
}

jira_issue_link_add() {
    jira_safe "<other-id>" "$2"
    jira_la_doc=$(jira_fetch "$1" issuelinks) || return $?
    if ! printf '%s' "$jira_la_doc" | _jq -e --arg id "$2" --arg t "$3" '
        '"$BOARD_LIB"' .fields.issuelinks | jira_links | any(.[]; .id == $id and .type == $t)' >/dev/null; then
        jira_la_name=$(jira_link_type_name "$3") || return $?
        # Measured: inward A, outward B reads on A as "A blocks B".
        jira_la_in=$1 jira_la_out=$2
        if [ "$3" = blocked-by ]; then
            jira_la_in=$2 jira_la_out=$1
        fi
        _jq -nc --arg t "$jira_la_name" --arg a "$jira_la_in" --arg b "$jira_la_out" \
            '{type: {name: $t}, inwardIssue: {key: $a}, outwardIssue: {key: $b}}' |
            jira_send POST /rest/api/2/issueLink >/dev/null || return $?
    fi
    jira_final_view "$1"
}

jira_issue_link_remove() {
    jira_safe "<other-id>" "$2"
    jira_lr_doc=$(jira_fetch "$1" issuelinks) || return $?
    jira_lr_ids=$(printf '%s' "$jira_lr_doc" | _jq -r --arg id "$2" --arg t "$3" '
        '"$BOARD_LIB"' .fields.issuelinks | jira_links | .[] | select(.id == $id and .type == $t) | .link | tostring')
    for jira_lr_id in $jira_lr_ids; do
        jira_safe "a link" "$jira_lr_id"
        jira_call DELETE "/rest/api/2/issueLink/$jira_lr_id" >/dev/null ||
            jira_stop "$?" "$1" "one link went, another did not" || return $?
    done
    jira_final_view "$1"
}

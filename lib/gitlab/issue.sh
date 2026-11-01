# shellcheck shell=sh

# An issue is reached by its iid. Free has no status widget: a status is a label declared in
# [board.statuses], kept in step with the open or closed state, and a priority is a label too.

# Usage: <raw issues as an array> | gitlab_warn_clash
gitlab_warn_clash() {
    _jq -r --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' .[] | gl_clash($cfg)' |
        while IFS= read -r gitlab_wc_line; do
            board_warn "$gitlab_wc_line"
        done
}

# Parent and subtasks exist only on the work item, and links only under their own path.
gitlab_fetch() {
    board_require_int '<id>' "$1"
    gitlab_ft_issue=$(gitlab_rest GET "$GL_ISSUES/$1") || return $?
    gitlab_ft_links=$(gitlab_rest GET "$GL_ISSUES/$1/links") || return $?
    gitlab_ft_tree=$(gitlab_query IssueHierarchy -f "path=$GL_PATH" -f "iid=$1") || return $?
    printf '%s\n%s\n%s\n' "$gitlab_ft_issue" "$gitlab_ft_links" "$gitlab_ft_tree" |
        _jq -sc '{issue: .[0], links: .[1], tree: .[2]}'
}

gitlab_issue_view() {
    gitlab_iv_doc=$(gitlab_fetch "$1") || return $?
    printf '%s' "$gitlab_iv_doc" | _jq -c '[.issue]' | gitlab_warn_clash
    printf '%s' "$gitlab_iv_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' gl_issue($cfg)'
}

# --- list --------------------------------------------------------------------------------

gitlab_list_page() {
    gitlab_lp_page=${1:-1}
    gitlab_lp_doc=$(gitlab_rest GET "$GL_ISSUES?$GL_LIST_QUERY&page=$gitlab_lp_page") || return $?
    printf '%s' "$gitlab_lp_doc" | gitlab_warn_clash
    printf '%s' "$gitlab_lp_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        --argjson filter "$GL_LIST_FILTER" --argjson page "$gitlab_lp_page" '
        '"$BOARD_LIB"'
        {has_next: (length == 100), end_cursor: ($page + 1 | tostring),
         nodes: [.[] | {issue: .} | gl_issue($cfg) | select(gl_keep($filter))
                 | if $filter.parent then .parent = $filter.parent else . end]}'
}

# The subtasks of an issue, as a JSON array of iids.
gitlab_children() {
    board_require_int --parent "$1"
    gitlab_ch_doc=$(gitlab_query IssueHierarchy -f "path=$GL_PATH" -f "iid=$1") || return $?
    printf '%s' "$gitlab_ch_doc" | _jq -c ''"$BOARD_LIB"' [gl_tree.children.nodes[]?.iid]'
}

gitlab_issue_list() {
    GL_LIST_FILTER=$(cat)
    eval "$(printf '%s' "$GL_LIST_FILTER" | _jq -r '
        @sh "gitlab_il_assignee=\(.assignee // "" | tostring) gitlab_il_priority=\(.priority // "" | tostring)",
        @sh "gitlab_il_parent=\(.parent // "" | tostring) gitlab_il_sprint=\(.sprint // "" | tostring)",
        @sh "gitlab_il_limit=\(.limit // "all" | tostring)"')"
    if [ -n "$gitlab_il_sprint" ]; then
        board_provider_load sprint
        gitlab_require_iterations || return $?
    fi
    gitlab_il_label=$(gitlab_priority_label "$gitlab_il_priority") || return $?
    gitlab_il_me=$gitlab_il_assignee
    if [ "$gitlab_il_assignee" = @me ]; then
        gitlab_il_user=$(gitlab_viewer) || return $?
        gitlab_il_me=$(printf '%s' "$gitlab_il_user" | _jq -r .username)
    fi
    gitlab_il_iids=null
    if [ -n "$gitlab_il_parent" ]; then
        gitlab_il_iids=$(gitlab_children "$gitlab_il_parent") || return $?
        if [ "$gitlab_il_iids" = '[]' ]; then
            printf '[]\n'
            return 0
        fi
    fi
    GL_LIST_FILTER=$(printf '%s' "$GL_LIST_FILTER" | _jq -c --arg label "$gitlab_il_label" --arg me "$gitlab_il_me" \
        --argjson iids "$gitlab_il_iids" '
        . + {priority_label: (if $label == "" then null else $label end), iids: $iids}
        | if .assignee then .assignee = $me else . end')
    GL_LIST_QUERY=$(printf '%s' "$GL_LIST_FILTER" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" \
        ''"$BOARD_LIB"' gl_list_query($cfg)')
    board_paged gitlab_list_page "$gitlab_il_limit"
}

# --- write -------------------------------------------------------------------------------

# The issue as it now is, after a write: a read that fails here must not hide that the write went
# through.
gitlab_view_after_write() {
    gitlab_issue_view "$1" || board_partial "$1" "the change went through, but the issue could not be read back"
}

# Prints the id of a work item type. An unknown name is a mistake in the call.
gitlab_type_id() {
    gitlab_ti_doc=$(gitlab_query WorkItemTypes -f "path=$GL_PATH") || return $?
    gitlab_ti_id=$(printf '%s' "$gitlab_ti_doc" | _jq -r --arg t "$1" '
        '"$BOARD_LIB"' [.data.project.workItemTypes.nodes[] | select(.name | ieq($t)) | .id] | first // ""')
    if [ -z "$gitlab_ti_id" ]; then
        board_usage_die "no type '$1': the project has $(printf '%s' "$gitlab_ti_doc" |
            _jq -r '[.data.project.workItemTypes.nodes[].name] | join(", ")')"
    fi
    printf '%s' "$gitlab_ti_id"
}

# Resolves names in an intent into what GitLab takes, and refuses what it cannot do, all before
# the first write. Usage: gitlab_resolve_intent <intent> <the issue as it is now, or {}>
gitlab_resolve_intent() {
    gitlab_ri_intent=$1
    eval "$(printf '%s' "$gitlab_ri_intent" | _jq -r '
        @sh "gitlab_ri_status=\(.status // "" | tostring) gitlab_ri_priority=\(.priority // "" | tostring)",
        @sh "gitlab_ri_milestone=\(.milestone // "" | tostring) gitlab_ri_parent=\(.parent // "" | tostring)",
        @sh "gitlab_ri_sprint=\(.sprint // "" | tostring) gitlab_ri_type=\(.type // "" | tostring)",
        @sh "gitlab_ri_unsprint=\(if (.clear | index("sprint")) then "1" else "" end)",
        @sh "gitlab_ri_people=\(if ((.assignees + .add_assignees + .remove_assignees) | length) > 0 then "1" else "" end)",
        @sh "gitlab_ri_want_me=\(if ((.assignees + .add_assignees + .remove_assignees) | index("@me")) then "1" else "" end)"')"

    gitlab_ri_status_doc=null
    if [ -n "$gitlab_ri_status" ]; then
        gitlab_ri_status_doc=$(gitlab_status_named "$gitlab_ri_status") || return $?
    fi
    gitlab_ri_label=$(gitlab_priority_label "$gitlab_ri_priority") || return $?

    gitlab_ri_type_id=''
    if [ -n "$gitlab_ri_type" ]; then
        gitlab_ri_type_id=$(gitlab_type_id "$gitlab_ri_type") || return $?
    fi

    gitlab_ri_sprint_id=''
    if [ -n "$gitlab_ri_sprint$gitlab_ri_unsprint" ]; then
        board_provider_load sprint
        gitlab_require_iterations || return $?
        if [ -n "$gitlab_ri_sprint" ]; then
            gitlab_ri_sprint_id=$(gitlab_iteration_id "$gitlab_ri_sprint") || return $?
        fi
    fi

    gitlab_ri_parent_id=''
    if [ -n "$gitlab_ri_parent" ]; then
        board_require_int --parent "$gitlab_ri_parent"
        gitlab_ri_doc=$(gitlab_rest GET "$GL_ISSUES/$gitlab_ri_parent") || return $?
        gitlab_ri_parent_id=$(printf '%s' "$gitlab_ri_doc" | _jq -r .id)
    fi

    gitlab_ri_milestone_id=null
    if [ -n "$gitlab_ri_milestone" ]; then
        gitlab_ri_doc=$(gitlab_rest_all "projects/$GL_ID/milestones?include_ancestors=true&per_page=100") || return $?
        gitlab_ri_milestone_id=$(printf '%s' "$gitlab_ri_doc" | _jq -c --arg m "$gitlab_ri_milestone" \
            ''"$BOARD_LIB"' [.[] | select(.title | ieq($m)) | .id] | first // null')
        if [ "$gitlab_ri_milestone_id" = null ]; then
            board_warn "no milestone '$gitlab_ri_milestone'"
            return "$BOARD_EXIT_NOT_FOUND"
        fi
    fi

    # REST takes the whole assignee list as user ids, and it never says who the names were.
    gitlab_ri_ids=null
    if [ -n "$gitlab_ri_people" ]; then
        gitlab_ri_me=null
        if [ -n "$gitlab_ri_want_me" ]; then
            gitlab_ri_me=$(gitlab_viewer) || return $?
        fi
        gitlab_ri_members=$(gitlab_rest_all "projects/$GL_ID/members/all?per_page=100") || return $?
        gitlab_ri_ids=$(printf '%s\n%s\n%s\n%s\n' "$gitlab_ri_intent" "$2" "$gitlab_ri_members" "$gitlab_ri_me" | _jq -sc '
            '"$BOARD_LIB"'
            .[0] as $i | .[1] as $now | .[2] as $members | .[3] as $me
            | def id_of: . as $n
                  | if $n == "@me" then $me.id
                    else ([$members[] | select(.username | ieq($n)) | .id] | first) end;
              ([($i.assignees + $i.add_assignees)[] | {name: ., id: id_of}]) as $add
            | if any($add[]; .id == null)
              then {missing: [$add[] | select(.id == null) | .name]}
              else {ids: ((($now.assignees // []) | map(.id)) - [$i.remove_assignees[] | id_of] + ($add | map(.id)) | unique)}
              end')
        gitlab_ri_missing=$(printf '%s' "$gitlab_ri_ids" | _jq -r '.missing // [] | join(", ")')
        if [ -n "$gitlab_ri_missing" ]; then
            board_warn "no member '$gitlab_ri_missing'"
            return "$BOARD_EXIT_NOT_FOUND"
        fi
        gitlab_ri_ids=$(printf '%s' "$gitlab_ri_ids" | _jq -c .ids)
    fi

    printf '%s' "$gitlab_ri_intent" | _jq -c --arg label "$gitlab_ri_label" --arg parent "$gitlab_ri_parent_id" \
        --arg sprint "$gitlab_ri_sprint_id" --arg type "$gitlab_ri_type_id" --argjson status "$gitlab_ri_status_doc" \
        --argjson milestone "$gitlab_ri_milestone_id" --argjson ids "$gitlab_ri_ids" '
        . + {status_doc: $status, milestone_id: $milestone, assignee_ids: $ids,
             priority_label: (if $label == "" then null else $label end),
             parent_id: (if $parent == "" then null else $parent end),
             sprint_id: (if $sprint == "" then null else $sprint end),
             type_id: (if $type == "" then null else $type end)}'
}

# Usage: gitlab_set_parent <work item id> <parent id, empty to clear>
gitlab_set_parent() {
    if [ -n "$2" ]; then
        gitlab_sp_doc=$(gitlab_query SetParent -f "id=gid://gitlab/WorkItem/$1" -f "parent=gid://gitlab/WorkItem/$2") || return $?
    else
        gitlab_sp_doc=$(gitlab_query SetParent -f "id=gid://gitlab/WorkItem/$1" -F parent=null) || return $?
    fi
    gitlab_sp_why=$(gitlab_refused "$gitlab_sp_doc" workItemUpdate)
    if [ -n "$gitlab_sp_why" ]; then
        board_warn "only a Task can have a parent, and only an Issue can be one; pass --type Task to convert it: $gitlab_sp_why"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    GL_WROTE=1
}

# Usage: gitlab_convert_type <work item id> <type id>
# REST takes issue_type on create, but refuses to change an Issue to a Task.
gitlab_convert_type() {
    gitlab_ct_doc=$(gitlab_query ConvertType -f "id=gid://gitlab/WorkItem/$1" -f "type=$2") || return $?
    gitlab_ct_why=$(gitlab_refused "$gitlab_ct_doc" workItemConvert)
    if [ -n "$gitlab_ct_why" ]; then
        board_warn "$gitlab_ct_why"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    GL_WROTE=1
}

# Usage: gitlab_set_iteration <work item id> <iteration id, empty to clear>
gitlab_set_iteration() {
    if [ -n "$2" ]; then
        gitlab_si_doc=$(gitlab_query SetIteration -f "id=gid://gitlab/WorkItem/$1" -f "iteration=gid://gitlab/Iteration/$2") || return $?
    else
        gitlab_si_doc=$(gitlab_query SetIteration -f "id=gid://gitlab/WorkItem/$1" -F iteration=null) || return $?
    fi
    gitlab_si_why=$(gitlab_refused "$gitlab_si_doc" workItemUpdate)
    if [ -n "$gitlab_si_why" ]; then
        board_warn "$gitlab_si_why"
        return "$BOARD_EXIT_ERROR"
    fi
    GL_WROTE=1
}

# What only the work item takes: type, parent, sprint. Type comes first: --type Task --parent 1
# converts an issue that could not have a parent as it was.
# Usage: gitlab_apply_widgets <work item id> <resolved intent> [convert]
gitlab_apply_widgets() {
    eval "$(printf '%s' "$2" | _jq -r '
        @sh "gitlab_aw_type=\(.type_id // "" | tostring) gitlab_aw_parent=\(.parent_id // "" | tostring)",
        @sh "gitlab_aw_sprint=\(.sprint_id // "" | tostring)",
        @sh "gitlab_aw_unparent=\(if (.clear | index("parent")) then "1" else "" end)",
        @sh "gitlab_aw_unsprint=\(if (.clear | index("sprint")) then "1" else "" end)"')"
    if [ -n "${3:-}" ] && [ -n "$gitlab_aw_type" ]; then
        gitlab_convert_type "$1" "$gitlab_aw_type" || return $?
    fi
    if [ -n "$gitlab_aw_parent$gitlab_aw_unparent" ]; then
        gitlab_set_parent "$1" "$gitlab_aw_parent" || return $?
    fi
    if [ -n "$gitlab_aw_sprint$gitlab_aw_unsprint" ]; then
        gitlab_set_iteration "$1" "$gitlab_aw_sprint" || return $?
    fi
}

gitlab_issue_create() {
    gitlab_ic_intent=$(_jq -c --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' gl_create_defaults($cfg)')
    if printf '%s' "$gitlab_ic_intent" | _jq -e ''"$BOARD_LIB"' .parent and (.type | ieq("Task") | not)' >/dev/null; then
        board_warn "only a Task can have a parent on GitLab: leave out --type, or pass --type Task"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    gitlab_ic_intent=$(gitlab_resolve_intent "$gitlab_ic_intent" '{}') || return $?
    gitlab_ic_new=$(printf '%s' "$gitlab_ic_intent" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        ''"$BOARD_LIB"' gl_create_body($cfg)' | gitlab_rest_body POST "$GL_ISSUES") || return $?
    gitlab_ic_iid=$(printf '%s' "$gitlab_ic_new" | _jq -r .iid)
    gitlab_ic_id=$(printf '%s' "$gitlab_ic_new" | _jq -r .id)
    # POST has no state_event, so a status that means closed takes a second call.
    if printf '%s' "$gitlab_ic_intent" | _jq -e '.status_doc.category == "done" or .status_doc.category == "canceled"' >/dev/null; then
        printf '{"state_event":"close"}' | gitlab_rest_body PUT "$GL_ISSUES/$gitlab_ic_iid" >/dev/null ||
            board_partial "$gitlab_ic_iid" "the issue exists, but could not be closed"
    fi
    gitlab_apply_widgets "$gitlab_ic_id" "$gitlab_ic_intent" ||
        board_partial "$gitlab_ic_iid" "the issue exists, but its parent or sprint could not be set"
    gitlab_view_after_write "$gitlab_ic_iid"
}

gitlab_issue_edit() {
    board_require_int '<id>' "$1"
    gitlab_ie_id=$1
    gitlab_ie_intent=$(cat)
    gitlab_ie_now=$(gitlab_rest GET "$GL_ISSUES/$gitlab_ie_id") || return $?
    gitlab_ie_intent=$(gitlab_resolve_intent "$gitlab_ie_intent" "$gitlab_ie_now") || return $?
    # The widgets go first: this is where GitLab refuses by rule, and then nothing has changed.
    gitlab_apply_widgets "$(printf '%s' "$gitlab_ie_now" | _jq -r .id)" "$gitlab_ie_intent" convert ||
        gitlab_step_failed $? "$gitlab_ie_id" "the type changed, the parent or sprint did not" || return $?
    gitlab_ie_body=$(printf '%s' "$gitlab_ie_intent" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        ''"$BOARD_LIB"' gl_edit_body($cfg)')
    if [ "$gitlab_ie_body" != '{}' ]; then
        printf '%s' "$gitlab_ie_body" | gitlab_rest_body PUT "$GL_ISSUES/$gitlab_ie_id" >/dev/null ||
            gitlab_step_failed $? "$gitlab_ie_id" "the type, parent or sprint changed, the other fields did not" || return $?
    fi
    gitlab_view_after_write "$gitlab_ie_id"
}

# Usage: gitlab_put_status <id> <{name, category}>  — one call, so labels and state change together.
gitlab_put_status() {
    printf '%s' "$2" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' gl_move_body($cfg)' |
        gitlab_rest_body PUT "$GL_ISSUES/$1" >/dev/null
}

gitlab_issue_move() {
    board_require_int '<id>' "$1"
    gitlab_im_doc=$(gitlab_status_named "$2") || return $?
    gitlab_put_status "$1" "$gitlab_im_doc" || return $?
    gitlab_view_after_write "$1"
}

# Without a status of the category the other status labels still go: a closed issue with a todo
# label would read as todo.
gitlab_issue_close() {
    board_require_int '<id>' "$1"
    gitlab_put_status "$1" "$(_jq -nc --arg n "$(gitlab_status_in "$2")" --arg c "$2" \
        '{name: (if $n == "" then null else $n end), category: $c}')" || return $?
    gitlab_view_after_write "$1"
}

gitlab_issue_reopen() {
    if [ -n "$2" ]; then
        gitlab_issue_move "$1" "$2"
        return $?
    fi
    board_require_int '<id>' "$1"
    gitlab_ir_doc=$(gitlab_rest GET "$GL_ISSUES/$1") || return $?
    if [ "$(printf '%s' "$gitlab_ir_doc" | _jq -r .state)" = closed ]; then
        gitlab_put_status "$1" "$(_jq -nc --arg n "$(gitlab_status_in todo)" \
            '{name: (if $n == "" then null else $n end), category: "todo"}')" || return $?
        gitlab_view_after_write "$1"
        return $?
    fi
    gitlab_issue_view "$1"
}

gitlab_issue_delete() {
    board_require_int '<id>' "$1"
    gitlab_rest DELETE "$GL_ISSUES/$1" >/dev/null
}

# --- comments ----------------------------------------------------------------------------

gitlab_issue_comment_list() {
    board_require_int '<id>' "$1"
    gitlab_cl_doc=$(gitlab_rest_all "$GL_ISSUES/$1/notes?per_page=100&sort=asc&order_by=created_at") || return $?
    printf '%s' "$gitlab_cl_doc" | _jq -c --arg web "$GL_WEB" \
        ''"$BOARD_LIB"' map(select(.system == false) | gl_comment($web))'
}

gitlab_issue_comment_add() {
    board_require_int '<id>' "$1"
    gitlab_ca_doc=$(gitlab_rest_body POST "$GL_ISSUES/$1/notes") || return $?
    printf '%s' "$gitlab_ca_doc" | _jq -c --arg web "$GL_WEB" ''"$BOARD_LIB"' gl_comment($web)'
}

gitlab_issue_comment_edit() {
    board_require_int '<id>' "$1"
    board_require_int '<comment-id>' "$2"
    gitlab_ce_doc=$(gitlab_rest_body PUT "$GL_ISSUES/$1/notes/$2") || return $?
    printf '%s' "$gitlab_ce_doc" | _jq -c --arg web "$GL_WEB" ''"$BOARD_LIB"' gl_comment($web)'
}

gitlab_issue_comment_delete() {
    board_require_int '<id>' "$1"
    board_require_int '<comment-id>' "$2"
    gitlab_rest DELETE "$GL_ISSUES/$1/notes/$2" >/dev/null
}

# --- links -------------------------------------------------------------------------------

gitlab_issue_link_list() {
    board_require_int '<id>' "$1"
    gitlab_ll_doc=$(gitlab_rest GET "$GL_ISSUES/$1/links") || return $?
    printf '%s' "$gitlab_ll_doc" | _jq -c ''"$BOARD_LIB"' map(gl_link)'
}

# Usage: gitlab_link_find <links> <other id> <type>  — prints the link id, or nothing.
gitlab_link_find() {
    printf '%s' "$1" | _jq -r --arg other "$2" --arg type "$3" '
        '"$BOARD_LIB"' [.[] | select(gl_link | .id == $other and .type == $type) | .issue_link_id] | first // ""'
}

gitlab_issue_link_add() {
    board_require_int '<id>' "$1"
    board_require_int '<other-id>' "$2"
    case $3 in
        relates) gitlab_la_type=relates_to ;;
        blocks) gitlab_la_type=blocks ;;
        blocked-by) gitlab_la_type=is_blocked_by ;;
        *)
            board_warn "GitLab has no duplicates link"
            return "$BOARD_EXIT_UNSUPPORTED"
            ;;
    esac
    # A second add is a 409. Linking twice has to succeed, and a 409 also means another link type.
    gitlab_la_links=$(gitlab_rest GET "$GL_ISSUES/$1/links") || return $?
    if [ -z "$(gitlab_link_find "$gitlab_la_links" "$2" "$3")" ]; then
        gitlab_la_doc=$(gitlab_rest GET "$GL_ISSUES/$1") || return $?
        # An encoded path here is 404 Project Not Found, unlike in a URL.
        printf '%s' "$gitlab_la_doc" | _jq -c --arg other "$2" --arg type "$gitlab_la_type" \
            '{target_project_id: .project_id, target_issue_iid: ($other | tonumber), link_type: $type}' |
            gitlab_rest_body POST "$GL_ISSUES/$1/links" >/dev/null || return $?
        gitlab_view_after_write "$1"
        return $?
    fi
    gitlab_issue_view "$1"
}

gitlab_issue_link_remove() {
    board_require_int '<id>' "$1"
    gitlab_lr_links=$(gitlab_rest GET "$GL_ISSUES/$1/links") || return $?
    gitlab_lr_id=$(gitlab_link_find "$gitlab_lr_links" "$2" "$3")
    if [ -n "$gitlab_lr_id" ]; then
        gitlab_rest DELETE "$GL_ISSUES/$1/links/$gitlab_lr_id" >/dev/null || return $?
        gitlab_view_after_write "$1"
        return $?
    fi
    gitlab_issue_view "$1"
}

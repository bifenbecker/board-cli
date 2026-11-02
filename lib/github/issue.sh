# shellcheck shell=sh

# An issue is reached by number, owner/repo#number, or PVTI_ for a project item.
# Sets GH_ID_ITEM, or GH_ID_REPO and GH_ID_NUMBER.
github_parse_id() {
    GH_ID_ITEM='' GH_ID_REPO=$GH_REPO GH_ID_NUMBER=''
    case $1 in
        PVTI_*) GH_ID_ITEM=$1 ;;
        */*\#*)
            GH_ID_REPO=${1%\#*}
            GH_ID_NUMBER=${1##*\#}
            ;;
        *) GH_ID_NUMBER=$1 ;;
    esac
    if [ -z "$GH_ID_ITEM" ]; then
        case $GH_ID_NUMBER in
            '' | *[!0-9]*) board_usage_die "<id> must be a number, owner/repo#number or PVTI_..., got '$1'" ;;
        esac
    fi
}

# The whole issue as the board has it. Prints the raw answer: .issue or .item.
github_fetch() {
    github_require_project
    github_parse_id "$1"
    if [ -n "$GH_ID_ITEM" ]; then
        github_ft_doc=$(_jq -nc --arg id "$GH_ID_ITEM" '{id: $id}' | github_field_vars | github_query ItemView) || return $?
        github_ft_doc=$(printf '%s' "$github_ft_doc" | _jq -c '.node // empty')
        [ -n "$github_ft_doc" ] || {
            board_warn "no project item $GH_ID_ITEM"
            return "$BOARD_EXIT_NOT_FOUND"
        }
        if [ "$(printf '%s' "$github_ft_doc" | _jq -r '.content.__typename // ""')" = PullRequest ]; then
            board_warn "$GH_ID_ITEM is a pull request, not an issue"
            return "$BOARD_EXIT_UNSUPPORTED"
        fi
        printf '%s' "$github_ft_doc" | _jq -c '{item: .}'
        return 0
    fi
    github_ft_doc=$(_jq -nc --arg repo "$GH_ID_REPO" --argjson number "$GH_ID_NUMBER" \
        '{owner: ($repo | split("/")[0]), name: ($repo | split("/")[1]), number: $number}' |
        github_field_vars | github_query IssueView) || return $?
    printf '%s' "$github_ft_doc" | _jq -c '{issue: .repository.issue}'
}

# The raw answer of github_fetch into a normalised issue.
github_normalise() {
    _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg repo "$GH_REPO" --argjson number "$GH_NUMBER" --arg owner "$GH_OWNER" '
        '"$BOARD_LIB"'
        if .item then (.item | gh_item($cfg; $repo)) else (.issue | gh_issue($cfg; $repo; $number; $owner)) end'
}

# From a raw answer sets GH_NODE, GH_ITEM, GH_IS_DRAFT, GH_IS_CLOSED, GH_PARENT_NODE and the
# GH_ID_* of github_parse_id. A PVTI_ id of a real issue becomes its number and repository here,
# so every later step works the same for both.
# Usage: github_ids <raw answer> <id>
github_ids() {
    github_parse_id "$2"
    eval "$(printf '%s' "$1" | _jq -r --argjson number "$GH_NUMBER" --arg owner "$GH_OWNER" '
        '"$BOARD_LIB"'
        (if .item then (.item.content // {}) else .issue end) as $c
        | (if .item then .item.id else (.issue.projectItems.nodes | gh_our_item($number; $owner) | .id // "") end) as $item
        | ($c.__typename == "Issue" or (.item | not)) as $is_issue
        | @sh "GH_NODE=\($c.id // "" | tostring) GH_ITEM=\($item | tostring) GH_IS_DRAFT=\(if $is_issue then "" else "1" end)",
          @sh "GH_PARENT_NODE=\($c.parent.id // "" | tostring) GH_IS_CLOSED=\(if $c.state == "CLOSED" then "1" else "" end)",
          (if .item and $is_issue then
              @sh "GH_ID_ITEM='' GH_ID_REPO=\($c.repository.nameWithOwner | tostring) GH_ID_NUMBER=\($c.number | tostring)"
           else empty end)')"
}

github_issue_view() {
    github_iv_doc=$(github_fetch "$1") || return $?
    printf '%s' "$github_iv_doc" | github_normalise
}

# The node id of an issue that can be a parent or a link. A draft has neither.
github_node_of() {
    github_no_doc=$(github_fetch "$1") || return $?
    github_no_id=$(printf '%s' "$github_no_doc" | _jq -r '.issue.id // (.item.content | select(.__typename == "Issue") | .id) // empty')
    [ -n "$github_no_id" ] || {
        board_warn "$1 is a draft item: it cannot be a parent or a link"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    printf '%s' "$github_no_id"
}

# After a failed step: exit 6 with the id once a write went through, else the step's own status.
# Usage: step || { github_stop "$?" <id> <message>; return $?; }
github_stop() {
    [ -z "${GH_WROTE:-}" ] || board_partial "$2" "$3"
    return "$1"
}

# The answer that ends a write. The write is done whatever happens to this read.
github_final_view() {
    github_issue_view "$1" || board_partial "$1" "the change went through, but the issue could not be read back"
}

# --- list --------------------------------------------------------------------------------

github_list_page() {
    github_lp_doc=$(printf '%s' "$GH_LIST_VARS" | _jq -c --arg after "$1" \
        '. + {after: (if $after == "" then null else $after end)}' | github_field_vars | github_query BoardItems) || return $?
    if ! printf '%s' "$github_lp_doc" | _jq -e '.repositoryOwner.projectV2 != null' >/dev/null; then
        board_warn "no project $GH_NUMBER under $GH_OWNER"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$github_lp_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg repo "$GH_REPO" \
        --argjson filter "$GH_LIST_FILTER" '
        '"$BOARD_LIB"'
        .repositoryOwner.projectV2.items as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor,
           nodes: [$page.nodes[] | select(.isArchived | not) | select(.type != "PULL_REQUEST")
                   | select(.content != null)
                   | gh_item($cfg; $repo) | select(gh_keep($filter; $repo))]}'
}

github_issue_list() {
    github_require_project
    GH_LIST_FILTER=$(cat)
    github_il_me=''
    case $(printf '%s' "$GH_LIST_FILTER" | _jq -r '.assignee // ""') in
        @me) github_il_me=$(github_viewer) || return $? ;;
    esac
    github_il_sprint=''
    if [ "$(printf '%s' "$GH_LIST_FILTER" | _jq -r '.sprint // ""')" = current ]; then
        board_provider_load sprint
        github_il_doc=$(github_sprint_current 2>/dev/null) || {
            printf '[]'
            return 0
        }
        github_il_sprint=$(printf '%s' "$github_il_doc" | _jq -r .name)
    fi
    GH_LIST_FILTER=$(printf '%s' "$GH_LIST_FILTER" | _jq -c --arg me "$github_il_me" --arg sprint "$github_il_sprint" '
        (if .assignee == "@me" then .assignee = $me else . end)
        | (if $sprint != "" then .sprint = $sprint else . end)')
    GH_LIST_VARS=$(printf '%s' "$GH_LIST_FILTER" | _jq -c --arg owner "$GH_OWNER" --argjson number "$GH_NUMBER" '
        '"$BOARD_LIB"'
        {owner: $owner, number: $number, first: 100, query: gh_filter_query}')
    github_il_limit=$(printf '%s' "$GH_LIST_FILTER" | _jq -r '.limit // "all"')
    board_paged github_list_page "$github_il_limit"
}

# --- fields on the project ---------------------------------------------------------------

github_plan_field() {
    GH_PLAN=$(printf '%s' "$GH_PLAN" | _jq -c --arg f "$1" --argjson v "$2" '. + [{field: $f, value: $v}]')
}

github_plan_clear() {
    GH_PLAN=$(printf '%s' "$GH_PLAN" | _jq -c --arg f "$1" '. + [{field: $f, value: null}]')
}

# The id of a project field by name, or nothing.
github_field_id() {
    github_fi_meta=$(github_meta) || return $?
    printf '%s' "$github_fi_meta" | _jq -r --arg f "$1" '
        '"$BOARD_LIB"'
        [.fields.nodes[] | select(.name != null) | select(.name | ieq($f)) | .id] | first // ""'
}

# Usage: github_plan_option <field name> <option name>
github_plan_option() {
    github_po_doc=$(github_option "$1" "$2") || return $?
    github_plan_field "$(printf '%s' "$github_po_doc" | _jq -r .field)" \
        "$(printf '%s' "$github_po_doc" | _jq -c '{singleSelectOptionId: .option}')"
}

# Usage: github_require_field <field name> <hint>  — sets GH_FIELD_ID, or exit 3.
github_require_field() {
    GH_FIELD_ID=$(github_field_id "$1") || return $?
    [ -n "$GH_FIELD_ID" ] || {
        board_warn "this project has no field '$1'${2:+: $2}"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
}

# Turns what an intent asks of project fields into GH_PLAN, and writes nothing. Every name is
# checked here, so a wrong status or an undeclared priority stops before the first write.
# Usage: github_plan <intent>
github_plan() {
    GH_PLAN='[]'
    eval "$(printf '%s' "$1" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" '
        @sh "github_pl_status=\(.status // "" | tostring) github_pl_due=\(.due // "" | tostring) github_pl_sprint=\(.sprint // "" | tostring)",
        @sh "github_pl_want=\(.priority // "" | tostring) github_pl_priority=\(if .priority then ($cfg.priority[.priority] // "" | tostring) else "" end)",
        @sh "github_pl_clear=\(.clear | join(" "))"')"
    if [ -n "$github_pl_status" ]; then
        github_plan_option Status "$github_pl_status" || return $?
    fi
    case $github_pl_want in
        '') ;;
        none)
            github_require_field "$GH_PRIORITY_FIELD" "declare it in [board.target] priority_field" || return $?
            github_plan_clear "$GH_FIELD_ID"
            ;;
        *)
            [ -n "$github_pl_priority" ] || {
                board_warn "priority $github_pl_want is not declared: add it to [board.priority]"
                return "$BOARD_EXIT_UNSUPPORTED"
            }
            github_plan_option "$GH_PRIORITY_FIELD" "$github_pl_priority" || return $?
            ;;
    esac
    if [ -n "$github_pl_due" ]; then
        github_require_field "$GH_DUE_FIELD" "add a date field, or set [board.target] due_field" || return $?
        github_plan_field "$GH_FIELD_ID" "$(_jq -nc --arg d "$github_pl_due" '{date: $d}')"
    fi
    if [ -n "$github_pl_sprint" ]; then
        [ -n "$GH_SPRINT_FIELD" ] || {
            board_warn "declare [board.target] sprint_field: the name of the project's iteration field"
            return "$BOARD_EXIT_UNSUPPORTED"
        }
        github_require_field "$GH_SPRINT_FIELD" || return $?
        github_pl_field=$GH_FIELD_ID
        github_pl_it=$(github_iteration_id "$github_pl_sprint") || return $?
        github_plan_field "$github_pl_field" "$(_jq -nc --arg i "$github_pl_it" '{iterationId: $i}')"
    fi
    for github_pl_name in $github_pl_clear; do
        case $github_pl_name in
            priority)
                github_require_field "$GH_PRIORITY_FIELD" || return $?
                github_plan_clear "$GH_FIELD_ID"
                ;;
            due)
                github_require_field "$GH_DUE_FIELD" || return $?
                github_plan_clear "$GH_FIELD_ID"
                ;;
            sprint)
                github_require_field "${GH_SPRINT_FIELD:-Sprint}" || return $?
                github_plan_clear "$GH_FIELD_ID"
                ;;
        esac
    done
}

# Writes GH_PLAN to an item, noting each write.
github_plan_apply() {
    github_pa_meta=$(github_meta) || return $?
    github_pa_project=$(printf '%s' "$github_pa_meta" | _jq -r .id)
    printf '%s' "$GH_PLAN" | _jq -c '.[]' >"$BOARD_TMP/plan"
    while IFS= read -r github_pa_op; do
        if [ "$(printf '%s' "$github_pa_op" | _jq -r '.value == null')" = true ]; then
            printf '%s' "$github_pa_op" | _jq -c --arg project "$github_pa_project" --arg item "$1" \
                '{projectId: $project, itemId: $item, fieldId: .field}' |
                github_query ClearField >/dev/null || return $?
        else
            printf '%s' "$github_pa_op" | _jq -c --arg project "$github_pa_project" --arg item "$1" \
                '{projectId: $project, itemId: $item, fieldId: .field, value: .value}' |
                github_query SetField >/dev/null || return $?
        fi
        GH_WROTE=1
    done <"$BOARD_TMP/plan"
}

# Usage: github_iteration_id <name|current>
github_iteration_id() {
    board_provider_load sprint
    github_it_doc=$(github_sprints) || return $?
    github_it_id=$(printf '%s' "$github_it_doc" | _jq -r --arg want "$1" '
        '"$BOARD_LIB"'
        [.[] | select(if $want == "current" then .state == "active" else (.name | ieq($want)) end) | .id] | first // ""')
    [ -n "$github_it_id" ] || {
        board_warn "no sprint '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$github_it_id"
}

# Adds the issue to the project when it is not there, leaving the item in GH_ITEM.
github_ensure_item() {
    [ -z "$GH_ITEM" ] || return 0
    github_ei_meta=$(github_meta) || return $?
    GH_ITEM=$(printf '%s\n' "$github_ei_meta" | _jq -c --arg node "$GH_NODE" \
        '{projectId: .id, contentId: $node}' | github_query AddItem) || return $?
    GH_ITEM=$(printf '%s' "$GH_ITEM" | _jq -r .addProjectV2ItemById.item.id)
    GH_WROTE=1
}

# --- write -------------------------------------------------------------------------------

# Resolves names in an intent to what the REST API takes: @me to a login, a milestone to its number.
# Uses GH_ID_REPO, which a milestone number belongs to.
github_resolve_intent() {
    github_ri_intent=$1
    github_ri_me=''
    if printf '%s' "$github_ri_intent" | _jq -e '(.assignees + .add_assignees + .remove_assignees) | index("@me")' >/dev/null; then
        github_ri_me=$(github_viewer) || return $?
    fi
    github_ri_ms='null'
    if printf '%s' "$github_ri_intent" | _jq -e '.milestone != null' >/dev/null; then
        github_ri_list=$(github_rest_all "repos/$GH_ID_REPO/milestones?state=all&per_page=100") || return $?
        github_ri_want=$(printf '%s' "$github_ri_intent" | _jq -r .milestone)
        github_ri_ms=$(printf '%s' "$github_ri_list" | _jq -c --arg m "$github_ri_want" '
            '"$BOARD_LIB"'
            [.[] | select(.title | ieq($m)) | .number] | first // "missing"')
        if [ "$github_ri_ms" = '"missing"' ]; then
            board_warn "no milestone '$github_ri_want'"
            return "$BOARD_EXIT_NOT_FOUND"
        fi
    fi
    printf '%s' "$github_ri_intent" | _jq -c --arg me "$github_ri_me" --argjson ms "$github_ri_ms" '
        def me: map(if . == "@me" then $me else . end);
        .assignees |= me | .add_assignees |= me | .remove_assignees |= me | .milestone_number = $ms'
}

# A repository owned by a user has no issue types, and the API drops --type without a word.
# Usage: github_check_type <intent>
github_check_type() {
    github_ct_type=$(printf '%s' "$1" | _jq -r '.type // ""')
    [ -n "$github_ct_type" ] || return 0
    github_ct_doc=$(_jq -nc --arg repo "$GH_ID_REPO" '{owner: ($repo | split("/")[0]), name: ($repo | split("/")[1])}' |
        github_query IssueTypes) || return $?
    github_ct_have=$(printf '%s' "$github_ct_doc" | _jq -c '.repository.issueTypes.nodes // [] | map(.name)')
    if [ "$github_ct_have" = '[]' ]; then
        board_warn "repository $GH_ID_REPO has no issue types: they exist only in organisations"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    printf '%s' "$github_ct_have" | _jq -e --arg t "$github_ct_type" '
        '"$BOARD_LIB"'
        any(.[]; ieq($t))' >/dev/null ||
        board_usage_die "no issue type '$github_ct_type': $GH_ID_REPO has $(printf '%s' "$github_ct_have" | _jq -r 'join(", ")')"
}

github_issue_create() {
    github_require_project
    github_ic_intent=$(cat)
    GH_ID_REPO=$GH_REPO
    GH_WROTE=''
    github_ic_intent=$(github_resolve_intent "$github_ic_intent") || return $?
    github_check_type "$github_ic_intent" || return $?
    github_plan "$github_ic_intent" || return $?
    github_ic_parent=$(printf '%s' "$github_ic_intent" | _jq -r '.parent // ""')
    github_ic_parent_node=''
    if [ -n "$github_ic_parent" ]; then
        github_ic_parent_node=$(github_node_of "$github_ic_parent") || return $?
    fi
    github_ic_meta=$(github_meta) || return $?
    github_ic_new=$(printf '%s' "$github_ic_intent" | _jq -c '
        {title, body: (.body // ""), assignees, labels}
        + (if .milestone_number then {milestone: .milestone_number} else {} end)
        + (if .type then {type: .type} else {} end)' | github_rest_body POST "repos/$GH_REPO/issues") || return $?
    GH_WROTE=1
    github_ic_number=$(printf '%s' "$github_ic_new" | _jq -r .number)
    github_ic_node=$(printf '%s' "$github_ic_new" | _jq -r .node_id)
    github_ic_item=$(printf '%s\n' "$github_ic_meta" | _jq -c --arg node "$github_ic_node" \
        '{projectId: .id, contentId: $node}' | github_query AddItem) ||
        board_partial "$github_ic_number" "the issue exists, but could not be added to the project"
    github_ic_item=$(printf '%s' "$github_ic_item" | _jq -r .addProjectV2ItemById.item.id)
    github_plan_apply "$github_ic_item" ||
        board_partial "$github_ic_number" "the issue exists, but a project field could not be set"
    if [ -n "$github_ic_parent_node" ]; then
        _jq -nc --arg i "$github_ic_parent_node" --arg s "$github_ic_node" '{issueId: $i, subIssueId: $s}' |
            github_query SetParent >/dev/null ||
            board_partial "$github_ic_number" "the issue exists, but its parent could not be set"
    fi
    github_final_view "$github_ic_number"
}

# Removing what is not there succeeds, so a 404 here is fine. Sent by name, so one label's removal
# never resends the others: an edit that did not touch a label cannot lose it.
github_remove_label() {
    github_rl_status=0
    board_exec "$GH_CLI" api -X DELETE "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/labels/$(board_urlencode "$1")" </dev/null ||
        github_rl_status=$?
    [ "$github_rl_status" != 0 ] || return 0
    case $(board_err_line) in
        *'HTTP 404'*) return 0 ;;
    esac
    github_check "$github_rl_status"
}

# Labels and assignees go through their own endpoints, for the same reason.
# Usage: github_edit_people_and_labels <intent>
github_edit_lists() {
    if printf '%s' "$1" | _jq -e '.add_labels != []' >/dev/null; then
        printf '%s' "$1" | _jq -c '{labels: .add_labels}' |
            github_rest_body POST "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/labels" >/dev/null || return $?
        GH_WROTE=1
    fi
    printf '%s' "$1" | _jq -r '.remove_labels[]' >"$BOARD_TMP/remove-labels"
    while IFS= read -r github_el_label; do
        github_remove_label "$github_el_label" || return $?
        GH_WROTE=1
    done <"$BOARD_TMP/remove-labels"
    if printf '%s' "$1" | _jq -e '.add_assignees != []' >/dev/null; then
        printf '%s' "$1" | _jq -c '{assignees: .add_assignees}' |
            github_rest_body POST "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/assignees" >/dev/null || return $?
        GH_WROTE=1
    fi
    if printf '%s' "$1" | _jq -e '.remove_assignees != []' >/dev/null; then
        printf '%s' "$1" | _jq -c '{assignees: .remove_assignees}' |
            github_rest_body DELETE "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/assignees" >/dev/null || return $?
        GH_WROTE=1
    fi
}

github_issue_edit() {
    github_ie_id=$1
    GH_WROTE=''
    github_ie_intent=$(cat)
    github_ie_raw=$(github_fetch "$github_ie_id") || return $?
    github_ids "$github_ie_raw" "$github_ie_id"
    github_ie_intent=$(github_resolve_intent "$github_ie_intent") || return $?
    if [ -n "$GH_IS_DRAFT" ] && printf '%s' "$github_ie_intent" | _jq -e '
        (.add_labels + .remove_labels + .add_assignees + .remove_assignees | length > 0)
        or .milestone or .parent or .type or (.clear | index("milestone") or index("parent"))' >/dev/null; then
        board_warn "a draft item takes only --title, --body and --status"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    github_check_type "$github_ie_intent" || return $?
    github_plan "$github_ie_intent" || return $?
    github_ie_parent=$(printf '%s' "$github_ie_intent" | _jq -r '.parent // ""')
    github_ie_parent_node=''
    if [ -n "$github_ie_parent" ]; then
        github_ie_parent_node=$(github_node_of "$github_ie_parent") || return $?
    fi
    github_ie_clear_parent=''
    if printf '%s' "$github_ie_intent" | _jq -e '.clear | index("parent")' >/dev/null; then
        github_ie_clear_parent=$GH_PARENT_NODE
    fi

    if [ -n "$GH_IS_DRAFT" ]; then
        if printf '%s' "$github_ie_intent" | _jq -e '.title != null or .body != null' >/dev/null; then
            printf '%s' "$github_ie_intent" | _jq -c --arg id "$GH_NODE" \
                '{input: ({draftIssueId: $id} + (if .title then {title} else {} end) + (if .body != null then {body} else {} end))}' |
                github_query UpdateDraft >/dev/null || return $?
            GH_WROTE=1
        fi
    else
        github_ie_patch=$(printf '%s' "$github_ie_intent" | _jq -c '
            (if .title then {title} else {} end)
            + (if .body != null then {body} else {} end)
            + (if .milestone_number then {milestone: .milestone_number}
               elif (.clear | index("milestone")) then {milestone: null} else {} end)
            + (if .type then {type} else {} end)')
        if [ "$github_ie_patch" != '{}' ]; then
            printf '%s' "$github_ie_patch" |
                github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
            GH_WROTE=1
        fi
        github_edit_lists "$github_ie_intent" || {
            github_stop "$?" "$github_ie_id" "some fields changed, a label or assignee did not"
            return $?
        }
    fi
    if [ "$GH_PLAN" != '[]' ]; then
        github_ensure_item || {
            github_stop "$?" "$github_ie_id" "some fields changed, the issue could not be added to the project"
            return $?
        }
        github_plan_apply "$GH_ITEM" || {
            github_stop "$?" "$github_ie_id" "some fields changed, a project field did not"
            return $?
        }
    fi
    if [ -n "$github_ie_parent_node" ]; then
        _jq -nc --arg i "$github_ie_parent_node" --arg s "$GH_NODE" '{issueId: $i, subIssueId: $s}' |
            github_query SetParent >/dev/null || {
            github_stop "$?" "$github_ie_id" "some fields changed, the parent could not be set"
            return $?
        }
        GH_WROTE=1
    elif [ -n "$github_ie_clear_parent" ]; then
        _jq -nc --arg i "$github_ie_clear_parent" --arg s "$GH_NODE" '{issueId: $i, subIssueId: $s}' |
            github_query ClearParent >/dev/null || {
            github_stop "$?" "$github_ie_id" "some fields changed, the parent could not be cleared"
            return $?
        }
        GH_WROTE=1
    fi
    github_final_view "$github_ie_id"
}

github_issue_move() {
    GH_WROTE=''
    github_im_raw=$(github_fetch "$1") || return $?
    github_ids "$github_im_raw" "$1"
    GH_PLAN='[]'
    github_plan_option Status "$2" || return $?
    github_ensure_item || return $?
    github_plan_apply "$GH_ITEM" || {
        github_stop "$?" "$1" "the issue was added to the project, but its status could not be set"
        return $?
    }
    github_final_view "$1"
}

# The first status of a category, in project order, or nothing.
github_status_in() {
    board_provider_load status
    github_si_doc=$(github_status_list) || return $?
    printf '%s' "$github_si_doc" | _jq -r --arg c "$1" '[.[] | select(.category == $c) | .name] | first // ""'
}

github_issue_close() {
    GH_WROTE=''
    github_cl_raw=$(github_fetch "$1") || return $?
    github_ids "$github_cl_raw" "$1"
    github_cl_status=$(github_status_in "$2") || return $?
    [ -n "$github_cl_status" ] || board_usage_die "no status has category $2: declare one in [board.statuses]"
    GH_PLAN='[]'
    github_plan_option Status "$github_cl_status" || return $?
    if [ -z "$GH_IS_DRAFT" ]; then
        github_cl_reason=completed
        [ "$2" = done ] || github_cl_reason=not_planned
        _jq -nc --arg r "$github_cl_reason" '{state: "closed", state_reason: $r}' |
            github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
        GH_WROTE=1
    fi
    github_ensure_item || {
        github_stop "$?" "$1" "closed, but the issue could not be added to the project"
        return $?
    }
    github_plan_apply "$GH_ITEM" || {
        github_stop "$?" "$1" "closed, but the status could not be set"
        return $?
    }
    github_final_view "$1"
}

github_issue_reopen() {
    GH_WROTE=''
    github_ro_raw=$(github_fetch "$1") || return $?
    github_ids "$github_ro_raw" "$1"
    github_ro_status=$2
    github_ro_closed=$GH_IS_CLOSED
    if [ -n "$GH_IS_DRAFT" ]; then
        # A draft has no closed state: its status is all there is.
        github_ro_category=$(printf '%s' "$github_ro_raw" | github_normalise | _jq -r '.status.category // ""')
        case $github_ro_category in
            'done' | canceled) github_ro_closed=1 ;;
        esac
    fi
    if [ -n "$github_ro_closed" ] && [ -z "$github_ro_status" ]; then
        # A reopened issue keeps Done on the project: no workflow moves it back.
        github_ro_status=$(github_status_in todo) || return $?
    fi
    GH_PLAN='[]'
    if [ -n "$github_ro_status" ]; then
        github_plan_option Status "$github_ro_status" || return $?
    fi
    if [ -n "$GH_IS_CLOSED" ]; then
        printf '{"state":"open"}' |
            github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
        GH_WROTE=1
    fi
    if [ "$GH_PLAN" != '[]' ]; then
        github_ensure_item || {
            github_stop "$?" "$1" "reopened, but the issue could not be added to the project"
            return $?
        }
        github_plan_apply "$GH_ITEM" || {
            github_stop "$?" "$1" "reopened, but the status could not be set"
            return $?
        }
    fi
    github_final_view "$1"
}

github_issue_delete() {
    github_id_raw=$(github_fetch "$1") || return $?
    github_ids "$github_id_raw" "$1"
    if [ -n "$GH_IS_DRAFT" ]; then
        github_id_meta=$(github_meta) || return $?
        printf '%s\n' "$github_id_meta" | _jq -c --arg item "$GH_ITEM" '{projectId: .id, itemId: $item}' |
            github_query DeleteItem >/dev/null
    else
        _jq -nc --arg id "$GH_NODE" '{id: $id}' | github_query DeleteIssue >/dev/null
    fi
}

# --- comments ----------------------------------------------------------------------------

# Leaves the issue in GH_ID_REPO and GH_ID_NUMBER. A PVTI_ id needs a read to learn them.
github_comment_target() {
    github_require_project
    github_parse_id "$1"
    if [ -n "$GH_ID_ITEM" ]; then
        github_ct_raw=$(github_fetch "$1") || return $?
        github_ids "$github_ct_raw" "$1"
        if [ -n "$GH_IS_DRAFT" ]; then
            board_warn "a draft item has no comments"
            return "$BOARD_EXIT_UNSUPPORTED"
        fi
    fi
}

github_issue_comment_list() {
    github_comment_target "$1" || return $?
    github_cl_doc=$(github_rest_all "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/comments?per_page=100") || return $?
    printf '%s' "$github_cl_doc" | _jq -c ''"$BOARD_LIB"' map(gh_comment)'
}

github_issue_comment_add() {
    github_comment_target "$1" || return $?
    github_ca_doc=$(github_rest_body POST "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/comments") || return $?
    printf '%s' "$github_ca_doc" | _jq -c ''"$BOARD_LIB"' gh_comment'
}

# A comment id works on its own in the API, so a wrong issue would pass unnoticed.
# Usage: github_comment_of_issue <comment id>
github_comment_of_issue() {
    github_co_doc=$(github_rest GET "repos/$GH_ID_REPO/issues/comments/$1") || return $?
    if ! printf '%s' "$github_co_doc" | _jq -e --arg n "/issues/$GH_ID_NUMBER" '.issue_url | endswith($n)' >/dev/null; then
        board_warn "comment $1 is not on issue $GH_ID_NUMBER"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
}

github_issue_comment_edit() {
    github_comment_target "$1" || return $?
    github_comment_of_issue "$2" || return $?
    github_ce_doc=$(github_rest_body PATCH "repos/$GH_ID_REPO/issues/comments/$2") || return $?
    printf '%s' "$github_ce_doc" | _jq -c ''"$BOARD_LIB"' gh_comment'
}

github_issue_comment_delete() {
    github_comment_target "$1" || return $?
    github_comment_of_issue "$2" || return $?
    github_rest DELETE "repos/$GH_ID_REPO/issues/comments/$2" >/dev/null
}

# --- links -------------------------------------------------------------------------------

github_issue_link_list() {
    github_ll_doc=$(github_fetch "$1") || return $?
    printf '%s' "$github_ll_doc" | github_normalise | _jq -c .links
}

# Usage: github_link_sides <id> <other> <type>
# Sets GH_LINK_MUTATION inputs: GH_LINK_A and GH_LINK_B, read as "B blocks A", and whether the link
# exists already, in GH_LINK_EXISTS. Linking twice must succeed, and the API refuses it.
github_link_sides() {
    github_ls_a=$(github_node_of "$1") || return $?
    github_ls_b=$(github_node_of "$2") || return $?
    case $3 in
        blocks)
            GH_LINK_A=$github_ls_b GH_LINK_B=$github_ls_a
            github_ls_read=$2
            ;;
        *)
            GH_LINK_A=$github_ls_a GH_LINK_B=$github_ls_b
            github_ls_read=$1
            ;;
    esac
    github_ls_raw=$(github_fetch "$github_ls_read") || return $?
    GH_LINK_EXISTS=$(printf '%s' "$github_ls_raw" | _jq -r --arg t "$3" --arg b "$GH_LINK_B" '
        (.issue // .item.content) as $i
        | (if $t == "relates" then [($i.relatesTo.nodes // [])[].id]
           elif $t == "duplicates" then [$i.duplicateOf.id // empty]
           else [($i.blockedBy.nodes // [])[].id] end)
        | index($b) != null')
}

github_link_input() {
    _jq -nc --arg a "$GH_LINK_A" --arg b "$GH_LINK_B" "{$1: \$a, $2: \$b}"
}

github_issue_link_add() {
    github_link_sides "$1" "$2" "$3" || return $?
    if [ "$GH_LINK_EXISTS" != true ]; then
        case $3 in
            relates) github_link_input issueId relatedIssueId | github_query AddRelates >/dev/null || return $? ;;
            duplicates) github_link_input issueId duplicateIssueId | github_query CloseDuplicate >/dev/null || return $? ;;
            *) github_link_input issueId blockingIssueId | github_query AddBlock >/dev/null || return $? ;;
        esac
    fi
    github_issue_view "$1" || board_partial "$1" "linked, but the issue could not be read back"
}

github_issue_link_remove() {
    github_link_sides "$1" "$2" "$3" || return $?
    if [ "$GH_LINK_EXISTS" = true ]; then
        case $3 in
            relates) github_link_input issueId relatedIssueId | github_query RemoveRelates >/dev/null || return $? ;;
            duplicates) github_link_input duplicateId canonicalId | github_query UnmarkDuplicate >/dev/null || return $? ;;
            *) github_link_input issueId blockingIssueId | github_query RemoveBlock >/dev/null || return $? ;;
        esac
    fi
    github_issue_view "$1" || board_partial "$1" "unlinked, but the issue could not be read back"
}

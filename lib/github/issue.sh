# shellcheck shell=sh

# An issue is reached by number, owner/repo#number, or PVTI_ for a project item with no repository.
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
    _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg repo "$GH_REPO" --argjson number "$GH_NUMBER" '
        include "github/shape";
        if .item then (.item | gh_item($cfg; $repo)) else (.issue | gh_issue($cfg; $repo; $number)) end'
}

# Sets GH_NODE, GH_ITEM, GH_IS_DRAFT, GH_PARENT_NODE and the GH_ID_* of github_parse_id.
# Usage: github_ids <raw answer> <id>
github_ids() {
    github_parse_id "$2"
    eval "$(printf '%s' "$1" | _jq -r --argjson number "$GH_NUMBER" '
        (if .item then (.item.content // {}) else .issue end) as $c
        | (if .item then .item.id
           else ([.issue.projectItems.nodes[] | select(.project.number == $number)] | first | .id // "") end) as $item
        | @sh "GH_NODE=\($c.id // "") GH_ITEM=\($item) GH_IS_DRAFT=\(if .item and ($c.__typename != "Issue") then "1" else "" end) GH_PARENT_NODE=\($c.parent.id // "")"')"
}

github_issue_view() {
    github_iv_doc=$(github_fetch "$1") || return $?
    printf '%s' "$github_iv_doc" | github_normalise
}

# The node id of another issue, for parent and links.
github_node_of() {
    github_no_doc=$(github_fetch "$1") || return $?
    printf '%s' "$github_no_doc" | _jq -r '(.issue.id // .item.content.id) // empty'
}

# --- list --------------------------------------------------------------------------------

github_list_page() {
    github_lp_doc=$(printf '%s' "$GH_LIST_VARS" | _jq -c --arg after "$1" \
        '. + {after: (if $after == "" then null else $after end)}' | github_field_vars | github_query BoardItems) || return $?
    printf '%s' "$github_lp_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg repo "$GH_REPO" \
        --argjson filter "$GH_LIST_FILTER" '
        include "github/shape";
        .repositoryOwner.projectV2.items as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor,
           nodes: [$page.nodes[] | select(.isArchived | not) | select(.content != null)
                   | gh_item($cfg; $repo) | select(gh_keep($filter))]}'
}

github_issue_list() {
    github_require_project
    GH_LIST_FILTER=$(cat)
    github_il_me=''
    case $(printf '%s' "$GH_LIST_FILTER" | _jq -r '.assignee // ""') in
        @me) github_il_me=$(github_viewer) || return $? ;;
    esac
    GH_LIST_FILTER=$(printf '%s' "$GH_LIST_FILTER" | _jq -c --arg me "$github_il_me" \
        'if .assignee == "@me" then .assignee = $me else . end')
    GH_LIST_VARS=$(printf '%s' "$GH_LIST_FILTER" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        --arg owner "$GH_OWNER" --argjson number "$GH_NUMBER" '
        include "github/shape";
        {owner: $owner, number: $number, first: 100, query: gh_filter_query($cfg)}')
    github_il_limit=$(printf '%s' "$GH_LIST_FILTER" | _jq -r '.limit // "all"')
    board_paged github_list_page "$github_il_limit"
}

# --- fields on the project ---------------------------------------------------------------

# Usage: github_set_field <item> <field id> <value JSON>
github_set_field() {
    github_sf_meta=$(github_meta) || return $?
    printf '%s\n' "$github_sf_meta" | _jq -c --arg item "$1" --arg field "$2" --argjson value "$3" \
        '{projectId: .id, itemId: $item, fieldId: $field, value: $value}' | github_query SetField >/dev/null
}

github_set_status() {
    github_ss_doc=$(github_option Status "$2") || return $?
    github_ss_field=$(printf '%s' "$github_ss_doc" | _jq -r .field)
    github_ss_value=$(printf '%s' "$github_ss_doc" | _jq -c '{singleSelectOptionId: .option}')
    github_set_field "$1" "$github_ss_field" "$github_ss_value"
}

github_clear_field() {
    github_cf_meta=$(github_meta) || return $?
    github_cf_field=$(printf '%s' "$github_cf_meta" | _jq -r --arg f "$2" '
        include "jq/common"; [.fields.nodes[] | select(.name != null) | select(.name | ieq($f)) | .id] | first // ""')
    [ -n "$github_cf_field" ] || {
        board_warn "this project has no field '$2'"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    printf '%s\n' "$github_cf_meta" | _jq -c --arg item "$1" --arg field "$github_cf_field" \
        '{projectId: .id, itemId: $item, fieldId: $field}' | github_query ClearField >/dev/null
}

# Sets the project fields an intent names. Usage: github_apply_fields <item> <intent>
github_apply_fields() {
    eval "$(printf '%s' "$2" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" '
        @sh "github_af_status=\(.status // "") github_af_due=\(.due // "") github_af_sprint=\(.sprint // "")",
        @sh "github_af_priority=\(if .priority then ($cfg.priority[.priority] // "") else "" end) github_af_want_priority=\(.priority // "")",
        @sh "github_af_clear=\(.clear | join(" "))"')"
    if [ -n "$github_af_status" ]; then
        github_set_status "$1" "$github_af_status" || return $?
    fi
    if [ -n "$github_af_want_priority" ]; then
        [ -n "$github_af_priority" ] || {
            board_warn "priority $github_af_want_priority is not declared: add it to [board.priority]"
            return "$BOARD_EXIT_UNSUPPORTED"
        }
        github_af_doc=$(github_option "$GH_PRIORITY_FIELD" "$github_af_priority") || return $?
        github_set_field "$1" "$(printf '%s' "$github_af_doc" | _jq -r .field)" \
            "$(printf '%s' "$github_af_doc" | _jq -c '{singleSelectOptionId: .option}')" || return $?
    fi
    if [ -n "$github_af_due" ]; then
        github_af_meta=$(github_meta) || return $?
        github_af_field=$(printf '%s' "$github_af_meta" | _jq -r --arg f "$GH_DUE_FIELD" '
            include "jq/common"; [.fields.nodes[] | select(.name != null) | select(.name | ieq($f)) | .id] | first // ""')
        [ -n "$github_af_field" ] || {
            board_warn "this project has no date field '$GH_DUE_FIELD': add one, or set [board.target] due_field"
            return "$BOARD_EXIT_UNSUPPORTED"
        }
        github_set_field "$1" "$github_af_field" "$(_jq -nc --arg d "$github_af_due" '{date: $d}')" || return $?
    fi
    if [ -n "$github_af_sprint" ]; then
        github_sprint_field_id || return $?
        github_af_it=$(github_iteration_id "$github_af_sprint") || return $?
        github_set_field "$1" "$GH_SPRINT_FIELD_ID" "$(_jq -nc --arg i "$github_af_it" '{iterationId: $i}')" || return $?
    fi
    for github_af_field in $github_af_clear; do
        case $github_af_field in
            priority) github_clear_field "$1" "$GH_PRIORITY_FIELD" || return $? ;;
            due) github_clear_field "$1" "$GH_DUE_FIELD" || return $? ;;
            sprint) github_clear_field "$1" "${GH_SPRINT_FIELD:-Sprint}" || return $? ;;
        esac
    done
}

github_sprint_field_id() {
    [ -n "$GH_SPRINT_FIELD" ] || {
        board_warn "declare [board.target] sprint_field: the name of the project's iteration field"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    github_sp_meta=$(github_meta) || return $?
    GH_SPRINT_FIELD_ID=$(printf '%s' "$github_sp_meta" | _jq -r --arg f "$GH_SPRINT_FIELD" '
        include "jq/common"; [.fields.nodes[] | select(.name != null) | select(.name | ieq($f)) | .id] | first // ""')
    [ -n "$GH_SPRINT_FIELD_ID" ] || {
        board_warn "this project has no field '$GH_SPRINT_FIELD'"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
}

# Usage: github_iteration_id <name|current>
github_iteration_id() {
    board_provider_load sprint
    github_it_doc=$(github_sprints) || return $?
    github_it_id=$(printf '%s' "$github_it_doc" | _jq -r --arg want "$1" '
        include "jq/common";
        [.[] | select(if $want == "current" then .state == "active" else (.name | ieq($want)) end) | .id] | first // ""')
    [ -n "$github_it_id" ] || {
        board_warn "no sprint '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$github_it_id"
}

# --- write -------------------------------------------------------------------------------

# Resolves names in an intent to what the REST API takes: @me to a login, a milestone to its number.
github_resolve_intent() {
    github_ri_intent=$1
    github_ri_me=''
    if printf '%s' "$github_ri_intent" | _jq -e '(.assignees + .add_assignees + .remove_assignees) | index("@me")' >/dev/null; then
        github_ri_me=$(github_viewer) || return $?
    fi
    github_ri_ms='null'
    if printf '%s' "$github_ri_intent" | _jq -e '.milestone != null' >/dev/null; then
        github_ri_list=$(github_rest_all "repos/$GH_REPO/milestones?state=all&per_page=100") || return $?
        github_ri_want=$(printf '%s' "$github_ri_intent" | _jq -r .milestone)
        github_ri_ms=$(printf '%s' "$github_ri_list" | _jq -c --arg m "$github_ri_want" '
            include "jq/common"; [.[] | select(.title | ieq($m)) | .number] | first // "missing"')
        if [ "$github_ri_ms" = '"missing"' ]; then
            board_warn "no milestone '$github_ri_want'"
            return "$BOARD_EXIT_NOT_FOUND"
        fi
    fi
    printf '%s' "$github_ri_intent" | _jq -c --arg me "$github_ri_me" --argjson ms "$github_ri_ms" '
        def me: map(if . == "@me" then $me else . end);
        .assignees |= me | .add_assignees |= me | .remove_assignees |= me | .milestone_number = $ms'
}

github_issue_create() {
    github_require_project
    github_ic_intent=$(cat)
    github_ic_intent=$(github_resolve_intent "$github_ic_intent") || return $?
    github_ic_new=$(printf '%s' "$github_ic_intent" | _jq -c '
        {title, body: (.body // ""), assignees, labels}
        + (if .milestone_number then {milestone: .milestone_number} else {} end)
        + (if .type then {type: .type} else {} end)' | github_rest_body POST "repos/$GH_REPO/issues") || return $?
    github_ic_number=$(printf '%s' "$github_ic_new" | _jq -r .number)
    github_ic_node=$(printf '%s' "$github_ic_new" | _jq -r .node_id)
    github_ic_meta=$(github_meta) || board_partial "$github_ic_number" "the issue exists, but the project could not be read"
    github_ic_item=$(printf '%s\n' "$github_ic_meta" | _jq -c --arg node "$github_ic_node" \
        '{projectId: .id, contentId: $node}' | github_query AddItem) ||
        board_partial "$github_ic_number" "the issue exists, but could not be added to the project"
    github_ic_item=$(printf '%s' "$github_ic_item" | _jq -r .addProjectV2ItemById.item.id)
    github_apply_fields "$github_ic_item" "$github_ic_intent" ||
        board_partial "$github_ic_number" "the issue exists, but a project field could not be set"
    github_ic_parent=$(printf '%s' "$github_ic_intent" | _jq -r '.parent // ""')
    if [ -n "$github_ic_parent" ]; then
        github_ic_parent_node=$(github_node_of "$github_ic_parent") ||
            board_partial "$github_ic_number" "the issue exists, but its parent could not be read"
        _jq -nc --arg i "$github_ic_parent_node" --arg s "$github_ic_node" '{issueId: $i, subIssueId: $s}' |
            github_query SetParent >/dev/null ||
            board_partial "$github_ic_number" "the issue exists, but its parent could not be set"
    fi
    github_issue_view "$github_ic_number"
}

github_issue_edit() {
    github_ie_id=$1
    github_ie_patch='{}'
    github_ie_intent=$(cat)
    github_ie_raw=$(github_fetch "$github_ie_id") || return $?
    github_ids "$github_ie_raw" "$github_ie_id"
    github_ie_intent=$(github_resolve_intent "$github_ie_intent") || return $?
    if [ -n "$GH_IS_DRAFT" ]; then
        if printf '%s' "$github_ie_intent" | _jq -e '
            (.add_labels + .remove_labels + .add_assignees + .remove_assignees + .clear | length > 0)
            or .milestone or .parent or .type' >/dev/null; then
            board_warn "a draft item takes only --title, --body and --status"
            return "$BOARD_EXIT_UNSUPPORTED"
        fi
        if printf '%s' "$github_ie_intent" | _jq -e '.title != null or .body != null' >/dev/null; then
            printf '%s' "$github_ie_intent" | _jq -c --arg id "$GH_NODE" \
                '{input: ({draftIssueId: $id} + (if .title then {title} else {} end) + (if .body then {body} else {} end))}' |
                github_query UpdateDraft >/dev/null || return $?
        fi
    else
        github_ie_patch=$(printf '%s\n%s\n' "$github_ie_raw" "$github_ie_intent" | _jq -sc '
            .[0].issue as $now | .[1] as $i
            | ([$now.labels.nodes[].name] + $i.add_labels - $i.remove_labels | unique) as $labels
            | ([$now.assignees.nodes[].login] + $i.add_assignees - $i.remove_assignees | unique) as $people
            | {}
            + (if $i.title then {title: $i.title} else {} end)
            + (if $i.body != null then {body: $i.body} else {} end)
            + (if $i.milestone_number then {milestone: $i.milestone_number}
               elif ($i.clear | index("milestone")) then {milestone: null} else {} end)
            + (if $i.type then {type: $i.type} else {} end)
            + (if (($i.add_labels + $i.remove_labels) | length) > 0 then {labels: $labels} else {} end)
            + (if (($i.add_assignees + $i.remove_assignees) | length) > 0 then {assignees: $people} else {} end)')
        if [ "$github_ie_patch" != '{}' ]; then
            printf '%s' "$github_ie_patch" |
                github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
        fi
    fi
    if printf '%s' "$github_ie_intent" | _jq -e '.status or .priority or .due or .sprint or ((.clear - ["milestone", "parent"]) | length > 0)' >/dev/null; then
        if [ -z "$GH_ITEM" ]; then
            github_ie_meta=$(github_meta) || return $?
            GH_ITEM=$(printf '%s\n' "$github_ie_meta" | _jq -c --arg node "$GH_NODE" \
                '{projectId: .id, contentId: $node}' | github_query AddItem) || return $?
            GH_ITEM=$(printf '%s' "$GH_ITEM" | _jq -r .addProjectV2ItemById.item.id)
        fi
        github_ie_status=0
        github_apply_fields "$GH_ITEM" "$github_ie_intent" || github_ie_status=$?
        if [ "$github_ie_status" != 0 ]; then
            [ "$github_ie_patch" != '{}' ] || return "$github_ie_status"
            board_partial "$github_ie_id" "some fields changed, a project field did not"
        fi
    fi
    github_ie_parent=$(printf '%s' "$github_ie_intent" | _jq -r '.parent // ""')
    if [ -n "$github_ie_parent" ]; then
        github_ie_parent_node=$(github_node_of "$github_ie_parent") ||
            board_partial "$github_ie_id" "some fields changed, the parent could not be read"
        _jq -nc --arg i "$github_ie_parent_node" --arg s "$GH_NODE" '{issueId: $i, subIssueId: $s}' |
            github_query SetParent >/dev/null || board_partial "$github_ie_id" "some fields changed, the parent could not be set"
    elif printf '%s' "$github_ie_intent" | _jq -e '.clear | index("parent")' >/dev/null && [ -n "$GH_PARENT_NODE" ]; then
        _jq -nc --arg i "$GH_PARENT_NODE" --arg s "$GH_NODE" '{issueId: $i, subIssueId: $s}' |
            github_query ClearParent >/dev/null || board_partial "$github_ie_id" "some fields changed, the parent could not be cleared"
    fi
    github_issue_view "$github_ie_id"
}

# Makes sure the issue has an item here, leaving it in GH_ITEM.
github_ensure_item() {
    github_ei_raw=$(github_fetch "$1") || return $?
    github_ids "$github_ei_raw" "$1"
    if [ -z "$GH_ITEM" ]; then
        github_ei_meta=$(github_meta) || return $?
        GH_ITEM=$(printf '%s\n' "$github_ei_meta" | _jq -c --arg node "$GH_NODE" \
            '{projectId: .id, contentId: $node}' | github_query AddItem) || return $?
        GH_ITEM=$(printf '%s' "$GH_ITEM" | _jq -r .addProjectV2ItemById.item.id)
    fi
}

github_issue_move() {
    github_ensure_item "$1" || return $?
    github_set_status "$GH_ITEM" "$2" || return $?
    github_issue_view "$1"
}

# The first status of a category, in project order, or nothing.
github_status_in() {
    board_provider_load status
    github_si_doc=$(github_status_list) || return $?
    printf '%s' "$github_si_doc" | _jq -r --arg c "$1" '[.[] | select(.category == $c) | .name] | first // ""'
}

github_issue_close() {
    github_ensure_item "$1" || return $?
    github_ic_status=$(github_status_in "$2") || return $?
    if [ -z "$GH_IS_DRAFT" ]; then
        github_ic_reason=completed
        [ "$2" = done ] || github_ic_reason=not_planned
        _jq -nc --arg r "$github_ic_reason" '{state: "closed", state_reason: $r}' |
            github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
    fi
    if [ -n "$github_ic_status" ]; then
        github_set_status "$GH_ITEM" "$github_ic_status" || board_partial "$1" "closed, but the status could not be set"
    elif [ -n "$GH_IS_DRAFT" ]; then
        board_usage_die "no status has category $2: declare one in [board.statuses]"
    fi
    github_issue_view "$1"
}

github_issue_reopen() {
    github_ensure_item "$1" || return $?
    github_ir_status=$2
    github_ir_closed=$(printf '%s' "$github_ei_raw" | _jq -r '.issue.state // "OPEN"')
    if [ "$github_ir_closed" = CLOSED ]; then
        printf '{"state":"open"}' | github_rest_body PATCH "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER" >/dev/null || return $?
        # A reopened issue keeps Done on the project: no workflow moves it back.
        [ -n "$github_ir_status" ] || github_ir_status=$(github_status_in todo) || return $?
    fi
    if [ -n "$github_ir_status" ]; then
        github_set_status "$GH_ITEM" "$github_ir_status" || board_partial "$1" "reopened, but the status could not be set"
    fi
    github_issue_view "$1"
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

github_comment_target() {
    github_require_project
    github_parse_id "$1"
    if [ -n "$GH_ID_ITEM" ]; then
        board_warn "a draft item has no comments"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
}

github_issue_comment_list() {
    github_comment_target "$1" || return $?
    github_cl_doc=$(github_rest_all "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/comments?per_page=100") || return $?
    printf '%s' "$github_cl_doc" | _jq -c 'include "github/shape"; map(gh_comment)'
}

github_issue_comment_add() {
    github_comment_target "$1" || return $?
    github_ca_doc=$(github_rest_body POST "repos/$GH_ID_REPO/issues/$GH_ID_NUMBER/comments") || return $?
    printf '%s' "$github_ca_doc" | _jq -c 'include "github/shape"; gh_comment'
}

github_issue_comment_edit() {
    github_comment_target "$1" || return $?
    github_ce_doc=$(github_rest_body PATCH "repos/$GH_ID_REPO/issues/comments/$2") || return $?
    printf '%s' "$github_ce_doc" | _jq -c 'include "github/shape"; gh_comment'
}

github_issue_comment_delete() {
    github_comment_target "$1" || return $?
    github_rest DELETE "repos/$GH_ID_REPO/issues/comments/$2" >/dev/null
}

# --- links -------------------------------------------------------------------------------

github_issue_link_list() {
    github_ll_doc=$(github_fetch "$1") || return $?
    printf '%s' "$github_ll_doc" | github_normalise | _jq -c .links
}

# Usage: github_link_nodes <id> <other> <type>  — sets GH_BLOCKED and GH_BLOCKER.
github_link_nodes() {
    github_ln_a=$(github_node_of "$1") || return $?
    github_ln_b=$(github_node_of "$2") || return $?
    [ -n "$github_ln_a" ] && [ -n "$github_ln_b" ] || {
        board_warn "a draft item cannot be linked"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    if [ "$3" = blocks ]; then
        GH_BLOCKED=$github_ln_b GH_BLOCKER=$github_ln_a
    else
        GH_BLOCKED=$github_ln_a GH_BLOCKER=$github_ln_b
    fi
}

github_issue_link_add() {
    case $3 in
        relates)
            board_warn "GitHub has no way to set a relates link"
            return "$BOARD_EXIT_UNSUPPORTED"
            ;;
        duplicates)
            github_la_a=$(github_node_of "$1") || return $?
            github_la_b=$(github_node_of "$2") || return $?
            _jq -nc --arg i "$github_la_a" --arg d "$github_la_b" '{issueId: $i, duplicateIssueId: $d}' |
                github_query CloseDuplicate >/dev/null || return $?
            ;;
        *)
            github_link_nodes "$1" "$2" "$3" || return $?
            _jq -nc --arg i "$GH_BLOCKED" --arg b "$GH_BLOCKER" '{issueId: $i, blockingIssueId: $b}' |
                github_query AddBlock >/dev/null || return $?
            ;;
    esac
    github_issue_view "$1"
}

github_issue_link_remove() {
    case $3 in
        relates | duplicates)
            board_warn "GitHub has no way to remove a $3 link"
            return "$BOARD_EXIT_UNSUPPORTED"
            ;;
    esac
    github_link_nodes "$1" "$2" "$3" || return $?
    _jq -nc --arg i "$GH_BLOCKED" --arg b "$GH_BLOCKER" '{issueId: $i, blockingIssueId: $b}' |
        github_query RemoveBlock >/dev/null || return $?
    github_issue_view "$1"
}

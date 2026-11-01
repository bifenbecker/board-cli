# shellcheck shell=sh

# Milestones belong to a project, so they need [board.target] project. The id is Linear's UUID: a
# milestone has nothing shorter, and no URL of its own.

linear_require_project() {
    [ -n "$LN_PROJECT" ] || {
        board_warn "milestones belong to a project: set [board.target] project"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
}

linear_milestone_page() {
    linear_mp_doc=$(_jq -nc --arg project "$LN_PROJECT" --arg after "$1" \
        '{project: $project, after: (if $after == "" then null else $after end)}' | linear_query MilestoneList) || return $?
    printf '%s' "$linear_mp_doc" | _jq -c --arg state "$LN_MILESTONE_STATE" '
        '"$BOARD_LIB"'
        .project.projectMilestones as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor,
           nodes: [$page.nodes[] | ln_milestone | select($state == "all" or .state == $state)]}'
}

linear_milestone_list() {
    linear_require_project || return $?
    LN_MILESTONE_STATE=$1
    board_paged linear_milestone_page "$2"
}

# Usage: linear_milestone_id <name>  — prints the id, or exit 4.
linear_milestone_id() {
    linear_mi_list=$(linear_milestone_list all all) || return $?
    linear_mi_id=$(printf '%s' "$linear_mi_list" | _jq -r --arg n "$1" \
        ''"$BOARD_LIB"' [.[] | select(.name | ieq($n)) | .id] | first // ""')
    [ -n "$linear_mi_id" ] || {
        board_warn "no milestone '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_mi_id"
}

linear_milestone_view() {
    linear_mv_doc=$(_jq -nc --arg id "$1" '{id: $id}' | linear_query MilestoneView) || return $?
    printf '%s' "$linear_mv_doc" | _jq -c ''"$BOARD_LIB"' .projectMilestone | ln_milestone'
}

linear_milestone_input() {
    _jq -c '
        (if .name then {name} else {} end)
        + (if .description != null then {description} else {} end)
        + (if .due then {targetDate: .due} else {} end)'
}

linear_milestone_create() {
    linear_require_project || return $?
    linear_mc_input=$(linear_milestone_input)
    linear_mc_meta=$(linear_meta) || return $?
    linear_mc_doc=$(printf '%s\n%s\n' "$linear_mc_input" "$linear_mc_meta" |
        _jq -sc '{input: (.[0] + {projectId: .[1].project.id})}' | linear_query MilestoneCreate) || return $?
    printf '%s' "$linear_mc_doc" | _jq -c ''"$BOARD_LIB"' .projectMilestoneCreate.projectMilestone | ln_milestone'
}

linear_milestone_edit() {
    linear_require_project || return $?
    linear_me_intent=$(cat)
    if printf '%s' "$linear_me_intent" | _jq -e '.state != null' >/dev/null; then
        board_warn "--state is not supported: a Linear milestone closes by itself when its issues are done"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    linear_me_doc=$(printf '%s' "$linear_me_intent" | linear_milestone_input | _jq -c --arg id "$1" \
        '{id: $id, input: .}' | linear_query MilestoneUpdate) || return $?
    printf '%s' "$linear_me_doc" | _jq -c ''"$BOARD_LIB"' .projectMilestoneUpdate.projectMilestone | ln_milestone'
}

linear_milestone_delete() {
    linear_require_project || return $?
    _jq -nc --arg id "$1" '{id: $id}' | linear_query MilestoneDelete >/dev/null
}

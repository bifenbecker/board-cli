# shellcheck shell=sh

# Iterations need a paid tier. REST says so only as a bare 403 with nothing about a license, the
# same as a missing permission, so the work item types are asked instead.
gitlab_require_iterations() {
    gitlab_ri_types=$(gitlab_query WorkItemTypes -f "path=$GL_PATH") || return $?
    if printf '%s' "$gitlab_ri_types" | _jq -e \
        'any(.data.project.workItemTypes.nodes[].widgetDefinitions[]; .type == "ITERATION")' >/dev/null; then
        return 0
    fi
    board_warn "iterations need a Premium tier: this GitLab project has none"
    return "$BOARD_EXIT_UNSUPPORTED"
}

# Newest first.
gitlab_sprints() {
    gitlab_require_iterations || return $?
    gitlab_sp_doc=$(gitlab_rest_all "projects/$GL_ID/iterations?per_page=100") || return $?
    printf '%s' "$gitlab_sp_doc" | _jq -c ''"$BOARD_LIB"' map(gl_sprint) | sort_by(.start_date) | reverse'
}

# Usage: gitlab_iteration_id <name|current>
gitlab_iteration_id() {
    gitlab_it_doc=$(gitlab_sprints) || return $?
    gitlab_it_id=$(printf '%s' "$gitlab_it_doc" | _jq -r --arg want "$1" '
        '"$BOARD_LIB"'
        [.[] | select(if $want == "current" then .state == "active" else (.name | ieq($want)) end) | .id] | first // ""')
    if [ -z "$gitlab_it_id" ]; then
        board_warn "no sprint '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$gitlab_it_id"
}

gitlab_sprint_list() {
    gitlab_sl_doc=$(gitlab_sprints) || return $?
    printf '%s' "$gitlab_sl_doc" | _jq -c --arg s "$1" --arg l "$2" '
        map(select($s == "all" or .state == $s))
        | if $l == "all" then . else .[:($l | tonumber)] end'
}

gitlab_sprint_view() {
    gitlab_sv_doc=$(gitlab_sprints) || return $?
    gitlab_sv_hit=$(printf '%s' "$gitlab_sv_doc" | _jq -c --arg id "$1" '[.[] | select(.id == $id)] | first // empty')
    if [ -z "$gitlab_sv_hit" ]; then
        board_warn "no sprint $1"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$gitlab_sv_hit"
}

gitlab_sprint_current() {
    gitlab_sc_doc=$(gitlab_sprints) || return $?
    gitlab_sc_hit=$(printf '%s' "$gitlab_sc_doc" | _jq -c '[.[] | select(.state == "active")] | first // empty')
    if [ -z "$gitlab_sc_hit" ]; then
        board_warn "no sprint is active"
        return "$BOARD_EXIT_NOT_FOUND"
    fi
    printf '%s' "$gitlab_sc_hit"
}

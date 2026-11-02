# shellcheck shell=sh

# A sprint is a cycle of the team. Cycles are a team setting; with them off nothing here exists.

linear_require_cycles() {
    linear_rc_meta=$(linear_meta) || return $?
    if ! printf '%s' "$linear_rc_meta" | _jq -e .team.cyclesEnabled >/dev/null; then
        board_warn "team $LN_TEAM has cycles turned off"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
}

linear_cycle_page() {
    linear_cp_doc=$(_jq -nc --arg team "$LN_TEAM" --arg after "$1" \
        '{team: $team, after: (if $after == "" then null else $after end)}' | linear_query CycleList) || return $?
    printf '%s' "$linear_cp_doc" | _jq -c '
        .team.cycles as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor, nodes: $page.nodes}'
}

# The raw cycles, newest first.
linear_cycles() {
    linear_require_cycles || return $?
    linear_cy_doc=$(board_paged linear_cycle_page all) || return $?
    printf '%s' "$linear_cy_doc" | _jq -c 'sort_by(.startsAt) | reverse'
}

linear_sprint_list() {
    linear_sl_doc=$(linear_cycles) || return $?
    printf '%s' "$linear_sl_doc" | _jq -c --arg s "$1" '
        '"$BOARD_LIB"' map(ln_sprint | select($s == "all" or .state == $s))' | board_cut "$2"
}

linear_sprint_view() {
    linear_sv_doc=$(linear_sprint_list all all) || return $?
    linear_sv_hit=$(printf '%s' "$linear_sv_doc" | _jq -c --arg id "$1" '[.[] | select(.id == $id)] | first // empty')
    [ -n "$linear_sv_hit" ] || {
        board_warn "no sprint $1"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_sv_hit"
}

linear_sprint_current() {
    linear_sc_doc=$(linear_sprint_list active all) || return $?
    linear_sc_hit=$(printf '%s' "$linear_sc_doc" | _jq -c 'first // empty')
    [ -n "$linear_sc_hit" ] || {
        board_warn "no sprint is active"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_sc_hit"
}

# Usage: linear_cycle_id <name|number|current>  — prints Linear's own id, which is what an issue takes.
linear_cycle_id() {
    linear_ci_doc=$(linear_cycles) || return $?
    linear_ci_id=$(printf '%s' "$linear_ci_doc" | _jq -r --arg want "$1" '
        '"$BOARD_LIB"'
        [.[] | select(if $want == "current" then .isActive
                      else (.number | tostring) == $want or (ln_cycle_name | ieq($want)) end) | .id]
        | first // ""')
    [ -n "$linear_ci_id" ] || {
        board_warn "no sprint '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_ci_id"
}

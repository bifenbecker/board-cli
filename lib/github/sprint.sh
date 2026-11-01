# shellcheck shell=sh

# Iterations of the field named in [board.target] sprint_field, newest first.
github_sprints() {
    [ -n "$GH_SPRINT_FIELD" ] || {
        board_warn "declare [board.target] sprint_field: the name of the project's iteration field"
        return "$BOARD_EXIT_UNSUPPORTED"
    }
    github_sp_meta=$(github_meta) || return $?
    github_sp_doc=$(printf '%s' "$github_sp_meta" | _jq -c --arg f "$GH_SPRINT_FIELD" --arg today "$(date -u +%Y-%m-%d)" '
        include "jq/common";
        [.fields.nodes[] | select(.name != null) | select(.name | ieq($f))] | first
        | if .configuration == null then null else
          def end_of: (.startDate + "T00:00:00Z" | fromdateiso8601) + (.duration * 86400) - 86400 | todate | .[0:10];
          [(.configuration.iterations[]
            | {id, name: .title, start_date: .startDate, end_date: end_of}
            | .state = (if .start_date <= $today and $today <= .end_date then "active" else "future" end)),
           (.configuration.completedIterations[]
            | {id, name: .title, start_date: .startDate, end_date: end_of, state: "closed"})]
          | map(make_sprint) | sort_by(.start_date) | reverse end')
    if [ "$github_sp_doc" = null ]; then
        board_warn "field '$GH_SPRINT_FIELD' is not an iteration field"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
    printf '%s' "$github_sp_doc"
}

github_sprint_list() {
    github_env
    github_sl_doc=$(github_sprints) || return $?
    printf '%s' "$github_sl_doc" | _jq -c --arg s "$1" --arg l "$2" '
        map(select($s == "all" or .state == $s))
        | if $l == "all" then . else .[:($l | tonumber)] end'
}

github_sprint_view() {
    github_env
    github_sv_doc=$(github_sprints) || return $?
    github_sv_hit=$(printf '%s' "$github_sv_doc" | _jq -c --arg id "$1" '[.[] | select(.id == $id)] | first // empty')
    [ -n "$github_sv_hit" ] || {
        board_warn "no sprint $1"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$github_sv_hit"
}

github_sprint_current() {
    github_env
    github_sc_doc=$(github_sprints) || return $?
    github_sc_hit=$(printf '%s' "$github_sc_doc" | _jq -c '[.[] | select(.state == "active")] | first // empty')
    [ -n "$github_sc_hit" ] || {
        board_warn "no sprint is active"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$github_sc_hit"
}

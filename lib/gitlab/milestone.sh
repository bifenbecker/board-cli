# shellcheck shell=sh

# A milestone is reached by the id REST gives it, not by the iid in its URL: that is what the
# paths under milestones/ take.

gitlab_milestone_body() {
    _jq -c '
        (if .name then {title: .name} else {} end)
        + (if .description != null then {description} else {} end)
        + (if .due then {due_date: .due} else {} end)
        + (if .state then {state_event: (if .state == "closed" then "close" else "activate" end)} else {} end)'
}

gitlab_milestone_page() {
    gitlab_mp_doc=$(gitlab_rest_page "projects/$GL_ID/milestones?per_page=100$GL_MILESTONE_STATE&page=${1:-1}") || return $?
    printf '%s' "$gitlab_mp_doc" | _jq -c --arg next "$(gitlab_next_page)" '
        '"$BOARD_LIB"'
        {has_next: ($next != ""), end_cursor: $next, nodes: map(gl_milestone)}'
}

gitlab_milestone_list() {
    case $1 in
        open) GL_MILESTONE_STATE='&state=active' ;;
        closed) GL_MILESTONE_STATE='&state=closed' ;;
        *) GL_MILESTONE_STATE='' ;;
    esac
    board_paged gitlab_milestone_page "$2"
}

gitlab_milestone_view() {
    board_require_int '<id>' "$1"
    gitlab_mv_doc=$(gitlab_rest GET "projects/$GL_ID/milestones/$1") || return $?
    printf '%s' "$gitlab_mv_doc" | _jq -c ''"$BOARD_LIB"' gl_milestone'
}

gitlab_milestone_create() {
    gitlab_mc_doc=$(gitlab_milestone_body | gitlab_rest_body POST "projects/$GL_ID/milestones") || return $?
    gitlab_has_id "$gitlab_mc_doc" milestone || return $?
    printf '%s' "$gitlab_mc_doc" | _jq -c ''"$BOARD_LIB"' gl_milestone'
}

gitlab_milestone_edit() {
    board_require_int '<id>' "$1"
    gitlab_me_doc=$(gitlab_milestone_body | gitlab_rest_body PUT "projects/$GL_ID/milestones/$1") || return $?
    gitlab_has_id "$gitlab_me_doc" milestone || return $?
    printf '%s' "$gitlab_me_doc" | _jq -c ''"$BOARD_LIB"' gl_milestone'
}

gitlab_milestone_delete() {
    board_require_int '<id>' "$1"
    gitlab_rest DELETE "projects/$GL_ID/milestones/$1" >/dev/null
}

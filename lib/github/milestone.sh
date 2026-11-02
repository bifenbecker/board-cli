# shellcheck shell=sh

github_milestone_body() {
    _jq -c '
        (if .name then {title: .name} else {} end)
        + (if .description != null then {description} else {} end)
        + (if .due then {due_on: (.due + "T12:00:00Z")} else {} end)
        + (if .state then {state} else {} end)'
}

github_milestone_list() {
    github_env
    github_ml_doc=$(github_rest_all "repos/$GH_REPO/milestones?state=$1&per_page=100") || return $?
    printf '%s' "$github_ml_doc" | _jq -c ''"$BOARD_LIB"' map(gh_milestone)' | board_cut "$2"
}

github_milestone_view() {
    github_env
    github_mv_doc=$(github_rest GET "repos/$GH_REPO/milestones/$1") || return $?
    printf '%s' "$github_mv_doc" | _jq -c ''"$BOARD_LIB"' gh_milestone'
}

github_milestone_create() {
    github_env
    github_mc_doc=$(github_milestone_body | github_rest_body POST "repos/$GH_REPO/milestones") || return $?
    printf '%s' "$github_mc_doc" | _jq -c ''"$BOARD_LIB"' gh_milestone'
}

github_milestone_edit() {
    github_env
    github_me_doc=$(github_milestone_body | github_rest_body PATCH "repos/$GH_REPO/milestones/$1") || return $?
    printf '%s' "$github_me_doc" | _jq -c ''"$BOARD_LIB"' gh_milestone'
}

github_milestone_delete() {
    github_env
    github_rest DELETE "repos/$GH_REPO/milestones/$1" >/dev/null
}

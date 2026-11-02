# shellcheck shell=sh

# A milestone is a version: released means closed.

jira_version_body() {
    _jq -c '
        (if .name then {name} else {} end)
        + (if .description != null then {description} else {} end)
        + (if .due then {releaseDate: .due} else {} end)
        + (if .state then {released: (.state == "closed")} else {} end)'
}

jira_version_out() {
    _jq -c --arg base "$JIRA_BASE" --arg project "$JIRA_PROJECT" ''"$BOARD_LIB"' jira_milestone($base; $project)'
}

jira_milestone_list() {
    jira_require_project
    jira_ml_doc=$(jira_call GET "/rest/api/2/project/$JIRA_PROJECT/versions") || return $?
    jira_ml_doc=$(printf '%s' "$jira_ml_doc" | _jq -c --arg s "$1" --arg base "$JIRA_BASE" --arg project "$JIRA_PROJECT" '
        '"$BOARD_LIB"'
        map(jira_milestone($base; $project) | select($s == "all" or .state == $s))') || return $?
    printf '%s' "$jira_ml_doc" | board_cut "$2"
}

jira_milestone_view() {
    jira_safe "<id>" "$1"
    jira_mv_doc=$(jira_call GET "/rest/api/2/version/$1") || return $?
    printf '%s' "$jira_mv_doc" | jira_version_out
}

jira_milestone_create() {
    jira_require_project
    BOARD_WRITE_ID=''
    jira_mc_doc=$(jira_version_body | _jq -c --arg p "$JIRA_PROJECT" '. + {project: $p}' |
        jira_send POST /rest/api/2/version) || return $?
    jira_written "$jira_mc_doc" id >/dev/null || return $?
    printf '%s' "$jira_mc_doc" | jira_version_out
}

jira_milestone_edit() {
    jira_safe "<id>" "$1"
    BOARD_WRITE_ID=$1
    jira_me_doc=$(jira_version_body | jira_send PUT "/rest/api/2/version/$1") || return $?
    jira_written "$jira_me_doc" id >/dev/null || return $?
    printf '%s' "$jira_me_doc" | jira_version_out
}

jira_milestone_delete() {
    jira_safe "<id>" "$1"
    BOARD_WRITE_ID=$1
    jira_call DELETE "/rest/api/2/version/$1" >/dev/null
}

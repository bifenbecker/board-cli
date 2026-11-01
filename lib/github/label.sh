# shellcheck shell=sh

github_label_list() {
    github_env
    github_ll_doc=$(github_rest_all "repos/$GH_REPO/labels?per_page=100") || return $?
    printf '%s' "$github_ll_doc" | _jq -c 'include "github/shape"; map(gh_label)'
}

github_label_create() {
    github_env
    github_lc_intent=$(cat)
    github_lc_name=$(printf '%s' "$github_lc_intent" | _jq -r .name)
    # Creating twice must succeed: look first, because a 422 here also means a bad color.
    github_lc_have=$(github_label_list) || return $?
    github_lc_hit=$(printf '%s' "$github_lc_have" | _jq -c --arg n "$github_lc_name" \
        'include "jq/common"; [.[] | select(.name | ieq($n))] | first // empty')
    if [ -n "$github_lc_hit" ]; then
        printf '%s' "$github_lc_hit"
        return 0
    fi
    github_lc_doc=$(printf '%s' "$github_lc_intent" | _jq -c '
        {name} + (if .color then {color} else {} end) + (if .description != null then {description} else {} end)' |
        github_rest_body POST "repos/$GH_REPO/labels") || return $?
    printf '%s' "$github_lc_doc" | _jq -c 'include "github/shape"; gh_label'
}

github_label_edit() {
    github_env
    github_le_intent=$(cat)
    github_le_name=$(printf '%s' "$github_le_intent" | _jq -r .name)
    github_le_path=repos/$GH_REPO/labels/$(board_urlencode "$github_le_name")
    github_le_doc=$(printf '%s' "$github_le_intent" | _jq -c '
        (if .new_name then {new_name} else {} end) + (if .color then {color} else {} end)
        + (if .description != null then {description} else {} end)' |
        github_rest_body PATCH "$github_le_path") || return $?
    printf '%s' "$github_le_doc" | _jq -c 'include "github/shape"; gh_label'
}

github_label_delete() {
    github_env
    github_rest DELETE "repos/$GH_REPO/labels/$(board_urlencode "$1")" >/dev/null
}

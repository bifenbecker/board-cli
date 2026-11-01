# shellcheck shell=sh

github_member_list() {
    github_env
    github_ml_doc=$(github_rest_all "repos/$GH_REPO/assignees?per_page=100") || return $?
    printf '%s' "$github_ml_doc" | _jq -c --arg s "$1" '
        include "jq/common";
        [.[] | {id: .login, name: .login} | make_member
         | select($s == "" or (.name | test($s | re_escape; "i")))]'
}

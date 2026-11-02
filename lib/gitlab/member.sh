# shellcheck shell=sh

gitlab_member_list() {
    gitlab_ml_doc=$(gitlab_rest_all "projects/$GL_ID/members/all?per_page=100") || return $?
    printf '%s' "$gitlab_ml_doc" | _jq -c --arg s "$1" '
        '"$BOARD_LIB"'
        [.[] | select(.state == "active") | {id: .username, name} | make_member
         | select($s == "" or (.name | test($s | re_escape; "i")) or (.id | test($s | re_escape; "i")))]'
}

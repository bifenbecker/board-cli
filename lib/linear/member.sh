# shellcheck shell=sh

linear_member_page() {
    linear_mp_doc=$(_jq -nc --arg team "$LN_TEAM" --arg after "$1" \
        '{team: $team, after: (if $after == "" then null else $after end)}' | linear_query MemberList) || return $?
    printf '%s' "$linear_mp_doc" | _jq -c '
        .team.members as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor, nodes: $page.nodes}'
}

# The raw members of the team, with both of their names.
linear_members() {
    linear_require_team
    board_paged linear_member_page all
}

linear_member_list() {
    linear_ml_doc=$(linear_members) || return $?
    printf '%s' "$linear_ml_doc" | _jq -c --arg s "$1" '
        '"$BOARD_LIB"'
        [.[] | select($s == "" or ((.name + " " + .displayName) | test($s | re_escape; "i")))
         | ln_user | make_member]'
}

# Usage: linear_member_id <@me|id|name|display name>  — prints the id, or exit 4.
linear_member_id() {
    if [ "$1" = @me ]; then
        linear_mi_doc=$(linear_viewer) || return $?
        printf '%s' "$linear_mi_doc" | _jq -r .id
        return 0
    fi
    linear_mi_doc=$(linear_members) || return $?
    linear_mi_id=$(printf '%s' "$linear_mi_doc" | _jq -r --arg who "$1" '
        '"$BOARD_LIB"'
        [.[] | select(.id == $who or (.name | ieq($who)) or (.displayName | ieq($who))) | .id] | first // ""')
    [ -n "$linear_mi_id" ] || {
        board_warn "no member '$1' on team $LN_TEAM"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_mi_id"
}

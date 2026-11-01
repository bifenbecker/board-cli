# shellcheck shell=sh

# A status is a label declared in [board.statuses] and, usually, a list on the board. GitLab keeps
# the list when the label is renamed and drops it when the label is deleted.

gitlab_status_list() {
    printf '%s' "$BOARD_CONFIG_JSON" | _jq -c '
        '"$BOARD_LIB"'
        . as $cfg | [gl_status_names($cfg)[] | {name: .} | make_status($cfg)]'
}

# A declared status under its declared spelling: labels are case-sensitive on GitLab.
gitlab_status_spelling() {
    gitlab_ss_hit=$(gitlab_status_find "$1")
    if [ -n "$gitlab_ss_hit" ]; then
        printf '%s' "$gitlab_ss_hit" | _jq -r .name
    else
        printf '%s' "$1"
    fi
}

gitlab_status_add() {
    board_provider_load label
    gitlab_sa_labels=$(gitlab_labels_raw) || return $?
    gitlab_sa_label=$(printf '%s' "$gitlab_sa_labels" | _jq -c --arg n "$1" \
        ''"$BOARD_LIB"' [.[] | select(.name | ieq($n))] | first // empty')
    if [ -z "$gitlab_sa_label" ]; then
        gitlab_sa_label=$(_jq -nc --arg n "$1" '{name: $n, color: "#6699cc"}' |
            gitlab_rest_body POST "projects/$GL_ID/labels") || return $?
        GL_WROTE=1
    fi
    gitlab_sa_id=$(printf '%s' "$gitlab_sa_label" | _jq -r .id)
    gitlab_sa_board=$(gitlab_board_doc) ||
        gitlab_step_failed $? "$1" "the label exists, but the board could not be read" || return $?
    gitlab_sa_list=$(printf '%s' "$gitlab_sa_board" | _jq -r --argjson l "$gitlab_sa_id" \
        '[.lists[] | select(.label.id == $l) | .id] | first // ""')
    if [ -z "$gitlab_sa_list" ]; then
        gitlab_sa_path=projects/$GL_ID/boards/$(printf '%s' "$gitlab_sa_board" | _jq -r .id)/lists
        _jq -nc --argjson l "$gitlab_sa_id" '{label_id: $l}' | gitlab_rest_body POST "$gitlab_sa_path" >/dev/null ||
            gitlab_step_failed $? "$1" "the label exists, but the list could not be added to the board" || return $?
    fi
    printf '%s' "$gitlab_sa_label" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg c "$2" '
        '"$BOARD_LIB"' {id, name} | make_status($cfg) | .category = (.category // $c)'
}

gitlab_status_rename() {
    gitlab_sr_old=$(gitlab_status_spelling "$1")
    gitlab_sr_doc=$(_jq -nc --arg n "$2" '{new_name: $n}' |
        gitlab_rest_body PUT "projects/$GL_ID/labels/$(board_urlencode "$gitlab_sr_old")") || return $?
    printf '%s' "$gitlab_sr_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg old "$gitlab_sr_old" '
        '"$BOARD_LIB"' {id, name, native: category_of($cfg; $old; null)} | make_status($cfg)'
}

gitlab_status_delete() {
    gitlab_rest DELETE "projects/$GL_ID/labels/$(board_urlencode "$(gitlab_status_spelling "$1")")" >/dev/null
}

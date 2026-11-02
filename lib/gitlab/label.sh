# shellcheck shell=sh

gitlab_labels_raw() {
    gitlab_rest_all "projects/$GL_ID/labels?per_page=100"
}

gitlab_label_list() {
    gitlab_ll_doc=$(gitlab_labels_raw) || return $?
    printf '%s' "$gitlab_ll_doc" | _jq -c ''"$BOARD_LIB"' map(gl_label)'
}

gitlab_label_create() {
    gitlab_lc_intent=$(cat)
    gitlab_lc_name=$(printf '%s' "$gitlab_lc_intent" | _jq -r .name)
    # Creating twice must succeed: look first, because a 400 here also means a bad color.
    gitlab_lc_have=$(gitlab_label_list) || return $?
    gitlab_lc_hit=$(printf '%s' "$gitlab_lc_have" | _jq -c --arg n "$gitlab_lc_name" \
        ''"$BOARD_LIB"' [.[] | select(.name | ieq($n))] | first // empty')
    if [ -n "$gitlab_lc_hit" ]; then
        printf '%s' "$gitlab_lc_hit"
        return 0
    fi
    # GitLab requires a color. This one is what it gives a label created by first use.
    gitlab_lc_doc=$(printf '%s' "$gitlab_lc_intent" | _jq -c '
        {name, color: ("#" + (.color // "6699cc"))} + (if .description != null then {description} else {} end)' |
        gitlab_rest_body POST "projects/$GL_ID/labels") || return $?
    gitlab_has_id "$gitlab_lc_doc" label || return $?
    printf '%s' "$gitlab_lc_doc" | _jq -c ''"$BOARD_LIB"' gl_label'
}

gitlab_label_edit() {
    gitlab_le_intent=$(cat)
    gitlab_le_name=$(gitlab_label_real "$(printf '%s' "$gitlab_le_intent" | _jq -r .name)") || return $?
    gitlab_le_doc=$(printf '%s' "$gitlab_le_intent" | _jq -c '
        (if .new_name then {new_name} else {} end) + (if .color then {color: ("#" + .color)} else {} end)
        + (if .description != null then {description} else {} end)' |
        gitlab_rest_body PUT "projects/$GL_ID/labels/$(board_urlencode "$gitlab_le_name")") || return $?
    gitlab_has_id "$gitlab_le_doc" label || return $?
    printf '%s' "$gitlab_le_doc" | _jq -c ''"$BOARD_LIB"' gl_label'
}

gitlab_label_delete() {
    gitlab_ld_name=$(gitlab_label_real "$1") || return $?
    gitlab_rest DELETE "projects/$GL_ID/labels/$(board_urlencode "$gitlab_ld_name")" >/dev/null
}

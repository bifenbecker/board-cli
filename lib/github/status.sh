# shellcheck shell=sh

# Status is the single-select field called Status. Changing its options replaces the whole set:
# an option resent with its id keeps its id and its items, and one left out is deleted.

github_status_list() {
    github_sl_meta=$(github_meta) || return $?
    printf '%s' "$github_sl_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        [.fields.nodes[] | select(.name == "Status") | .options[] | {id, name} | make_status($cfg)]'
}

# Usage: github_status_write <jq filter over the option list> [<$a>] [<$b>]
# Values go in as --arg: jq on Windows reads env.* in the ANSI code page, which turns Cyrillic
# into question marks, and that would be written to the board.
github_status_write() {
    github_sw_field=$(github_status_field) || return $?
    github_sw_id=$(printf '%s' "$github_sw_field" | _jq -r .id)
    rm -f "$BOARD_TMP/github.meta"
    printf '%s' "$github_sw_field" | _jq -c --arg field "$github_sw_id" --arg a "${2:-}" --arg b "${3:-}" "
        {fieldId: \$field, options: (.options | map({id, name, color, description}) | $1)}" |
        github_query SetOptions
}

# The status as it now is, after a write that went through.
# Usage: github_status_final <name>
github_status_final() {
    github_sn_all=$(github_status_list) || board_partial "$1" "the status changed, but could not be read back"
    printf '%s' "$github_sn_all" | _jq -c --arg n "$1" '[.[] | select(.name == $n)] | first'
}

github_status_add() {
    github_sa_have=$(github_status_list) || return $?
    github_sa_hit=$(printf '%s' "$github_sa_have" | _jq -c --arg n "$1" \
        ''"$BOARD_LIB"' [.[] | select(.name | ieq($n))] | first // empty')
    if [ -n "$github_sa_hit" ]; then
        printf '%s' "$github_sa_hit"
        return 0
    fi
    github_status_write '. + [{name: $a, color: "GRAY", description: ""}]' "$1" >/dev/null || return $?
    github_sa_doc=$(github_status_final "$1") || return $?
    printf '%s' "$github_sa_doc" | _jq -c --arg c "$2" '.category = (.category // $c)'
}

github_status_rename() {
    github_sr_doc=$(github_option Status "$1") || return $?
    github_sr_id=$(printf '%s' "$github_sr_doc" | _jq -r .option)
    github_status_write 'map(if .id == $a then .name = $b else . end)' "$github_sr_id" "$2" >/dev/null || return $?
    github_status_final "$2"
}

github_status_delete() {
    github_sd_doc=$(github_option Status "$1") || return $?
    github_sd_id=$(printf '%s' "$github_sd_doc" | _jq -r .option)
    github_status_write 'map(select(.id != $a))' "$github_sd_id" >/dev/null
}

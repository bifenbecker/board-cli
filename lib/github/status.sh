# shellcheck shell=sh

# Status is the single-select field called Status. Changing its options replaces the whole set:
# an option resent with its id keeps its id and its items, and one left out is deleted.

github_status_list() {
    github_sl_meta=$(github_meta) || return $?
    printf '%s' "$github_sl_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        include "jq/common";
        [.fields.nodes[] | select(.name == "Status") | .options[] | {id, name} | make_status($cfg)]'
}

# Usage: <jq filter over the option list> | github_status_write <filter> — prints the new options.
github_status_write() {
    github_sw_field=$(github_status_field) || return $?
    github_sw_id=$(printf '%s' "$github_sw_field" | _jq -r .id)
    rm -f "$BOARD_TMP/github.meta"
    printf '%s' "$github_sw_field" | _jq -c --arg id "$github_sw_id" "
        {fieldId: \$id, options: (.options | map({id, name, color, description}) | $1)}" |
        github_query SetOptions
}

github_status_add() {
    github_sa_have=$(github_status_list) || return $?
    if printf '%s' "$github_sa_have" | _jq -e --arg n "$1" 'include "jq/common"; any(.[]; .name | ieq($n))' >/dev/null; then
        printf '%s' "$github_sa_have" | _jq -c --arg n "$1" 'include "jq/common"; [.[] | select(.name | ieq($n))] | first'
        return 0
    fi
    GH_STATUS_NAME=$1
    export GH_STATUS_NAME
    github_status_write '. + [{name: env.GH_STATUS_NAME, color: "GRAY", description: ""}]' >/dev/null || return $?
    github_status_list | _jq -c --arg n "$1" --arg c "$2" \
        '[.[] | select(.name == $n)] | first | .category = (.category // $c)'
}

github_status_rename() {
    github_option Status "$1" >/dev/null || return $?
    GH_STATUS_NAME=$1 GH_STATUS_NEW=$2
    export GH_STATUS_NAME GH_STATUS_NEW
    github_status_write 'map(if (.name | ascii_downcase) == (env.GH_STATUS_NAME | ascii_downcase) or .name == env.GH_STATUS_NAME
                             then .name = env.GH_STATUS_NEW else . end)' >/dev/null || return $?
    github_status_list | _jq -c --arg n "$2" '[.[] | select(.name == $n)] | first'
}

github_status_delete() {
    github_sd_doc=$(github_option Status "$1") || return $?
    GH_STATUS_ID=$(printf '%s' "$github_sd_doc" | _jq -r .option)
    export GH_STATUS_ID
    github_status_write 'map(select(.id != env.GH_STATUS_ID))' >/dev/null
}

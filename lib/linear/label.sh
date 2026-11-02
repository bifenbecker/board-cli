# shellcheck shell=sh

# A team's label list holds the team's labels and the workspace's. A new one goes to the team.

linear_label_page() {
    linear_lp_doc=$(_jq -nc --arg team "$LN_TEAM" --arg after "$1" \
        '{team: $team, after: (if $after == "" then null else $after end)}' | linear_query LabelList) || return $?
    printf '%s' "$linear_lp_doc" | _jq -c '
        '"$BOARD_LIB"'
        .team.labels as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor,
           nodes: [$page.nodes[] | ln_label]}'
}

linear_label_list() {
    linear_require_team
    board_paged linear_label_page all
}

# Usage: linear_label_find <name>  — prints the label, or nothing.
linear_label_find() {
    linear_lf_have=$(linear_label_list) || return $?
    printf '%s' "$linear_lf_have" | _jq -c --arg n "$1" ''"$BOARD_LIB"' [.[] | select(.name | ieq($n))] | first // empty'
}

# Usage: linear_label_found <name>  — prints the id. A label that is not there is exit 4.
linear_label_found() {
    linear_lg_hit=$(linear_label_find "$1") || return $?
    [ -n "$linear_lg_hit" ] || {
        board_warn "no label '$1'"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    printf '%s' "$linear_lg_hit" | _jq -r .id
}

# Linear refuses a longer name. Called before the first write, not left to fail halfway.
# Usage: linear_label_fits <JSON array of names>
linear_label_fits() {
    linear_lt_long=$(printf '%s' "$1" | _jq -r 'map(select(length > 80)) | first // ""')
    [ -z "$linear_lt_long" ] || board_usage_die "a label name takes at most 80 characters: '$linear_lt_long'"
}

# Usage: linear_label_split <JSON array of names>  — prints {known: [ids], missing: [names]}, each
# label once however it was spelled.
linear_label_split() {
    if [ "$1" = '[]' ]; then
        printf '{"known":[],"missing":[]}'
        return 0
    fi
    linear_lp_have=$(linear_label_list) || return $?
    linear_lp_doc=$(printf '%s\n%s\n' "$1" "$linear_lp_have" | _jq -sc '
        '"$BOARD_LIB"'
        .[1] as $have
        | reduce .[0][] as $n ([]; if any(.[]; ieq($n)) then . else . + [$n] end)
        | map(. as $n | {name: $n, hit: ([$have[] | select(.name | ieq($n)) | .id] | first)})
        | {known: (map(select(.hit) | .hit) | unique), missing: map(select(.hit == null) | .name)}')
    linear_label_fits "$(printf '%s' "$linear_lp_doc" | _jq -c .missing)"
    printf '%s' "$linear_lp_doc"
}

# Usage: <label input JSON on stdin> | linear_label_write  — prints the new label, raw.
linear_label_write() {
    linear_lw_meta=$(linear_meta) || return $?
    _jq -c --arg team "$(printf '%s' "$linear_lw_meta" | _jq -r .team.id)" '{input: (. + {teamId: $team})}' |
        linear_query LabelCreate
}

# Usage: linear_label_make <name>  — creates a label with Linear's default color, and prints its id.
linear_label_make() {
    linear_lm_doc=$(_jq -nc --arg n "$1" '{name: $n}' | linear_label_write) || return $?
    printf '%s' "$linear_lm_doc" | _jq -r .issueLabelCreate.issueLabel.id
}

# Intent to input. The board's color has a #, board's does not.
linear_label_input() {
    _jq -c '
        (if .new_name then {name: .new_name} else {} end)
        + (if .color then {color: ("#" + .color)} else {} end)
        + (if .description != null then {description} else {} end)'
}

linear_label_create() {
    linear_require_team
    linear_lc_intent=$(cat)
    linear_label_fits "$(printf '%s' "$linear_lc_intent" | _jq -c '[.name]')"
    linear_lc_name=$(printf '%s' "$linear_lc_intent" | _jq -r .name)
    # Creating twice must succeed, and Linear answers it with an error.
    linear_lc_hit=$(linear_label_find "$linear_lc_name") || return $?
    if [ -n "$linear_lc_hit" ]; then
        printf '%s' "$linear_lc_hit"
        return 0
    fi
    linear_lc_doc=$(printf '%s' "$linear_lc_intent" | _jq -c '. + {new_name: .name}' | linear_label_input |
        linear_label_write) || return $?
    printf '%s' "$linear_lc_doc" | _jq -c ''"$BOARD_LIB"' .issueLabelCreate.issueLabel | ln_label'
}

linear_label_edit() {
    linear_require_team
    linear_le_intent=$(cat)
    linear_label_fits "$(printf '%s' "$linear_le_intent" | _jq -c '[.new_name // empty]')"
    linear_le_name=$(printf '%s' "$linear_le_intent" | _jq -r .name)
    linear_le_id=$(linear_label_found "$linear_le_name") || return $?
    linear_le_doc=$(printf '%s' "$linear_le_intent" | linear_label_input | _jq -c --arg id "$linear_le_id" \
        '{id: $id, input: .}' | linear_query LabelUpdate) || return $?
    printf '%s' "$linear_le_doc" | _jq -c ''"$BOARD_LIB"' .issueLabelUpdate.issueLabel | ln_label'
}

linear_label_delete() {
    linear_require_team
    linear_ld_id=$(linear_label_found "$1") || return $?
    _jq -nc --arg id "$linear_ld_id" '{id: $id}' | linear_query LabelDelete >/dev/null
}

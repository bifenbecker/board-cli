# shellcheck shell=sh

# A status is a workflow state of the team. Linear stores its category as the state's type, so a
# status added here needs no [board.statuses] line.

linear_status_list() {
    linear_sl_meta=$(linear_meta) || return $?
    printf '%s' "$linear_sl_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' .team.states.nodes | ln_statuses($cfg)'
}

linear_status_add() {
    linear_sa_have=$(linear_status_list) || return $?
    linear_sa_hit=$(printf '%s' "$linear_sa_have" | _jq -c --arg n "$1" ''"$BOARD_LIB"' [.[] | select(.name | ieq($n))] | first // empty')
    if [ -n "$linear_sa_hit" ]; then
        printf '%s' "$linear_sa_hit"
        return 0
    fi
    linear_sa_meta=$(linear_meta) || return $?
    # The color is required. These are Linear's own defaults for each type.
    linear_sa_doc=$(printf '%s' "$linear_sa_meta" | _jq -c --arg n "$1" --arg c "$2" '
        {todo: {type: "unstarted", color: "#e2e2e2"}, in_progress: {type: "started", color: "#f2c94c"},
         done: {type: "completed", color: "#5e6ad2"}, canceled: {type: "canceled", color: "#95a2b3"}}[$c] as $t
        | {input: ({teamId: .team.id, name: $n} + $t)}' | linear_query StateCreate) || return $?
    rm -f "$BOARD_TMP/linear.meta"
    printf '%s' "$linear_sa_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        ''"$BOARD_LIB"' .workflowStateCreate.workflowState | ln_status($cfg)'
}

linear_status_rename() {
    linear_sr_id=$(linear_state "$1") || return $?
    # Linear would take it when the types differ, and then neither name could be moved to. Only
    # the status itself may hold the new name: that is a change of case.
    linear_sr_taken=$(linear_state_ids "$2") || return $?
    linear_sr_taken=$(printf '%s' "$linear_sr_taken" | _jq -c --arg id "$linear_sr_id" 'map(select(. != $id))')
    [ "$linear_sr_taken" = '[]' ] || board_usage_die "a status named '$2' exists already"
    linear_sr_doc=$(_jq -nc --arg id "$linear_sr_id" --arg n "$2" '{id: $id, input: {name: $n}}' |
        linear_query StateUpdate) || return $?
    rm -f "$BOARD_TMP/linear.meta"
    printf '%s' "$linear_sr_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" \
        ''"$BOARD_LIB"' .workflowStateUpdate.workflowState | ln_status($cfg)'
}

# There is no delete: an archived state stays in the team, hidden, and its name is free again.
linear_status_delete() {
    linear_sd_id=$(linear_state "$1") || return $?
    _jq -nc --arg id "$linear_sd_id" '{id: $id}' | linear_query StateArchive >/dev/null
}

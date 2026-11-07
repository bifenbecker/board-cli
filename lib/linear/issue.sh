# shellcheck shell=sh

# An issue is reached by its identifier, 3KD-13: Linear takes it wherever an issue id goes. Every
# call reads the issue before it writes: Linear lets a trashed issue be changed without a word.

# Prints the raw issue, with all of its labels, children and relations: writes decide from them.
linear_fetch() {
    linear_ft_doc=$(_jq -nc --arg id "$1" '{id: $id}' | linear_query IssueView) || return $?
    # A deleted issue stays readable for its 30 days in the trash, but for board it is gone.
    linear_ft_doc=$(printf '%s' "$linear_ft_doc" | _jq -c '.issue | select(.trashed != true)')
    [ -n "$linear_ft_doc" ] || {
        board_warn "issue $1 is in the trash"
        return "$BOARD_EXIT_NOT_FOUND"
    }
    linear_ft_seen=''
    while :; do
        # Almost no issue has more, so the usual answer costs no process.
        case $linear_ft_doc in
            *'"hasNextPage":true'*) ;;
            *) break ;;
        esac
        linear_ft_more=$(printf '%s' "$linear_ft_doc" | _jq -c ''"$BOARD_LIB"' ln_more')
        [ -n "$linear_ft_more" ] || break
        [ "$linear_ft_more" != "$linear_ft_seen" ] || board_die "the board returned the same page twice"
        linear_ft_seen=$linear_ft_more
        linear_ft_page=$(printf '%s' "$linear_ft_more" | linear_query IssueMore) || return $?
        linear_ft_doc=$(printf '%s\n%s\n' "$linear_ft_doc" "$linear_ft_page" |
            _jq -sc ''"$BOARD_LIB"' [.[0], .[1].issue] | ln_merge')
    done
    printf '%s' "$linear_ft_doc"
}

linear_normalise() {
    _jq -c --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' ln_issue($cfg)'
}

linear_issue_view() {
    linear_iv_doc=$(linear_fetch "$1") || return $?
    printf '%s' "$linear_iv_doc" | linear_normalise
}

# One page of the history of LN_HISTORY_ID: only the entries that change the state.
linear_history_page() {
    linear_hp_doc=$(_jq -nc --arg id "$LN_HISTORY_ID" --arg after "$1" \
        '{id: $id, after: (if $after == "" then null else $after end)}' | linear_query IssueHistory) || return $?
    printf '%s' "$linear_hp_doc" | _jq -c ''"$BOARD_LIB"' .issue.history
        | {nodes: (.nodes | ln_moves), has_next: .pageInfo.hasNextPage, end_cursor: .pageInfo.endCursor}'
}

linear_issue_history() {
    linear_ih_issue=$(linear_issue_view "$1") || return $?
    LN_HISTORY_ID=$1
    linear_ih_moves=$(board_paged linear_history_page all) || return $?
    printf '%s\n%s\n' "$linear_ih_issue" "$linear_ih_moves" |
        _jq -sc --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' {issue: .[0], moves: .[1]} | make_history($cfg)'
}

# The answer that ends a write. Linear can go on showing the old issue for some seconds after it
# reported success, so this reads until the test holds, for LN_SETTLE_SECONDS however long each read
# takes. A failed read is one more try: the write is done whatever happens here.
# Usage: linear_settle <id> <jq test on the raw issue> [jq args...]
linear_settle() {
    linear_sl_id=$1 linear_sl_test=$2
    shift 2
    linear_sl_end=$(($(date +%s) + LN_SETTLE_SECONDS))
    while :; do
        # A read left to its own 60 seconds would outlive the deadline.
        linear_sl_left=$((linear_sl_end - $(date +%s)))
        [ "$linear_sl_left" -ge 5 ] || linear_sl_left=5
        if linear_sl_raw=$(
            BOARD_TIMEOUT=$linear_sl_left
            linear_fetch "$linear_sl_id" 2>/dev/null
        ); then
            if printf '%s' "$linear_sl_raw" | _jq -e "$@" ''"$BOARD_LIB"' '"$linear_sl_test" >/dev/null; then
                printf '%s' "$linear_sl_raw" | linear_normalise
                return 0
            fi
            linear_sl_why="the change went through, but the board still shows the old state"
        else
            linear_sl_why="the change went through, but the issue could not be read back"
        fi
        [ "$(date +%s)" -lt "$linear_sl_end" ] || board_partial "$linear_sl_id" "$linear_sl_why"
        sleep 2
    done
}

# After a write of the issue itself: LN_STAMP is the updatedAt that write reported.
linear_final_view() {
    linear_settle "$1" '.updatedAt >= $stamp' --arg stamp "$LN_STAMP"
}

# Linear has no issue types.
linear_refuse_type() {
    if printf '%s' "$1" | _jq -e '.type != null' >/dev/null; then
        board_warn "--type is not supported: Linear has no issue types"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
}

# Usage: linear_one_assignee <JSON array of names>
linear_one_assignee() {
    if printf '%s' "$1" | _jq -e 'length > 1' >/dev/null; then
        board_warn "a Linear issue has one assignee"
        return "$BOARD_EXIT_UNSUPPORTED"
    fi
}

# Issue updates are one mutation, so a change of several fields is all or nothing.
# Usage: LN_STAMP=$(<input JSON on stdin> | linear_update <id>)  — prints the new updatedAt.
linear_update() {
    linear_up_doc=$(_jq -c --arg id "$1" '{id: $id, input: .}' | linear_query IssueUpdate) || return $?
    printf '%s' "$linear_up_doc" | _jq -r .issueUpdate.issue.updatedAt
}

# --- list --------------------------------------------------------------------------------

linear_list_page() {
    linear_lp_doc=$(printf '%s' "$LN_LIST_VARS" | _jq -c --arg after "$1" \
        '. + {after: (if $after == "" then null else $after end)}' | linear_query IssueList) || return $?
    # Only an issue's labels end in this: the page of issues has a cursor after it.
    case $linear_lp_doc in
        *'"hasNextPage":true}'*) board_warn "an issue has more than 50 labels: 'board issue view' shows them all" ;;
    esac
    printf '%s' "$linear_lp_doc" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        {has_next: .issues.pageInfo.hasNextPage, end_cursor: .issues.pageInfo.endCursor,
         nodes: [.issues.nodes[] | ln_issue($cfg)]}'
}

# A filter naming what the board does not have matches nothing: that is an empty list, not an error.
# Usage: resolve || { linear_no_match "$?"; return $?; }
linear_no_match() {
    [ "$1" = "$BOARD_EXIT_NOT_FOUND" ] || return "$1"
    printf '[]'
}

linear_issue_list() {
    linear_il_intent=$(cat)
    linear_refuse_type "$linear_il_intent" || return $?
    linear_il_meta=$(linear_meta) || return $?
    eval "$(printf '%s' "$linear_il_intent" | _jq -r '
        @sh "linear_il_status=\(.status // "" | tostring)",
        @sh "linear_il_sprint=\(.sprint // "" | tostring) linear_il_limit=\(.limit // "all" | tostring)"')"
    linear_il_states='[]' linear_il_cycle=''
    if [ -n "$linear_il_status" ]; then
        linear_il_states=$(linear_state_ids "$linear_il_status") || return $?
        if [ "$linear_il_states" = '[]' ]; then
            printf '[]'
            return 0
        fi
    fi
    if [ -n "$linear_il_sprint" ]; then
        board_provider_load sprint
        linear_require_cycles || return $?
        if [ "$linear_il_sprint" != current ]; then
            linear_il_cycle=$(linear_cycle_id "$linear_il_sprint") || {
                linear_no_match "$?"
                return $?
            }
        fi
    fi
    LN_LIST_VARS=$(printf '%s\n%s\n' "$linear_il_intent" "$linear_il_meta" | _jq -sc \
        --argjson cfg "$BOARD_CONFIG_JSON" --argjson states "$linear_il_states" --arg cycle "$linear_il_cycle" '
        '"$BOARD_LIB"'
        .[1] as $meta | .[0]
        | {filter: ln_filter($meta; $cfg; $states; $cycle),
           first: (if .limit == null or .limit > 100 then 100 else .limit end)}')
    board_paged linear_list_page "$linear_il_limit"
}

# --- write -------------------------------------------------------------------------------

# Status, sprint and milestone names in an intent to ids. Prints the input fields they make.
linear_resolve() {
    eval "$(printf '%s' "$1" | _jq -r '
        @sh "linear_rs_status=\(.status // "" | tostring) linear_rs_sprint=\(.sprint // "" | tostring)",
        @sh "linear_rs_milestone=\(.milestone // "" | tostring) linear_rs_parent=\(.parent // "" | tostring)"')"
    linear_rs_state='' linear_rs_cycle='' linear_rs_stone=''
    if [ -n "$linear_rs_parent" ]; then
        linear_fetch "$linear_rs_parent" >/dev/null || return $?
    fi
    if [ -n "$linear_rs_status" ]; then
        linear_rs_state=$(linear_state "$linear_rs_status") || return $?
    fi
    if [ -n "$linear_rs_sprint" ]; then
        board_provider_load sprint
        linear_rs_cycle=$(linear_cycle_id "$linear_rs_sprint") || return $?
    fi
    if [ -n "$linear_rs_milestone" ]; then
        board_provider_load milestone
        linear_rs_stone=$(linear_milestone_id "$linear_rs_milestone") || return $?
    fi
    _jq -nc --arg s "$linear_rs_state" --arg c "$linear_rs_cycle" --arg m "$linear_rs_stone" '
        (if $s != "" then {stateId: $s} else {} end)
        + (if $c != "" then {cycleId: $c} else {} end)
        + (if $m != "" then {projectMilestoneId: $m} else {} end)'
}

# Creates the labels that do not exist yet and puts them on the issue.
# Usage: linear_labels_attach <id> <JSON array of names>
linear_labels_attach() {
    board_provider_load label
    linear_la_ids='[]'
    linear_la_names=$(printf '%s' "$2" | _jq -r '.[] | @base64')
    for linear_la_name in $linear_la_names; do
        linear_la_name=$(printf '%s' "$linear_la_name" | _jq -Rr '@base64d')
        linear_la_id=$(linear_label_make "$linear_la_name") || return $?
        linear_la_ids=$(printf '%s' "$linear_la_ids" | _jq -c --arg id "$linear_la_id" '. + [$id]')
    done
    LN_STAMP=$(printf '%s' "$linear_la_ids" | _jq -c '{addedLabelIds: .}' | linear_update "$1")
}

linear_issue_create() {
    linear_ic_intent=$(cat)
    linear_refuse_type "$linear_ic_intent" || return $?
    linear_ic_people=$(printf '%s' "$linear_ic_intent" | _jq -c .assignees)
    linear_one_assignee "$linear_ic_people" || return $?
    linear_ic_meta=$(linear_meta) || return $?
    linear_ic_ids=$(linear_resolve "$linear_ic_intent") || return $?
    linear_ic_who=$(printf '%s' "$linear_ic_people" | _jq -r '.[0] // ""')
    linear_ic_member=''
    if [ -n "$linear_ic_who" ]; then
        board_provider_load member
        linear_ic_member=$(linear_member_id "$linear_ic_who") || return $?
    fi
    board_provider_load label
    linear_ic_labels=$(printf '%s' "$linear_ic_intent" | _jq -c .labels)
    linear_ic_labels=$(linear_label_split "$linear_ic_labels") || return $?
    # Issues do not follow their parent into a project: it is named here every time.
    linear_ic_doc=$(printf '%s\n%s\n%s\n%s\n' "$linear_ic_intent" "$linear_ic_meta" "$linear_ic_ids" "$linear_ic_labels" |
        _jq -sc --arg member "$linear_ic_member" '
        '"$BOARD_LIB"'
        .[1] as $meta | .[2] as $ids | .[3] as $labels
        | {input: ({teamId: $meta.team.id}
                   + (if $meta.project then {projectId: $meta.project.id} else {} end)
                   + (.[0] | ln_fields)
                   + $ids
                   + (if $member != "" then {assigneeId: $member} else {} end)
                   + (if ($labels.known | length) > 0 then {labelIds: $labels.known} else {} end))}' |
        linear_query IssueCreate) || return $?
    linear_ic_id=$(printf '%s' "$linear_ic_doc" | _jq -r .issueCreate.issue.identifier)
    LN_STAMP=$(printf '%s' "$linear_ic_doc" | _jq -r .issueCreate.issue.updatedAt)
    # After the issue, so a failure here has an id to report.
    linear_ic_missing=$(printf '%s' "$linear_ic_labels" | _jq -c .missing)
    if [ "$linear_ic_missing" != '[]' ]; then
        linear_labels_attach "$linear_ic_id" "$linear_ic_missing" ||
            board_partial "$linear_ic_id" "the issue exists, but a new label could not be added"
    fi
    linear_final_view "$linear_ic_id"
}

# Prints the assignee part of an update, from what the intent asks and who has the issue now.
# Usage: linear_assignee_input <intent> <raw issue>
linear_assignee_input() {
    linear_ai_add=$(printf '%s' "$1" | _jq -c .add_assignees)
    linear_one_assignee "$linear_ai_add" || return $?
    linear_ai_who=$(printf '%s' "$linear_ai_add" | _jq -r '.[0] // ""')
    board_provider_load member
    if [ -n "$linear_ai_who" ]; then
        linear_ai_id=$(linear_member_id "$linear_ai_who") || return $?
        _jq -nc --arg id "$linear_ai_id" '{assigneeId: $id}'
        return 0
    fi
    linear_ai_me=''
    if printf '%s' "$1" | _jq -e '.remove_assignees | index("@me")' >/dev/null; then
        linear_ai_me=$(linear_viewer) || return $?
        linear_ai_me=$(printf '%s' "$linear_ai_me" | _jq -r .id)
    fi
    printf '%s\n%s\n' "$1" "$2" | _jq -sc --arg me "$linear_ai_me" '
        '"$BOARD_LIB"'
        .[1].assignee as $now
        | if $now != null and any(.[0].remove_assignees[];
              . == $now.id or . == "@me" and $me == $now.id
              or (. as $who | $now.name | ieq($who)) or (. as $who | $now.displayName | ieq($who)))
          then {assigneeId: null} else {} end'
}

linear_issue_edit() {
    linear_ie_id=$1
    linear_ie_intent=$(cat)
    linear_refuse_type "$linear_ie_intent" || return $?
    linear_ie_raw=$(linear_fetch "$linear_ie_id") || return $?
    linear_ie_ids=$(linear_resolve "$linear_ie_intent") || return $?
    linear_ie_who=$(linear_assignee_input "$linear_ie_intent" "$linear_ie_raw") || return $?
    board_provider_load label
    linear_ie_labels=$(printf '%s' "$linear_ie_intent" | _jq -c .add_labels)
    linear_ie_labels=$(linear_label_split "$linear_ie_labels") || return $?
    linear_ie_input=$(printf '%s\n%s\n%s\n%s\n%s\n' "$linear_ie_intent" "$linear_ie_raw" "$linear_ie_ids" \
        "$linear_ie_who" "$linear_ie_labels" | _jq -sc '
        '"$BOARD_LIB"'
        .[0] as $i | .[4] as $labels
        | ([.[1].labels.nodes[] | . as $have
            | select(any($i.remove_labels[]; . as $name | $have.name | ieq($name))) | .id]) as $gone
        | ($i | ln_clears) + ($i | ln_fields) + .[2] + .[3]
        + (if ($labels.known | length) > 0 then {addedLabelIds: $labels.known} else {} end)
        + (if ($gone | length) > 0 then {removedLabelIds: $gone} else {} end)')
    if [ "$linear_ie_input" != '{}' ]; then
        LN_STAMP=$(printf '%s' "$linear_ie_input" | linear_update "$linear_ie_id") || return $?
    fi
    linear_ie_missing=$(printf '%s' "$linear_ie_labels" | _jq -c .missing)
    if [ "$linear_ie_missing" != '[]' ]; then
        linear_ie_status=0
        linear_labels_attach "$linear_ie_id" "$linear_ie_missing" || linear_ie_status=$?
        if [ "$linear_ie_status" != 0 ]; then
            # The transport has printed the id already when it gave up on a write.
            [ "$linear_ie_status" != "$BOARD_EXIT_PARTIAL" ] || return "$linear_ie_status"
            # A label made before the failure is a write too: linear_la_ids holds what it made.
            [ "$linear_ie_input" != '{}' ] || [ "$linear_la_ids" != '[]' ] || return "$linear_ie_status"
            board_partial "$linear_ie_id" "the issue changed only in part: a new label could not be added"
        fi
    fi
    if [ "$linear_ie_input$linear_ie_missing" = '{}[]' ]; then
        printf '%s' "$linear_ie_raw" | linear_normalise
        return 0
    fi
    linear_final_view "$linear_ie_id"
}

# Usage: linear_move_to <id> <raw issue> <state id>  — an issue already there is not written to.
linear_move_to() {
    if [ "$(printf '%s' "$2" | _jq -r .state.id)" = "$3" ]; then
        printf '%s' "$2" | linear_normalise
        return 0
    fi
    LN_STAMP=$(_jq -nc --arg s "$3" '{stateId: $s}' | linear_update "$1") || return $?
    linear_final_view "$1"
}

linear_issue_move() {
    linear_im_raw=$(linear_fetch "$1") || return $?
    linear_im_state=$(linear_state "$2") || return $?
    linear_move_to "$1" "$linear_im_raw" "$linear_im_state"
}

# The category an issue is in now, by the rules of [board.statuses].
linear_category_of() {
    printf '%s' "$1" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" ''"$BOARD_LIB"' .state | ln_status($cfg) | .category // ""'
}

linear_issue_close() {
    linear_ic_raw=$(linear_fetch "$1") || return $?
    linear_ic_now=$(linear_category_of "$linear_ic_raw")
    if [ "$linear_ic_now" = "$2" ]; then
        printf '%s' "$linear_ic_raw" | linear_normalise
        return 0
    fi
    linear_ic_state=$(linear_status_in "$2") || return $?
    [ -n "$linear_ic_state" ] || board_usage_die "no status has category $2: declare one in [board.statuses]"
    linear_move_to "$1" "$linear_ic_raw" "$linear_ic_state"
}

linear_issue_reopen() {
    linear_ir_raw=$(linear_fetch "$1") || return $?
    linear_ir_state=''
    if [ -n "$2" ]; then
        linear_ir_state=$(linear_state "$2") || return $?
    else
        case $(linear_category_of "$linear_ir_raw") in
            done | canceled)
                linear_ir_state=$(linear_status_in todo) || return $?
                [ -n "$linear_ir_state" ] || board_usage_die "no status has category todo: declare one in [board.statuses]"
                ;;
        esac
    fi
    if [ -z "$linear_ir_state" ]; then
        printf '%s' "$linear_ir_raw" | linear_normalise
        return 0
    fi
    linear_move_to "$1" "$linear_ir_raw" "$linear_ir_state"
}

linear_issue_delete() {
    linear_fetch "$1" >/dev/null || return $?
    _jq -nc --arg id "$1" '{id: $id}' | linear_query IssueDelete >/dev/null
}

# --- comments ----------------------------------------------------------------------------

linear_comment_page() {
    linear_cp_doc=$(_jq -nc --arg id "$LN_COMMENT_ISSUE" --arg after "$1" \
        '{id: $id, after: (if $after == "" then null else $after end)}' | linear_query CommentList) || return $?
    # A comment with no person behind it came from an integration.
    printf '%s' "$linear_cp_doc" | _jq -c '
        .issue.comments as $page
        | {has_next: $page.pageInfo.hasNextPage, end_cursor: $page.pageInfo.endCursor,
           nodes: [$page.nodes[] | select(.user != null or .externalUser != null)]}'
}

linear_issue_comment_list() {
    linear_fetch "$1" >/dev/null || return $?
    LN_COMMENT_ISSUE=$1
    linear_cl_doc=$(board_paged linear_comment_page all) || return $?
    # On the raw time: the normalised one stops at the second.
    printf '%s' "$linear_cl_doc" | _jq -c ''"$BOARD_LIB"' sort_by(.createdAt) | map(ln_comment)'
}

# Comment ids are global, so <id> would otherwise be taken on trust.
# Usage: linear_comment_on <id> <comment-id>  — exit 4 unless the comment is on that issue.
linear_comment_on() {
    linear_co_raw=$(linear_fetch "$1") || return $?
    linear_co_doc=$(_jq -nc --arg id "$2" '{id: $id}' | linear_query CommentIssue) || return $?
    printf '%s\n%s\n' "$linear_co_raw" "$linear_co_doc" |
        _jq -se '.[0].id == .[1].comment.issue.id' >/dev/null || {
        board_warn "comment $2 is not on issue $1"
        return "$BOARD_EXIT_NOT_FOUND"
    }
}

linear_issue_comment_add() {
    linear_ca_body=$(cat)
    linear_fetch "$1" >/dev/null || return $?
    linear_ca_doc=$(printf '%s' "$linear_ca_body" | _jq -c --arg id "$1" '{input: {issueId: $id, body}}' |
        linear_query CommentCreate) || return $?
    printf '%s' "$linear_ca_doc" | _jq -c ''"$BOARD_LIB"' .commentCreate.comment | ln_comment'
}

linear_issue_comment_edit() {
    linear_ce_body=$(cat)
    linear_comment_on "$1" "$2" || return $?
    linear_ce_doc=$(printf '%s' "$linear_ce_body" | _jq -c --arg id "$2" '{id: $id, input: {body}}' |
        linear_query CommentUpdate) || return $?
    printf '%s' "$linear_ce_doc" | _jq -c ''"$BOARD_LIB"' .commentUpdate.comment | ln_comment'
}

linear_issue_comment_delete() {
    linear_comment_on "$1" "$2" || return $?
    _jq -nc --arg id "$2" '{id: $id}' | linear_query CommentDelete >/dev/null
}

# --- links -------------------------------------------------------------------------------

linear_issue_link_list() {
    linear_ll_doc=$(linear_issue_view "$1") || return $?
    printf '%s' "$linear_ll_doc" | _jq -c .links
}

# Linear gives one answer to linking twice: the same relation. So there is nothing to look up first.
linear_issue_link_add() {
    linear_fetch "$1" >/dev/null || return $?
    linear_fetch "$2" >/dev/null || return $?
    linear_la_from=$1 linear_la_to=$2 linear_la_type=blocks
    case $3 in
        blocked-by) linear_la_from=$2 linear_la_to=$1 ;;
        relates) linear_la_type=related ;;
        duplicates) linear_la_type=duplicate ;;
    esac
    _jq -nc --arg a "$linear_la_from" --arg b "$linear_la_to" --arg t "$linear_la_type" \
        '{issue: $a, other: $b, type: $t}' | linear_query RelationCreate >/dev/null || return $?
    # A relation leaves updatedAt alone, so the link itself is what to wait for.
    linear_settle "$1" 'ln_relation_id($other; $type) != ""' --arg other "$2" --arg type "$3"
}

linear_issue_link_remove() {
    linear_lr_raw=$(linear_fetch "$1") || return $?
    linear_lr_id=$(printf '%s' "$linear_lr_raw" | _jq -r --arg other "$2" --arg type "$3" \
        ''"$BOARD_LIB"' ln_relation_id($other; $type)')
    if [ -z "$linear_lr_id" ]; then
        printf '%s' "$linear_lr_raw" | linear_normalise
        return 0
    fi
    _jq -nc --arg id "$linear_lr_id" '{id: $id}' | linear_query RelationDelete >/dev/null || return $?
    linear_settle "$1" 'ln_relation_id($other; $type) == ""' --arg other "$2" --arg type "$3"
}

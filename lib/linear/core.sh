# shellcheck shell=sh

# Linear adapter: transport, classification and the board-level calls. The board is a team, named by
# [board] project; [board.target] project narrows it to one project of that team.

LN_READY=''
# How long a write waits for a read that has caught up. The lag measured was under 20s.
LN_SETTLE_SECONDS=20

linear_env() {
    # Exit 6 promises the id on stdout, and the transport runs inside $(...) and >/dev/null.
    exec 4>&1
    [ -z "${LN_READY:-}" ] || return 0
    LN_CLI=linear
    LN_TEAM=${BOARD_PROJECT:-}
    LN_PROJECT=$(board_config_get .target.project 2>/dev/null) || LN_PROJECT=''
    LN_WORKSPACE=''
    if [ -n "${BOARD_URL:-}" ]; then
        linear_workspace_of "$BOARD_URL"
    fi
    LN_READY=1
}

# Usage: linear_workspace_of <url>  — sets LN_WORKSPACE from https://linear.app/<workspace>/...
# It goes into argv, and the url may come with a cloned repository: it must not read as a flag.
linear_workspace_of() {
    linear_wo_path=${1#*://}
    case $linear_wo_path in
        */*)
            linear_wo_path=${linear_wo_path#*/}
            LN_WORKSPACE=${linear_wo_path%%/*}
            ;;
    esac
    case $LN_WORKSPACE in
        -* | *[!A-Za-z0-9_-]*) board_usage_die "the workspace in the url is not valid: '$LN_WORKSPACE'" ;;
    esac
}

linear_require_team() {
    [ -n "$LN_TEAM" ] || board_usage_die "[board] project needs the team key, e.g. ENG"
}

# A call failed with no word on whether the board acted. A read just failed; a mutation may have gone
# through, so repeating it blindly could do it twice.
linear_unknown_write() {
    [ -n "${BOARD_WRITE:-}" ] || return "$BOARD_EXIT_ERROR"
    [ -z "${BOARD_WRITE_ID:-}" ] || printf '%s\n' "$BOARD_WRITE_ID" >&4
    board_warn "the write may have gone through. Check before repeating it"
    return "$BOARD_EXIT_PARTIAL"
}

# What a failed call means. A GraphQL error lands on stdout or on stderr depending on where it was
# raised, so both are read; anything else is text from the tool on stderr.
linear_check() {
    if [ "$1" = "$BOARD_EXIT_TIMEOUT" ]; then
        board_timed_out >&4
        return $?
    fi
    linear_ck_doc=$(_jq -Rsc ''"$BOARD_LIB"' ln_failure' <"$BOARD_OUT") || linear_ck_doc=''
    if [ -z "$linear_ck_doc" ] && [ "$1" != 0 ]; then
        linear_ck_doc=$(_jq -Rsc ''"$BOARD_LIB"' ln_failure' <"$BOARD_ERR") || linear_ck_doc=''
    fi
    if [ -z "$linear_ck_doc" ]; then
        [ "$1" != 0 ] || return 0
        linear_ck_line=$(board_err_line)
        board_warn "${linear_ck_line:-linear exited with status $1}"
        # The hint is not on the first line of what the tool prints.
        if grep -q 'linear auth login' "$BOARD_ERR"; then
            return "$BOARD_EXIT_AUTH"
        fi
        # 126 and 127: the tool never started, so nothing was sent.
        case $1 in
            126 | 127) return "$BOARD_EXIT_ERROR" ;;
        esac
        linear_unknown_write
        return $?
    fi
    eval "$(printf '%s' "$linear_ck_doc" | _jq -r '
        @sh "linear_ck_code=\(.code | tostring) linear_ck_raw=\(.raw | tostring) linear_ck_line=\(.message | tostring)",
        @sh "linear_ck_path=\(.path | tostring) linear_ck_user=\(.user | tostring)"')"
    case $linear_ck_raw:$linear_ck_path in
        'Entity not found: Project:project')
            linear_ck_line="project '$LN_PROJECT' was not found: [board.target] project wants the slug, the last part of the project URL"
            ;;
        'Entity not found: Team:team')
            linear_ck_line="team '$LN_TEAM' was not found: [board] project wants the team key"
            ;;
    esac
    board_warn "$linear_ck_line"
    case $linear_ck_code in
        AUTHENTICATION_ERROR | FORBIDDEN) return "$BOARD_EXIT_AUTH" ;;
    esac
    # A missing entity has no code of its own: it shares INPUT_ERROR with every refused input.
    case $linear_ck_raw in
        'Entity not found'* | *' not found') return "$BOARD_EXIT_NOT_FOUND" ;;
    esac
    # userError says Linear turned the request down. Anything else failed on its way through.
    [ "$linear_ck_user" = true ] || {
        linear_unknown_write
        return $?
    }
    return "$BOARD_EXIT_ERROR"
}

# Usage: linear_run <arguments of 'linear api'...>
linear_run() {
    # Several workspaces may be logged in: [board] url names ours. The tool refuses the flag beside
    # LINEAR_API_KEY, which holds one workspace anyway.
    if [ -n "$LN_WORKSPACE" ] && [ -z "${LINEAR_API_KEY:-}" ]; then
        set -- --workspace "$LN_WORKSPACE" "$@"
    fi
    linear_rn_status=0
    board_exec "$LN_CLI" api "$@" 4>&- || linear_rn_status=$?
    linear_check "$linear_rn_status"
}

# Usage: <query text on stdin> | linear_gql <Name>  — prints .data.
linear_gql() {
    linear_run - || return $?
    board_record "$1"
    linear_gq_doc=$(_jq -c '.data // empty
        | if ([.[]? | objects | .success] | index(false)) then "refused" else . end' <"$BOARD_OUT") || linear_gq_doc=''
    case $linear_gq_doc in
        '')
            # Exit 0 with nothing to read must not pass for a write that went through.
            board_warn "linear gave no answer"
            linear_unknown_write
            return $?
            ;;
        '"refused"')
            board_warn "linear turned the change down: it answered success: false"
            return "$BOARD_EXIT_ERROR"
            ;;
    esac
    printf '%s\n' "$linear_gq_doc"
}

# Usage: <values JSON on stdin> | linear_query <Name>
# The name is a file in lib/linear/queries. 'linear api' takes variables in argv only, so each $name
# in the file becomes its value as a literal and the whole request travels on stdin; %name is the
# same for an enum, which takes no quotes, and only ever holds a word from this adapter. One pass:
# text inside a value that looks like $name stays text. A timed-out read is a plain failure even in
# a command that writes: only a mutation has an unknown result.
linear_query() {
    IFS=' ' read -r linear_qr_kind _ <"$BOARD_HOME/lib/linear/queries/$1.graphql"
    BOARD_WRITE=''
    [ "$linear_qr_kind" != mutation ] || BOARD_WRITE=1
    _jq -r --rawfile q "$BOARD_HOME/lib/linear/queries/$1.graphql" \
        --rawfile f "$BOARD_HOME/lib/linear/queries/fragments.graphql" "$BOARD_JQ_GQL"'
        . as $v
        | ($q + (if ($q | test("\\.\\.\\.IssueRow")) then $f else "" end))
        | gsub("(?<sigil>[$%])(?<name>[A-Za-z]+)";
               if .sigil == "%" then $v[.name] else ($v[.name] | gql) end)' |
        linear_gql "$1"
}

# Everything about the team that does not change between calls of one run.
linear_meta() {
    if [ -f "$BOARD_TMP/linear.meta" ]; then
        cat "$BOARD_TMP/linear.meta"
        return 0
    fi
    linear_require_team
    linear_mt_doc=$(_jq -nc --arg team "$LN_TEAM" --arg project "$LN_PROJECT" \
        '{team: $team, project: $project, narrowed: ($project != "")}' | linear_query BoardMeta) || return $?
    case $linear_mt_doc in
        *'"hasNextPage":true'*) board_warn "team $LN_TEAM has more than 250 statuses: only the first 250 are known" ;;
    esac
    printf '%s' "$linear_mt_doc" >"$BOARD_TMP/linear.meta"
    printf '%s' "$linear_mt_doc"
}

# Usage: linear_state_ids <name|id>  — prints the ids it names as a JSON array, in board order.
# Linear lets two statuses share a name when their types differ.
linear_state_ids() {
    linear_sf_meta=$(linear_meta) || return $?
    printf '%s' "$linear_sf_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg n "$1" '
        '"$BOARD_LIB"' [.team.states.nodes | ln_statuses($cfg)[] | select(.id == $n or (.name | ieq($n))) | .id]'
}

# Usage: linear_state <name|id>  — prints the id of one status. A name that is not there, or that
# fits two, is wrong usage: a write must not pick one.
linear_state() {
    linear_st_ids=$(linear_state_ids "$1") || return $?
    linear_st_meta=$(linear_meta) || return $?
    case $linear_st_ids in
        '[]')
            board_usage_die "no status '$1': the team has $(printf '%s' "$linear_st_meta" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" '
                '"$BOARD_LIB"' .team.states.nodes | ln_statuses($cfg) | map(.name) | join(", ")')"
            ;;
        *,*)
            board_usage_die "status '$1' fits more than one, so pass the id: $(printf '%s' "$linear_st_meta" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" --argjson ids "$linear_st_ids" '
                '"$BOARD_LIB"' .team.states.nodes | ln_statuses($cfg)
                | map(select(.id | IN($ids[])) | "\(.name) (\(.category // "no category"), id \(.id))") | join(", ")')"
            ;;
    esac
    printf '%s' "$linear_st_ids" | _jq -r '.[0]'
}

# Usage: linear_status_in <category>  — prints the id of its first status in board order, or nothing.
linear_status_in() {
    linear_si_meta=$(linear_meta) || return $?
    printf '%s' "$linear_si_meta" | _jq -r --argjson cfg "$BOARD_CONFIG_JSON" --arg c "$1" '
        '"$BOARD_LIB"' .team.states.nodes | [ln_statuses($cfg)[] | select(.category == $c) | .id] | first // ""'
}

linear_viewer() {
    linear_vw_doc=$(printf '{}' | linear_query Viewer) || return $?
    printf '%s' "$linear_vw_doc" | _jq -c .viewer
}

linear_auth_status() {
    linear_as_user=$(linear_viewer) || return $?
    printf '%s' "$linear_as_user" | _jq -c --arg host "$BOARD_HOST" \
        '{kind: "linear", host: $host, authenticated: true, user: .displayName}'
}

linear_doctor_checks() {
    linear_dc_meta=$(linear_meta) || return $?
    printf '%s' "$linear_dc_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" '
        '"$BOARD_LIB"'
        {warnings: (if .project then [] else ["no [board.target] project: milestone commands exit 3"] end),
         errors: [.team.states.nodes | ln_statuses($cfg)[] | select(.category == null)
                  | "status \"\(.name)\" has no category: declare it in [board.statuses]"]}'
}

linear_board_list() {
    linear_bl_doc=$(printf '{}' | linear_query Teams) || return $?
    printf '%s' "$linear_bl_doc" | _jq -c --arg host "$BOARD_HOST" '
        '"$BOARD_LIB"'
        .organization.urlKey as $org
        | [.teams.nodes[] | {id: .key, name, url: "https://\($host)/\($org)/team/\(.key)"} | make_board]'
}

linear_board_view() {
    linear_bv_meta=$(linear_meta) || return $?
    printf '%s' "$linear_bv_meta" | _jq -c --argjson cfg "$BOARD_CONFIG_JSON" --arg url "${BOARD_URL%/}" '
        '"$BOARD_LIB"'
        (.team.states.nodes | ln_statuses($cfg)) as $s
        | {id: .team.key, name: (.project.name // .team.name), kind: "linear",
           url: (.project.url // "\($url)/team/\(.team.key)"),
           columns: ($s | map({name, statuses: [.name]})), statuses: $s}'
}

# A query can hide a mutation in argv or on stdin, and only the text tells. Reading too much into a
# word costs a warning; reading too little would call a write that timed out a plain failure.
linear_api_call() {
    BOARD_WRITE=''
    linear_ac_stdin=''
    for linear_ac_arg in "$@"; do
        case $linear_ac_arg in
            -) linear_ac_stdin=1 ;;
            *mutation*) BOARD_WRITE=1 ;;
        esac
    done
    if [ -n "$linear_ac_stdin" ]; then
        cat >"$BOARD_TMP/api.in"
        if grep -q mutation "$BOARD_TMP/api.in"; then
            BOARD_WRITE=1
        fi
        linear_run "$@" <"$BOARD_TMP/api.in" || return $?
    else
        linear_run "$@" || return $?
    fi
    cat "$BOARD_OUT"
}

# Usage: linear_init_discover <url> <repo>  — the repo means nothing here.
linear_init_discover() {
    linear_workspace_of "$1"
    linear_id_rest=${1#*://}
    linear_id_host=${linear_id_rest%%/*}
    linear_id_rest=${linear_id_rest#*/}
    linear_id_rest=${linear_id_rest#"$LN_WORKSPACE"}
    linear_id_rest=${linear_id_rest#/}
    linear_id_rest=${linear_id_rest%%\?*}
    case $linear_id_rest in
        project/*)
            linear_id_slug=${linear_id_rest#project/}
            linear_id_slug=${linear_id_slug%%/*}
            # The URL slug is <name>-<slugId>, and the name may hold dashes.
            LN_PROJECT=${linear_id_slug##*-}
            linear_id_doc=$(_jq -nc --arg p "$LN_PROJECT" '{project: $p}' | linear_query ProjectTeams) || return $?
            LN_TEAM=$(printf '%s' "$linear_id_doc" | _jq -r '.project.teams.nodes | if length == 1 then .[0].key else "" end')
            if [ -z "$LN_TEAM" ]; then
                board_usage_die "project $LN_PROJECT spans several teams: pass the URL of one team, and set [board.target] project by hand"
            fi
            ;;
        team/*)
            LN_TEAM=${linear_id_rest#team/}
            LN_TEAM=${LN_TEAM%%/*}
            LN_PROJECT=''
            ;;
        *)
            board_usage_die "--url must be a project or team URL: https://$linear_id_host/<workspace>/project/<slug> or .../team/<key>"
            ;;
    esac
    linear_id_meta=$(linear_meta) || return $?
    printf '%s' "$linear_id_meta" | _jq -c --arg url "https://$linear_id_host/$LN_WORKSPACE" --arg project "$LN_PROJECT" '
        '"$BOARD_LIB"'
        (.team.states.nodes | sort_by((.type | ln_order), .position)) as $states
        | {board: {kind: "linear", cli: "linear", url: $url, project: .team.key, issue_uri: "/issue/{ticket}"},
           target: (if $project == "" then {} else {project: $project} end),
           statuses: ([$states[] | {key: .name, value: (.type | ln_category)} | select(.value)] | from_entries),
           unplaced: [$states[] | select(.type | ln_category | not) | .name]}'
}

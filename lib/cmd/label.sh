# shellcheck shell=sh

LABEL_SHAPE='{id, name, color, description}
  color is six hex digits with no #, or null. id is null where labels are plain text.'

help_label() {
    cat <<'EOF'
board label - labels of the board

COMMANDS
  list      List the labels
  create    Create a label
  edit      Change a label
  delete    Delete a label
  sync      Create the labels declared in [board.labels]

To put a label on an issue, use 'board issue edit --add-label'.

Run 'board label <command> --help' for details.
EOF
}

help_label_list() {
    cat <<EOF
NAME
  board label list - list the labels

USAGE
  board label list

DESCRIPTION
  Lists the labels of the board.

OUTPUT
  Text: one name per line.
  JSON: array of $LABEL_SHAPE

PLATFORM NOTES
  GitHub: the labels of the repository of [board] url.
  Jira: every label used on the site, as plain text. On Data Center this is not supported.
  GitLab: status labels are listed too.

EXAMPLES
  board label list
  board label list --jq '.[].name'
EOF
}

cmd_label_list() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_doc=$(board_call label_list) || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output text_labels
}

help_label_create() {
    cat <<EOF
NAME
  board label create - create a label

USAGE
  board label create <name> [--color <hex>] [--description <text>]

DESCRIPTION
  Creates a label. Creating one that exists succeeds and leaves it as it is.

ARGUMENTS
  <name>                  Name of the label

FLAGS
  --color <hex>           Six hex digits, e.g. d73a4a
  -d, --description <text>  Description

OUTPUT
  Text: the name.
  JSON: $LABEL_SHAPE

PLATFORM NOTES
  Jira: not supported. A label exists once an issue carries it.
  Linear: --color needs a # on the board's side; board adds it.

EXAMPLES
  board label create bug --color d73a4a --description "Something is broken"
EOF
}

# Sets opt_color and opt_description, and arg_name unless it is already given.
label_flags() {
    opt_color='' opt_description='' opt_description_set=''
    while [ $# -gt 0 ]; do
        case $1 in
            --color)
                board_arg "$@"
                case $2 in
                    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) opt_color=$2 ;;
                    *) board_usage_die "--color must be six hex digits, got '$2'" ;;
                esac
                shift 2
                ;;
            -d | --description) board_arg "$@"; opt_description=$2; opt_description_set=1; shift 2 ;;
            -n | --name) board_arg "$@"; opt_new_name=$2; shift 2 ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_name" ] || board_unexpected "$1"
                arg_name=$1
                shift
                ;;
        esac
    done
    [ -n "$arg_name" ] || board_usage_die "<name> is required"
}

label_intent() {
    _jq -nc --arg name "$arg_name" --arg new_name "$opt_new_name" --arg color "$opt_color" \
        --arg description "$opt_description" --arg description_set "$opt_description_set" '
        include "jq/common";
        {name: $name, new_name: ($new_name | nullify), color: ($color | nullify),
         description: (if $description_set == "" then null else $description end)}'
}

cmd_label_create() {
    arg_name='' opt_new_name=''
    label_flags "$@"
    [ -z "$opt_new_name" ] || board_usage_die "--name is for 'board label edit'"
    label_intent >"$BOARD_TMP/intent"
    board_doc=$(board_call label_create <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output .name
}

help_label_edit() {
    cat <<EOF
NAME
  board label edit - change a label

USAGE
  board label edit <name> [--name <new-name>] [--color <hex>] [--description <text>]

DESCRIPTION
  Changes a label. Issues keep it under its new name.

ARGUMENTS
  <name>                  Current name

FLAGS
  -n, --name <new-name>   New name
  --color <hex>           Six hex digits, e.g. d73a4a
  -d, --description <text>  New description

OUTPUT
  Text: the name.
  JSON: $LABEL_SHAPE

PLATFORM NOTES
  Jira: not supported. A label is plain text on each issue.

EXAMPLES
  board label edit bug --name defect
EOF
}

cmd_label_edit() {
    arg_name='' opt_new_name=''
    label_flags "$@"
    [ -n "$opt_new_name$opt_color$opt_description_set" ] || board_usage_die "nothing to change: pass at least one flag"
    label_intent >"$BOARD_TMP/intent"
    board_doc=$(board_call label_edit <"$BOARD_TMP/intent") || board_fail "$?" "$board_doc"
    printf '%s\n' "$board_doc" | board_output .name
}

help_label_delete() {
    cat <<'EOF'
NAME
  board label delete - delete a label

USAGE
  board label delete <name> --yes

DESCRIPTION
  Deletes a label from the board and from every issue carrying it. Deleting needs --yes, so a slip
  cannot do it.

ARGUMENTS
  <name>       Name of the label

FLAGS
  -y, --yes    Really delete it

OUTPUT
  Text: nothing.
  JSON: {name, deleted}

PLATFORM NOTES
  Jira: not supported. A label is plain text on each issue.

EXAMPLES
  board label delete old-label --yes
EOF
}

cmd_label_delete() {
    arg_name='' opt_yes=''
    while [ $# -gt 0 ]; do
        case $1 in
            -y | --yes) opt_yes=1; shift ;;
            -*) board_unknown_flag "$1" ;;
            *)
                [ -z "$arg_name" ] || board_unexpected "$1"
                arg_name=$1
                shift
                ;;
        esac
    done
    [ -n "$arg_name" ] || board_usage_die "<name> is required"
    [ -n "$opt_yes" ] || board_usage_die "deleting needs --yes"
    board_call label_delete "$arg_name" || exit $?
    if board_json_mode; then
        _jq -n --arg name "$arg_name" '{name: $name, deleted: true}' | board_output .
    fi
}

help_label_sync() {
    cat <<'EOF'
NAME
  board label sync - create the labels declared in [board.labels]

USAGE
  board label sync

DESCRIPTION
  Creates each label of [board.labels] that the board lacks, with its value as the description. A
  label that exists is left alone, so running this twice changes nothing. Nothing is deleted.

OUTPUT
  Text: the names created, one per line.
  JSON: {created[], existing[]}

PLATFORM NOTES
  Jira: not supported. A label exists once an issue carries it.

EXAMPLES
  board label sync
  board label sync --jq .created
EOF
}

cmd_label_sync() {
    [ $# -eq 0 ] || board_unexpected "$1"
    board_config_load
    board_ls_have=$(board_call label_list) || exit $?
    board_ls_wanted=$(printf '%s\n%s\n' "$BOARD_CONFIG_JSON" "$board_ls_have" | _jq -sc '
        include "jq/common";
        (.[1] | map(.name)) as $have
        | (.[0].labels // {}) | to_entries
        | map(select(.key as $k | $have | any(ieq($k)) | not))
        | map({name: .key, new_name: null, color: null, description: (.value | tostring)})')
    board_ls_created=$(printf '%s' "$board_ls_wanted" | _jq -r '.[] | @base64') || exit 1
    for board_ls_item in $board_ls_created; do
        printf '%s' "$board_ls_item" | _jq -Rr '@base64d' >"$BOARD_TMP/intent"
        board_call label_create <"$BOARD_TMP/intent" >/dev/null || exit $?
    done
    printf '%s\n%s\n' "$BOARD_CONFIG_JSON" "$board_ls_wanted" | _jq -sc '
        (.[1] | map(.name)) as $created
        | {created: $created, existing: ((.[0].labels // {}) | keys | map(select(. as $k | $created | index($k) | not)))}' |
        board_output '.created[]'
}

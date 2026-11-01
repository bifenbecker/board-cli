# shellcheck shell=sh

# What the commands refuse before any adapter runs. Each case must stop at exit 2, so no case
# needs a fake CLI: reaching an adapter would be exit 3 at this stage, or a fake with no answer.

cmd_board() {
    t_workflow <<'EOF'
[board]
kind = "github"
url  = "https://github.com/a/b"
EOF
}

test_create_needs_a_title() {
    cmd_board
    t_run board issue create --body x
    t_status 2
    t_contains "$T_ERR" --title
}

test_edit_needs_a_change() {
    cmd_board
    t_run board issue edit 12
    t_status 2
    t_contains "$T_ERR" 'nothing to change'
}

test_edit_refuses_an_empty_title() {
    cmd_board
    t_run board issue edit 12 --title ''
    t_status 2
}

test_delete_needs_yes() {
    cmd_board
    t_run board issue delete 12
    t_status 2
    t_contains "$T_ERR" --yes
}

test_list_rejects_a_bad_limit() {
    cmd_board
    t_run board issue list --limit 0
    t_status 2
}

test_list_rejects_a_bad_category() {
    cmd_board
    t_run board issue list --category later
    t_status 2
}

test_due_date_must_be_a_date() {
    cmd_board
    t_run board issue create --title t --due tomorrow
    t_status 2
}

test_id_cannot_be_a_flag() {
    cmd_board
    t_run board issue move -x done
    t_status 2
}

test_link_needs_a_type() {
    cmd_board
    t_run board issue link add 1 2
    t_status 2
}

test_link_rejects_an_unknown_type() {
    cmd_board
    t_run board issue link add 1 2 --type causes
    t_status 2
}

test_label_color_must_be_hex() {
    cmd_board
    t_run board label create x --color red
    t_status 2
}

test_status_add_needs_a_category() {
    cmd_board
    t_run board status add Review
    t_status 2
}

test_clear_takes_known_fields_only() {
    cmd_board
    t_run board issue edit 1 --clear title
    t_status 2
}

test_body_file_must_exist() {
    cmd_board
    t_run board issue create --title t --body-file /no/such/file
    t_status 1
}

test_help_exists_for_every_listed_command() {
    t_run board issue --help
    t_status 0
    t_contains "$T_OUT" COMMANDS
    t_run board issue comment add --help
    t_status 0
    t_contains "$T_OUT" 'PLATFORM NOTES'
}

test_init_needs_a_url() {
    t_run board init
    t_status 2
}

test_init_cannot_place_an_unknown_host() {
    t_run board init --url https://tracker.example.com/x
    t_status 2
    t_contains "$T_ERR" --kind
}

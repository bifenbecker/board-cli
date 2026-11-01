#!/bin/sh
# One scenario, run against the real test boards. It creates issues and deletes them again, and it
# is the same for every board: that is the point of the common interface. A step a board cannot do
# must exit 3; anything else counts as a failure.
#
#   sh tests/live/run.sh [<kind>...]      default: all four
#   RECORD=1 sh tests/live/run.sh <kind>  also save the board's answers as fixtures
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
[ $# -gt 0 ] || set -- github gitlab linear jira
BOARD_JIRA_HOSTS=work-40585442.atlassian.net
export BOARD_JIRA_HOSTS

passed=0
failed=0
stamp=$(date +%H%M%S)
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

board() {
    sh "$root/bin/board" "$@"
}

report() {
    if [ "$1" = ok ]; then
        passed=$((passed + 1))
        printf '  ok    %s\n' "$2"
    else
        failed=$((failed + 1))
        printf '  FAIL  %s: %s\n' "$2" "$3"
    fi
}

# Usage: step <name> <jq test|-> <board args...>
# Runs the command; passes on exit 0 when the jq test holds for its stdout.
step() {
    step_name=$1
    step_test=$2
    shift 2
    step_status=0
    board "$@" >"$work/out" 2>"$work/err" || step_status=$?
    if [ "$step_status" != 0 ]; then
        report fail "$step_name" "exit $step_status: $(sed -n 1p "$work/err")"
        return 1
    fi
    if [ "$step_test" != - ] && ! jq -e "$step_test" <"$work/out" >/dev/null 2>"$work/err"; then
        report fail "$step_name" "test $step_test failed on: $(cut -c1-200 "$work/out" | sed -n 1p)"
        return 1
    fi
    report ok "$step_name"
}

# The same, for a step this board may not support: exit 3 is an answer.
maybe() {
    maybe_name=$1
    maybe_test=$2
    shift 2
    maybe_status=0
    board "$@" >"$work/out" 2>"$work/err" || maybe_status=$?
    case $maybe_status in
        0)
            if [ "$maybe_test" != - ] && ! jq -e "$maybe_test" <"$work/out" >/dev/null 2>&1; then
                report fail "$maybe_name" "test $maybe_test failed on: $(cut -c1-200 "$work/out" | sed -n 1p)"
                return 1
            fi
            report ok "$maybe_name"
            ;;
        3)
            passed=$((passed + 1))
            printf '  n/a   %s: %s\n' "$maybe_name" "$(sed -n 1p "$work/err")"
            return 1
            ;;
        *)
            report fail "$maybe_name" "exit $maybe_status: $(sed -n 1p "$work/err")"
            return 1
            ;;
    esac
}

# Usage: expect_exit <code> <name> <board args...>
expect_exit() {
    ee_code=$1
    ee_name=$2
    shift 2
    ee_status=0
    board "$@" >"$work/out" 2>"$work/err" || ee_status=$?
    if [ "$ee_status" = "$ee_code" ]; then
        report ok "$ee_name"
    else
        report fail "$ee_name" "wanted exit $ee_code, got $ee_status: $(sed -n 1p "$work/err")"
    fi
}

# Usage: field <board args...>  — stdout of a --jq call, with its exit status.
field() {
    board "$@" 2>/dev/null
}

scenario() {
    kind=$1
    printf '%s\n' "$kind"
    WORKFLOW_FILE=$root/tests/live/$kind.toml
    export WORKFLOW_FILE
    created=''
    label=zz-live-$stamp
    category=''

    step doctor '.ok' doctor --json || return
    step capabilities '.supported | length > 0' capabilities --json
    step 'board view' '.statuses | length > 0' view --json
    step 'board list' 'length > 0' list --json
    step 'status list' 'length > 0' status list --json
    step 'member list' 'length > 0' member list --json

    # A title and body with Cyrillic, a slash, quotes and a line break cross every layer.
    title="live $stamp: кириллица /start \"q\""
    printf 'line 1\nстрока 2 /start\n' >"$work/body"
    a=$(field issue create --title "$title" --body-file "$work/body" --jq .id) || {
        report fail 'create' "no id: $a"
        return
    }
    created="$a"
    report ok "create $a"
    step 'title kept' ".title | contains(\"кириллица /start\")" issue view "$a" --json
    step 'body kept' '.description | contains("строка 2 /start")' issue view "$a" --json
    step 'has a status' '.status.name != null' issue view "$a" --json

    b=$(field issue create --title "live $stamp b" --jq .id) || b=''
    [ -z "$b" ] || created="$created $b"

    step 'list has it' "map(.id) | index(\"$a\") != null" issue list --category all --limit all --json
    step 'search finds it' "map(.id) | index(\"$a\") != null" issue list --category all --search "live $stamp" --json
    step 'limit one' 'length == 1' issue list --category all --limit 1 --json

    step 'edit title' '.title == "edited"' issue edit "$a" --title edited --json
    step 'edit body' '.description | contains("second")' issue edit "$a" --body second --json
    step 'add label' "(.labels | index(\"$label\")) != null" issue edit "$a" --add-label "$label" --json
    step 'remove label' "(.labels | index(\"$label\")) == null" issue edit "$a" --remove-label "$label" --json
    maybe 'due date' '.due_date == "2027-01-15"' issue edit "$a" --due 2027-01-15 --json
    maybe 'clear due' '.due_date == null' issue edit "$a" --clear due --json
    maybe 'priority' '.priority == "high"' issue edit "$a" --priority high --json
    me=$(field member list --jq '.[0].id')
    step 'assign' "(.assignees | map(.id) | index(\"$me\")) != null" issue edit "$a" --add-assignee "$me" --json
    step 'my issues' "map(.id) | index(\"$a\") != null" issue list --assignee @me --category all --json
    step 'unassign' '.assignees == []' issue edit "$a" --remove-assignee "$me" --json

    if comment=$(field issue comment add "$a" --body "comment строка /start" --jq .id); then
        report ok "comment add $comment"
        step 'comment list' 'length == 1' issue comment list "$a" --json
        step 'comment edit' '.body | contains("edited")' issue comment edit "$a" "$comment" --body "edited" --json
        step 'view with comments' '.comments | length == 1' issue view "$a" --comments --json
    else
        report fail 'comment add' 'no id'
    fi

    if [ -n "$b" ]; then
        maybe 'parent' ".parent == \"$a\"" issue edit "$b" --parent "$a" --json
        maybe 'subtasks' ".subtasks | index(\"$b\") != null" issue view "$a" --json
        maybe 'clear parent' '.parent == null' issue edit "$b" --clear parent --json
        maybe 'link blocks' ".links | map(.id) | index(\"$b\") != null" issue link add "$a" "$b" --type blocks --json &&
            step 'link list' 'length > 0' issue link list "$b" --json &&
            step 'link remove' ".links | map(.id) | index(\"$b\") == null" issue link remove "$a" "$b" --type blocks --json
        maybe 'link relates' ".links | map(.id) | index(\"$b\") != null" issue link add "$a" "$b" --type relates --json &&
            step 'link relates remove' ".links | map(.id) | index(\"$b\") == null" issue link remove "$a" "$b" --type relates --json
    fi

    for category in in_progress done todo; do
        status=$(field status list --jq "[.[] | select(.category == \"$category\") | .name] | first // \"\"")
        [ -n "$status" ] || continue
        step "move to $status" ".status.category == \"$category\"" issue move "$a" "$status" --json
    done
    step 'close' '.status.category == "done"' issue close "$a" --json
    step 'reopen' '.status.category == "todo"' issue reopen "$a" --json

    if [ "${RECORD:-}" = 1 ]; then
        snapshot "$a"
    fi

    expect_exit 4 'view a missing issue' issue view "$(missing_id)"
    expect_exit 2 'move to a status that is not there' issue move "$a" no-such-status

    if m=$(field milestone create --name "live $stamp" --due 2027-02-01 --jq .id); then
        report ok "milestone create $m"
        step 'milestone view' ".id == \"$m\"" milestone view "$m" --json
        step 'milestone edit' '.description == "d"' milestone edit "$m" --description d --json
        step 'milestone list' "map(.id) | index(\"$m\") != null" milestone list --state all --json
        step 'issue in milestone' ".milestone == \"live $stamp\"" issue edit "$a" --milestone "live $stamp" --json
        step 'clear milestone' '.milestone == null' issue edit "$a" --clear milestone --json
        step 'milestone delete' - milestone delete "$m" --yes
    else
        printf '  n/a   milestone create\n'
    fi

    maybe 'label create' ".name == \"$label\"" label create "$label" --color 112233 --description live --json &&
        step 'label twice' ".name == \"$label\"" label create "$label" --json &&
        step 'label edit' ".name == \"$label-x\"" label edit "$label" --name "$label-x" --json &&
        step 'label delete' - label delete "$label-x" --yes
    maybe 'status add' '.name == "Zz Live"' status add "Zz Live" --category in_progress --json &&
        step 'status rename' '.name == "Zz Live 2"' status rename "Zz Live" "Zz Live 2" --json &&
        step 'status delete' - status delete "Zz Live 2" --yes
    maybe 'sprint list' 'type == "array"' sprint list --json

    for issue in $created; do
        step "delete $issue" - issue delete "$issue" --yes
    done
    created=''
}

missing_id() {
    case $kind in
        linear) printf '3KD-99999' ;;
        jira) printf 'KAN-99999' ;;
        *) printf '999999' ;;
    esac
}

# Saves the board's answers for the contract tests, from the reads an agent makes most.
snapshot() {
    case $kind in
        github) dir=gh ;;
        gitlab) dir=glab ;;
        linear) dir=linear ;;
        jira) dir=curl ;;
    esac
    BOARD_RECORD=$root/tests/fixtures/$dir
    export BOARD_RECORD
    {
        board issue view "$1" --json
        board issue list --category all --json
        board issue comment list "$1" --json
        board status list --json
        board label list --json
        board member list --json
        board milestone list --state all --json
        board view --json
    } >/dev/null 2>&1
    unset BOARD_RECORD
}

for kind_arg in "$@"; do
    scenario "$kind_arg"
    for issue in ${created:-}; do
        board issue delete "$issue" --yes >/dev/null 2>&1
    done
done

printf '%s passed, %s failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]

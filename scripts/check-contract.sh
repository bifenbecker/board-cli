#!/bin/sh
# Fails when the commands and the adapters disagree. lib/contract.txt names every adapter call;
# each one must be called by a command, and on each board it must either exist as a function or
# be listed in lib/<kind>/unsupported.txt with a reason. Nothing else stops one adapter drifting
# from the other three.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
bad=0
kinds='linear jira github gitlab'

complain() {
    printf 'contract: %s\n' "$*" >&2
    bad=1
}

contract=$(awk '{ print $1 }' lib/contract.txt | sort)
called=$(grep -ho 'board_call [a-z0-9_]*' lib/cmd/*.sh | awk '{ print $2 }' | sort -u)

for name in $called; do
    printf '%s\n' "$contract" | grep -qx "$name" || complain "lib/cmd calls $name, which lib/contract.txt does not list"
done
for name in $contract; do
    printf '%s\n' "$called" | grep -qx "$name" || complain "lib/contract.txt lists $name, which no command calls"
done

for kind in $kinds; do
    [ -d "lib/$kind" ] || {
        complain "no adapter lib/$kind"
        continue
    }
    defined=$(grep -ho "^${kind}_[a-z0-9_]*()" "lib/$kind"/*.sh 2>/dev/null | sed "s/^${kind}_//; s/()$//" | sort -u)
    unsupported=''
    if [ -f "lib/$kind/unsupported.txt" ]; then
        unsupported=$(awk 'NF { print $1 }' "lib/$kind/unsupported.txt" | sort -u)
        awk -v f="lib/$kind/unsupported.txt" 'NF == 1 { printf "contract: %s: %s has no reason\n", f, $1 > "/dev/stderr"; bad = 1 } END { exit bad }' \
            "lib/$kind/unsupported.txt" || bad=1
    fi
    for name in $contract; do
        has_fn=0
        is_out=0
        printf '%s\n' "$defined" | grep -qx "$name" && has_fn=1
        printf '%s\n' "$unsupported" | grep -qx "$name" && is_out=1
        if [ "$has_fn" = 0 ] && [ "$is_out" = 0 ]; then
            complain "$kind has neither ${kind}_$name nor an entry in unsupported.txt"
        fi
        if [ "$has_fn" = 1 ] && [ "$is_out" = 1 ]; then
            complain "$kind defines ${kind}_$name and lists it as unsupported"
        fi
    done
done

# Board names belong in help text only. Heredocs are dropped before the search.
leaks=$(awk '
    FNR == 1 { heredoc = "" }
    heredoc != "" { if ($0 == heredoc) heredoc = ""; next }
    /<<.?EOF.?$/ { heredoc = "EOF"; next }
    /^[ \t]*#/ { next }
    /(linear|jira|github|gitlab|BOARD_KIND)/ { printf "%s:%d: %s\n", FILENAME, FNR, $0 }
' lib/cmd/*.sh)
if [ -n "$leaks" ]; then
    printf '%s\n' "$leaks" >&2
    complain "lib/cmd names a board outside help; that belongs in lib/<kind>/"
fi

[ "$bad" = 0 ] && printf 'contract ok: %d calls, %d boards\n' "$(printf '%s\n' "$contract" | wc -l)" "$(printf '%s\n' "$kinds" | wc -w)"
exit "$bad"

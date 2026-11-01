#!/bin/sh
# Fails when a command's help lacks a required section or a well-formed NAME line: agents learn
# board from --help alone, and that help is written by hand for every command.
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BOARD_HOME=$root
for lib in util exec gql config json args help provider dispatch; do
    . "$root/lib/core/$lib.sh"
done
for file in "$root"/lib/cmd/*.sh; do
    . "$file"
done

# One stream through one awk: spawning tools per command is slow on Windows.
# shellcheck disable=SC2013 # function names hold no spaces
for node in $(grep -ho '^cmd_[a-z0-9_]*()' "$root"/lib/cmd/*.sh | sed 's/^cmd_//; s/()$//' | sort); do
    printf '@@ %s\n' "$node"
    "help_$node"
done | awk -v sections="$BOARD_HELP_SECTIONS" '
    function check() {
        if (node == "") return
        if (!named) { printf "help_%s: NAME line is missing or not \"  board <path> - <summary>\"\n", node > "/dev/stderr"; bad = 1 }
        for (i = 1; i <= n; i++) if (!(want[i] in seen)) {
            printf "help_%s: no %s section\n", node, want[i] > "/dev/stderr"; bad = 1
        }
        count++
    }
    BEGIN { n = split(sections, want, " ") }
    /^@@ / { check(); node = $2; named = 0; split("", seen); prev = ""; next }
    { seen[$0] = 1 }
    prev == "NAME" && /^  board .* - / { named = 1 }
    { prev = $0 }
    END { check(); if (!bad) printf "help ok: %d commands\n", count; exit bad }
'

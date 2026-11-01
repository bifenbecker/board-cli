#!/bin/sh
# Runs tests/unit and tests/contract, or the files named, with the fake provider CLIs first on
# PATH so no test reaches a real board. Exit 0 only when every case passed.
set -u

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BOARD_TEST_ROOT=$root
FAKE_FIXTURES=$root/tests/fixtures
PATH=$root/tests/fake:$PATH
export BOARD_TEST_ROOT FAKE_FIXTURES PATH
unset WORKFLOW_FILE BOARD_RECORD

[ $# -gt 0 ] || set -- "$root"/tests/unit/*.sh "$root"/tests/contract/*.sh

failed=0
passed=0
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

for file in "$@"; do
    [ -f "$file" ] || continue
    cases=$(sed -n 's/^\(test_[a-z0-9_]*\)().*/\1/p' "$file")
    basename "$file"
    for name in $cases; do
        T_TMP=$work/$name
        mkdir -p "$T_TMP"
        export T_TMP
        if (
            . "$root/tests/lib/assert.sh"
            . "$file"
            FAKE_LOG=$T_TMP/fake.log
            export FAKE_LOG
            cd "$T_TMP" || exit 1
            "$name"
            exit "$TEST_FAILED"
        ) 2>"$T_TMP/report"; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            echo "  FAIL $name"
            cat "$T_TMP/report"
        fi
    done
done

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]

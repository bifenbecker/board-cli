#!/bin/sh
# Runs tests/unit and tests/contract, or the files named, with the fake provider CLIs first on
# PATH so no test reaches a real board. Exit 0 only when every case passed.
set -u

# -P: under just on Windows a logical pwd is C:/..., whose colon cuts PATH before the fakes.
root=$(CDPATH='' cd -P -- "$(dirname -- "$0")/.." && pwd -P)
BOARD_TEST_ROOT=$root
FAKE_FIXTURES=$root/tests/fixtures
PATH=$root/tests/fake:$PATH
export BOARD_TEST_ROOT FAKE_FIXTURES PATH
unset WORKFLOW_FILE BOARD_RECORD BOARD_HOME

[ $# -gt 0 ] || set -- "$root"/tests/unit/*.sh "$root"/tests/contract/*.sh

failed=0
passed=0
work=$(mktemp -d) || exit 1
trap 'rm -rf "$work"' EXIT

for file in "$@"; do
    if [ ! -f "$file" ]; then
        echo "no such test file: $file"
        failed=$((failed + 1))
        continue
    fi
    cases=$(sed -n 's/^\(test_[a-z0-9_]*\)[ ]*().*/\1/p' "$file")
    basename "$file"
    for name in $cases; do
        T_TMP=$work/$(basename "$file" .sh).$name
        mkdir -p "$T_TMP"
        export T_TMP
        if (
            . "$root/tests/lib/assert.sh"
            . "$file"
            FAKE_LOG=$T_TMP/fake.log
            export FAKE_LOG
            cd "$T_TMP" || exit 1
            "$name" || t_fail "the test returned $?"
            # Reached only when the test ran to its end: an exit inside it leaves no mark.
            [ "$TEST_FAILED" != 0 ] || : >"$T_TMP/finished"
            exit "$TEST_FAILED"
        ) 2>"$T_TMP/report" && [ -f "$T_TMP/finished" ]; then
            passed=$((passed + 1))
        else
            failed=$((failed + 1))
            echo "  FAIL $name"
            cat "$T_TMP/report"
        fi
    done
done

echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ] && [ "$passed" -gt 0 ]

#!/bin/sh
# Runs the checks workflow.toml assigns to a stage: run-checks.sh static | pre_push
#
# Each name in [checks] is a recipe of checks.runner (just, make, npm run...), so a check is
# defined once, in the runner's own file, and this one only decides which a gate owes.
set -u

cd -- "$(dirname -- "$0")/.." || exit 1

stage=${1:-}
[ -n "$stage" ] || {
    echo "usage: run-checks.sh <stage>   (a key under [checks] in workflow.toml)" >&2
    exit 2
}

checks=$(sh scripts/workflow.sh get "checks.$stage") || exit 1
runner=$(sh scripts/workflow.sh get checks.runner just)
if [ -z "$(printf '%s' "$checks" | tr -d '[:space:]')" ]; then
    echo "run-checks.sh: [checks].$stage is empty, nothing to run"
    exit 0
fi

failed=
while IFS= read -r check; do
    [ -n "$check" ] || continue
    echo "==> $check"
    # shellcheck disable=SC2086 # the runner may be a command with arguments, e.g. "npm run"
    $runner "$check" || failed="$failed $check"
done <<EOF2
$checks
EOF2

if [ -n "$failed" ]; then
    echo
    echo "Failed:$failed"
    exit 1
fi

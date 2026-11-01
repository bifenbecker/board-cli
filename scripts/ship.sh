#!/bin/sh
# Takes the current branch to a draft request: gate, review, push, compose the request text, open
# it. Judgement-heavy steps are skills, invoked here by name: titles, descriptions and what counts
# as a finding stay in project docs and the skills that read them.
#
# The review is the shallow one, before the push: it prints and blocks, it does not publish.
#
# Usage:
#   sh scripts/ship.sh [BASE=<branch>] [DRY_RUN=1] [NO_REVIEW=1] [DRAFT=0]
#
#   BASE       base branch for the gate; the request itself targets what the git process
#              prescribes, as reported by the compose-request skill
#   DRY_RUN    gate only: check the branch, then stop. Nothing is reviewed, pushed or opened
#   NO_REVIEW  gate, push and open the request, but do not review it
#   DRAFT=0    open a regular request instead of a draft
#
# Requires git 2.38+ for `merge-tree --write-tree`, which reports conflicts through its exit code.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

config() {
    sh "$ROOT/scripts/workflow.sh" get "$@"
}

DEFAULT_BASE=$(config git.default_branch)
DELETE_BRANCH=$(config git.delete_branch false)
MAX_DIFF_LINES=$(config worktree.max_diff_lines)
REVIEW_MODEL=$(config review.shallow.model)
DIFF_PATHS=$(config worktree.diff_paths)
# Titles and descriptions are written from the diff; the smallest model got the facts wrong there.
COMPOSE_MODEL=$(config ship.compose_model sonnet)
CONFLICT_PATHS=$(config ship.conflict_paths '')
FORGE_CMD=$(config tools.forge forge)
REQUEST_DIR=.tmp/request
REVIEW_DIR=.tmp/review
REQUEST_SCHEMA_VERSION=1
REVIEW_SCHEMA_VERSION=2

forge() {
    # shellcheck disable=SC2086 # tools.forge may be a command with arguments, e.g. "sh bin/forge"
    $FORGE_CMD "$@"
}

# The headless agents may read anything but run only read-only git and write only their output.
# The script fetches before calling them, so they need no network.
READ_ONLY_GIT='Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git rev-parse:*),Bash(git status:*)'
# Flags that would let a read-only git command write files or run programs.
DENIED_GIT='Bash(git * --output*),Bash(git * -o *),Bash(git * --ext-diff*),Bash(git * --textconv*),Bash(git * --upload-pack*),Bash(git fetch:*)'
REVIEW_TOOLS="Read,Glob,Grep,Skill,$READ_ONLY_GIT,Bash(sh scripts/workflow.sh:*),Bash(mkdir -p .tmp/review),Edit(.tmp/review/**)"
COMPOSE_TOOLS="Read,Glob,Grep,Skill,$READ_ONLY_GIT,Bash(sh scripts/workflow.sh:*),Bash($FORGE_CMD request template:*),Bash(mkdir -p .tmp/request),Edit(.tmp/request/**)"

BASE=
DRY_RUN=
NO_REVIEW=
DRAFT=

usage() {
    sed -n '/^# Usage:/,/^$/{ s/^# \{0,1\}//; p; }' "$0"
}

for arg in "$@"; do
    case $arg in
        help | -h | --help) usage; exit 0 ;;
        BASE=*) BASE=${arg#BASE=} ;;
        DRY_RUN=*) DRY_RUN=${arg#DRY_RUN=} ;;
        NO_REVIEW=*) NO_REVIEW=${arg#NO_REVIEW=} ;;
        DRAFT=*) DRAFT=${arg#DRAFT=} ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 2
            ;;
    esac
done

BASE=${BASE:-$DEFAULT_BASE}
# Empty means "not passed": just forwards variables as given, and an empty DRAFT= must not
# silently turn into "open a non-draft request".
DRAFT=${DRAFT:-1}

step() {
    printf '\n\033[0;36m==>\033[0m %s\n' "$1"
}

note() {
    printf '\033[1;33m..\033[0m %s\n' "$1" >&2
}

fail() {
    printf '\033[0;31m!!\033[0m %s\n' "$1" >&2
    exit 1
}

enabled() {
    [ -n "$1" ] && [ "$1" != 0 ]
}

# Windows jq writes CRLF; -b exists only in those builds and keeps output LF.
if command jq -b -n null >/dev/null 2>&1; then
    jqx() { command jq -b "$@"; }
else
    jqx() { command jq "$@"; }
fi

# Ship works on the branch of the current working tree, including when it is a worktree.
cd "$(git rev-parse --show-toplevel)"

branch=$(git branch --show-current)
branch_slug=$(printf '%s' "$branch" | tr / -)

step "Preflight"

[ -n "$branch" ] || fail "Detached HEAD — check out a branch first"
[ "$branch" != "$BASE" ] || fail "Cannot ship from the base branch $BASE"

git remote get-url origin >/dev/null 2>&1 || fail "No 'origin' remote configured"

[ -z "$(git status --porcelain)" ] || fail "Working tree is dirty — commit or stash first"

git fetch origin "$BASE" --quiet 2>/dev/null ||
    fail "Cannot fetch $BASE from origin — does the branch exist there?"

# The branch itself need not be on origin: that is an ordinary first ship.
git fetch origin "$branch" --quiet 2>/dev/null || true

# Anything on origin that HEAD lacks means the push would be rejected: someone else pushed, or
# the branch was rebased and its old commits are still up there. Git's own rejection names neither.
if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    unpulled=$(git rev-list --count "HEAD..origin/$branch")
    if [ "$unpulled" != 0 ]; then
        missing=$(git rev-list --reverse --no-merges --cherry-pick --right-only "HEAD...origin/$branch")
        if [ -n "$missing" ]; then
            fail "origin/$branch has commit(s) whose changes HEAD does not carry:
$(printf '%s\n' "$missing" | git log --no-walk=unsorted --stdin --format='     %h %an: %s')
   A push would drop them. Fetch and integrate them, then run ship again:
   HEAD not rebased:  git pull --rebase
   HEAD rebased:      git cherry-pick $(printf '%s\n' "$missing" | git log --no-walk=unsorted --stdin --format=%h | paste -sd ' ' -)"
        fi
        fail "origin/$branch holds an older copy of commits HEAD already carries (a rebase).
   Replace it:       git push --force-with-lease, then run ship again"
    fi
fi

commits=$(git rev-list --count "origin/$BASE..HEAD")
[ "$commits" != 0 ] || fail "Branch has no commits over origin/$BASE — nothing to ship"

# Conflicts are cheaper to find now than after the request exists. --write-tree is a dry run.
merge_status=0
git merge-tree --write-tree HEAD "origin/$BASE" >/dev/null 2>&1 || merge_status=$?
case $merge_status in
    0) ;;
    1) fail "Branch conflicts with $BASE — rebase onto origin/$BASE first" ;;
    *) fail "Could not check for conflicts with $BASE (git merge-tree exited $merge_status)" ;;
esac

behind=$(git rev-list --count "HEAD..origin/$BASE")
[ "$behind" = 0 ] || note "Branch is $behind commit(s) behind origin/$BASE — a rebase is advisable"

# Some files conflict by existing rather than by content: two migrations added on two branches
# fork the revision graph although merge-tree sees no conflict. Only the base can notice.
while IFS= read -r conflict_path; do
    [ -n "$conflict_path" ] || continue
    mine=$(git diff --name-only --diff-filter=A "origin/$BASE...HEAD" -- "$conflict_path")
    theirs=$(git diff --name-only --diff-filter=A "HEAD...origin/$BASE" -- "$conflict_path")
    if [ -n "$mine" ] && [ -n "$theirs" ]; then
        fail "Both the branch and $BASE added files under $conflict_path since they diverged.
   Rebase onto origin/$BASE and reconcile them (for migrations: re-point yours at the new head)."
    fi
done <<EOF
$CONFLICT_PATHS
EOF

echo "Branch:  $branch → $BASE"
echo "Commits: $commits"

# A request nobody can hold in their head is reviewed by nobody. A norm, not a gate.
# shellcheck disable=SC2086 # DIFF_PATHS is a newline-separated list of paths without spaces
changed=$(git diff --shortstat "origin/$BASE...HEAD" -- $DIFF_PATHS |
    awk '{ n = 0; for (i = 1; i < NF; i++) if ($(i + 1) ~ /^(insertion|deletion)/) n += $i; print n }')
diff_paths_shown=$(printf '%s\n' "$DIFF_PATHS" | paste -sd ' ' -)
echo "Size:    ${changed:-0} lines in $diff_paths_shown, norm $MAX_DIFF_LINES"
if [ "${changed:-0}" -gt "$MAX_DIFF_LINES" ]; then
    note "Request is $changed lines in $diff_paths_shown against a norm of $MAX_DIFF_LINES — consider splitting it"
fi

# Same gate as the pre-push hook and CI: the checks [checks].static names.
step "Static checks"
sh "$ROOT/scripts/run-checks.sh" static || fail "Checks failed — fix them before shipping"

# The checks change nothing by design; anything left behind would ship unreviewed.
[ -z "$(git status --porcelain)" ] || fail "Checks modified files — review and commit them, then run ship again"

summary() {
    step "Done"
    echo "  Branch:  $branch"
    echo "  Review:  $1"
    echo "  Pushed:  $2"
    echo "  Request: ${3:-not created}"
}

# Probed before the dry run: a dry run is where one finds out whether shipping will work.
have_claude=true
command -v claude >/dev/null 2>&1 || have_claude=false
command -v jq >/dev/null 2>&1 || fail "jq is required to read what the review and the request produce"

if enabled "$DRY_RUN"; then
    step "Dry run — the branch is ready to ship, stopping here"
    summary "not run" "no"
    exit 0
fi

review_status=skipped

# Review what has not been shipped before. The mark of the last ship is a ref, so a worktree keeps
# it; a rebase leaves it pointing at commits that are gone, which the ancestor test catches.
review_range="origin/$BASE...HEAD"
ship_mark="refs/ship/$branch_slug"

if last_ship=$(git rev-parse --verify --quiet "$ship_mark"); then
    if git merge-base --is-ancestor "$last_ship" HEAD 2>/dev/null; then
        review_range="$last_ship..HEAD"
    else
        note "The last ship of this branch is no longer in its history — reviewing against $BASE"
    fi
fi

if enabled "$NO_REVIEW"; then
    note "Review skipped (NO_REVIEW)"
elif [ "$have_claude" = false ]; then
    note "claude CLI not found — review skipped, run /review-changes by hand"
else
    step "Review"
    review_file="$REVIEW_DIR/$branch_slug-$(git rev-parse --short HEAD).json"

    # Named in words, not as a slash command: those are not expanded in headless mode. The path
    # goes in twice, as argument and as $out, so a model retyping it still lands on the right file.
    out="$review_file" \
        claude -p "Use the review-changes skill with the argument: --depth shallow --out $review_file $review_range" \
        --model "$REVIEW_MODEL" \
        --allowedTools "$REVIEW_TOOLS" --disallowedTools "$DENIED_GIT" </dev/null ||
        note "Review did not finish"

    # A model gate can fail for reasons unrelated to the code; only findings block.
    if [ -f "$review_file" ] && ! jqx -e '.findings | type == "array" and all(.[]; type == "object")' "$review_file" >/dev/null 2>&1; then
        # A file that exists but cannot be read is not a clean review.
        fail "Review wrote $review_file, but it has no readable findings list — check it, or ship with NO_REVIEW=1"
    elif [ -f "$review_file" ]; then
        schema=$(jqx -r '.schema_version // 0' "$review_file" 2>/dev/null || echo 0)
        [ "$schema" = "$REVIEW_SCHEMA_VERSION" ] ||
            note "Review wrote schema $schema, expected $REVIEW_SCHEMA_VERSION — reading it anyway"
        # A count that cannot be read must stop the ship, never read as zero.
        blocking=$(jqx '[.findings[] | select(.severity == "blocking")] | length' "$review_file") ||
            fail "Cannot count the blocking findings in $review_file"
        total=$(jqx '.findings | length' "$review_file") ||
            fail "Cannot count the findings in $review_file"
        [ "$blocking" = 0 ] || fail "Review found $blocking blocking finding(s) — they are in $review_file"
        review_status="$total finding(s), none blocking"
        [ "$total" != 0 ] || review_status="nothing found"
        echo "Findings: $review_file"
    else
        note "Review produced no findings file — nothing was checked"
        review_status="left no result"
    fi
fi

step "Push"
git push -u origin HEAD

# Only now: what was reviewed but never pushed has to be reviewed again next time.
git update-ref "$ship_mark" HEAD

if [ "$have_claude" = false ]; then
    note "claude CLI not found — run /compose-request by hand"
    summary "$review_status" "yes"
    exit 0
fi

step "Request"

# Only "not found" (4) means no request; any other failure must not lead to a duplicate.
request_id_status=0
request_id=$(forge request id) || request_id_status=$?
[ "$request_id_status" = 0 ] || [ "$request_id_status" = 4 ] || fail "Cannot tell whether this branch already has a request"

if [ -n "$request_id" ]; then
    echo "Already open, leaving its text alone"
else
    head_sha=$(git rev-parse --short HEAD)
    request_file="$REQUEST_DIR/$branch_slug-$head_sha.json"

    out="$request_file" \
        claude -p "Use the compose-request skill with the argument: $BASE --out $request_file" \
        --model "$COMPOSE_MODEL" \
        --allowedTools "$COMPOSE_TOOLS" --disallowedTools "$DENIED_GIT" </dev/null ||
        fail "compose-request failed"

    # The name is typed by a model; a file for the same commit under a wrong name is the same work.
    if [ ! -f "$request_file" ]; then
        # shellcheck disable=SC2012 # names are ours: <branch>-<sha>.json
        stray=$(ls -t "$REQUEST_DIR"/*-"$head_sha".json 2>/dev/null | head -n 1 || true)
        [ -n "$stray" ] || fail "compose-request produced no file at $request_file"
        note "compose-request wrote $stray rather than $request_file — using it"
        request_file=$stray
    fi

    schema=$(jqx -r '.schema_version // 0' "$request_file")
    [ "$schema" = "$REQUEST_SCHEMA_VERSION" ] ||
        fail "compose-request wrote schema $schema, expected $REQUEST_SCHEMA_VERSION"

    title=$(jqx -r '.title' "$request_file")
    target=$(jqx -r '.base' "$request_file")
    body_file="${request_file%.json}.body.md"
    jqx -r '.body' "$request_file" >"$body_file"

    # A missing key comes out of jq as the string "null", not as an error.
    [ -n "$title" ] && [ "$title" != null ] || fail "compose-request produced no title"
    [ -n "$target" ] && [ "$target" != null ] || fail "compose-request produced no base branch"

    [ "$target" = "$BASE" ] || note "Gate used $BASE, but the git process points the request at $target"

    # Whoever ships is the author; the git process deletes the source branch on merge.
    set -- --target "$target" --title "$title" --assignee @me --body-file "$body_file"
    ! enabled "$DRAFT" || set -- "$@" --draft
    # Only GitLab records branch deletion on the request; GitHub deletes it at merge time.
    if [ "$DELETE_BRANCH" = true ] && [ "$(forge detect)" = gitlab ]; then
        set -- "$@" --delete-branch
    fi
    request_id=$(forge request create "$@") || fail "Could not create the request"
    request_id=${request_id##*/}
fi

request_url=$(forge request url "$request_id")
echo "Request: $request_url"

summary "$review_status" "yes" "$request_url"

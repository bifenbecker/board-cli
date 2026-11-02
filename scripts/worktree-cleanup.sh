#!/bin/sh
# Removes a task's worktree together with its local branch.
#
# Usage:
#   sh scripts/worktree-cleanup.sh [NAME=<worktree directory>] [FORCE=1]
#
#   NAME   the directory name inside the worktree directory; the current worktree by default
#   FORCE  remove even when work is uncommitted or unpushed
#
# Without FORCE it refuses while the worktree holds uncommitted changes or commits that are not
# on origin. The branch on origin is left alone: it is deleted when the request is merged.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FORGE_CMD=$(sh "$ROOT/scripts/workflow.sh" get tools.forge forge)
WORKTREES_DIR=$(sh "$ROOT/scripts/workflow.sh" get worktree.dir)
LINKS=$(sh "$ROOT/scripts/workflow.sh" get worktree.link '')

usage() {
    sed -n '/^# Usage:/,/^$/{ s/^# \{0,1\}//; p; }' "$0" >&2
}

is_windows() {
    case $(uname -s) in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# Shared paths are links into the main repository (a junction or a hard link on Windows). If one
# survives, the removal below walks through it into the real directory, so failing here is fatal.
unlink_shared_path() {
    for unlink_attempt in 1 2 3; do
        [ -e "$1" ] || [ -L "$1" ] || return 0
        [ "$unlink_attempt" != 3 ] || break
        if is_windows && [ -d "$1" ]; then
            cmd //c rmdir "$(cygpath -w "$1")" >/dev/null 2>&1 || true
        else
            rm -f "$1" 2>/dev/null || true
        fi
        # A handle held by something that is closing releases in a moment.
        [ "$unlink_attempt" != 1 ] || sleep 1
    done
    echo "Could not detach $1, so the worktree is left in place." >&2
    echo "Removing it now would reach through the link into the main repository." >&2
    echo "Close whatever holds it — an editor, a language server, a shell inside the worktree." >&2
    exit 1
}

NAME=
FORCE=

for arg in "$@"; do
    case $arg in
        NAME=*) NAME=${arg#NAME=} ;;
        FORCE=*) FORCE=${arg#FORCE=} ;;
        -h | --help | help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage
            exit 2
            ;;
    esac
done

forced=false
[ -z "$FORCE" ] || [ "$FORCE" = 0 ] || forced=true

# The main working tree is always listed first.
main_root=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
! command -v cygpath >/dev/null 2>&1 || main_root=$(cygpath -u "$main_root")

# The name is the first path segment after the worktree directory, so this works from any
# subdirectory of the worktree.
if [ -z "$NAME" ]; then
    current_dir=$(pwd)
    case $current_dir in
        */"$WORKTREES_DIR"/*) ;;
        *)
            echo "Run outside a worktree — give NAME=<directory>" >&2
            usage
            exit 2
            ;;
    esac
    path_inside=${current_dir#*/"$WORKTREES_DIR"/}
    NAME=${path_inside%%/*}
fi

# One directory, not a path: ".." would point everything below at the main repository.
case $NAME in
    '' | */* | *\\* | . | ..)
        echo "Not a worktree name: '$NAME' — it is one directory inside $WORKTREES_DIR/" >&2
        exit 2
        ;;
esac

worktree_dir="$main_root/$WORKTREES_DIR/$NAME"
[ -d "$worktree_dir" ] || {
    echo "No such worktree: $worktree_dir" >&2
    exit 1
}

# Asked of git's registry, not of the directory: an unregistered directory would answer for the
# main repository. Matched on the path's tail, since git prints Windows paths in its own form.
branch=$(git worktree list --porcelain | awk -v suffix="/$WORKTREES_DIR/$NAME" '
    /^worktree / { path = substr($0, 10); sub(/\r$/, "", path); found = (index(path, suffix) == length(path) - length(suffix) + 1) }
    /^branch /   { if (found) { sub(/^branch refs\/heads\//, ""); sub(/\r$/, ""); print; exit } }
')

if [ "$forced" = false ]; then
    uncommitted=$(git -C "$worktree_dir" status --porcelain)
    # Commits on no branch of origin, which includes a branch that was never pushed.
    unpushed_count=$(git -C "$worktree_dir" rev-list --count HEAD --not --remotes=origin)
    # A squash merge leaves the branch's commits off main, and the merge deletes the branch on
    # origin. They are saved all the same when a merged request carried exactly this HEAD.
    if [ "$unpushed_count" != 0 ] && [ -n "$branch" ]; then
        # Exit 4 means "no merged request"; any other failure means the check itself failed.
        merged_status=0
        merged_id=$($FORGE_CMD request id "$branch" --state merged 2>/dev/null) || merged_status=$?
        merged_sha=
        if [ "$merged_status" = 0 ]; then
            merged_sha=$($FORGE_CMD request view "$merged_id" --jq .sha 2>/dev/null) || merged_status=$?
        fi
        if [ "$merged_status" = 0 ] && [ "$merged_sha" = "$(git -C "$worktree_dir" rev-parse HEAD)" ]; then
            echo "Branch $branch was merged through request $merged_id; its commits are saved there"
            unpushed_count=0
        elif [ "$merged_status" != 0 ] && [ "$merged_status" != 4 ]; then
            echo "Could not check whether $branch was merged (forge exited $merged_status)." >&2
        fi
    fi
    if [ -n "$uncommitted" ] || [ "$unpushed_count" != 0 ]; then
        echo "The worktree $NAME still holds work that is not saved anywhere:" >&2
        [ -z "$uncommitted" ] ||
            echo "  uncommitted files: $(printf '%s\n' "$uncommitted" | wc -l | tr -d ' ')" >&2
        [ "$unpushed_count" = 0 ] || echo "  commits not on origin: $unpushed_count" >&2
        echo "Remove it with the work: just worktree-cleanup NAME=$NAME FORCE=1" >&2
        exit 1
    fi
fi

while IFS= read -r link; do
    [ -n "$link" ] || continue
    unlink_shared_path "$worktree_dir/$link"
done <<EOF
$LINKS
EOF

# The directory being removed cannot be the current one: Windows keeps it locked.
cd "$main_root"
# Files installed by a package manager are often read-only.
chmod -R u+w "$worktree_dir" 2>/dev/null || true

echo "Removing the worktree: $WORKTREES_DIR/$NAME"

# Unforced, nothing unsaved was found, so a refusal from git is worth showing, not overriding.
set -- worktree remove "$WORKTREES_DIR/$NAME"
[ "$forced" = false ] || set -- "$@" --force
if ! git_error=$(git "$@" 2>&1); then
    printf '%s\n' "$git_error" | sed 's/^/  /' >&2
    if [ "$forced" = false ]; then
        echo "Remove it anyway: just worktree-cleanup NAME=$NAME FORCE=1" >&2
        exit 1
    fi
    echo "  taking the directory out and clearing the record instead"
    rm -rf "$worktree_dir" 2>/dev/null || true
fi

if [ -e "$worktree_dir" ]; then
    # Prune now, so only one thing is left wrong: files on disk. Rerunning finishes the job.
    git worktree prune
    echo "Files inside the worktree are held open, so it is still on disk:" >&2
    find "$worktree_dir" -type f 2>/dev/null | head -5 | sed 's|^|  |' >&2
    echo "Close whatever holds them, then run the same command again." >&2
    exit 1
fi

if [ -n "$branch" ]; then
    echo "Removing the local branch: $branch"
    if ! git_error=$(git branch -D "$branch" 2>&1); then
        # Only a branch that really no longer exists is fine; a failure to delete one is not.
        if git show-ref --verify --quiet "refs/heads/$branch"; then
            printf '%s\n' "$git_error" | sed 's/^/  /' >&2
            exit 1
        fi
        echo "The branch is already gone"
    fi
else
    echo "No branch to remove: this worktree was no longer registered" >&2
fi

echo "Tidying up..."
git worktree prune
git fetch origin --prune

echo ""
echo "=== Done ==="
echo "  Worktree: $WORKTREES_DIR/$NAME (removed)"
[ -z "$branch" ] || echo "  Branch:   $branch (removed locally, untouched on origin)"
echo ""
echo "  If you were inside it: cd $main_root"

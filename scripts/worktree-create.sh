#!/bin/sh
# Creates a git worktree for a task.
#
# Usage:
#   sh scripts/worktree-create.sh ISSUE=<n> [TITLE="<title>"] [TYPE=<type>] [BASE=<branch>]
#   sh scripts/worktree-create.sh BRANCH=<branch name> [BASE=<branch>]
#
#   ISSUE   the ticket: an issue number on GitHub/GitLab, else PROJECT-<n> or <n>; its title is
#           read with board.title (forge for GitHub/GitLab) unless TITLE is given
#   TITLE   the task's title, which makes the branch slug
#   TYPE    the branch type (default from git.default_type in workflow.toml)
#   BRANCH  the whole branch name; no issue is read
#   BASE    the base branch (default from git.default_branch)
#
# The branch name follows git.branch_template in workflow.toml. Paths in worktree.link are linked
# from the main checkout, and worktree.install runs inside the new worktree, so the script works
# for any project without edits.

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

config() {
    sh "$ROOT/scripts/workflow.sh" get "$@"
}

DEFAULT_BASE=$(config git.default_branch)
DEFAULT_TYPE=$(config git.default_type)
BRANCH_TEMPLATE=$(config git.branch_template)
WORKTREES_DIR=$(config worktree.dir)
LINKS=$(config worktree.link '')
INSTALL_CMD=$(config worktree.install '')
BOARD_KIND=$(config board.kind '')
BOARD_PROJECT=$(config board.project '')
FORGE_CMD=$(config tools.forge forge)
# How a ticket title is read; {ticket} is substituted. Issues on GitHub/GitLab come from forge.
TITLE_CMD=$(config board.title '')
if [ -z "$TITLE_CMD" ]; then
    case $BOARD_KIND in
        github | gitlab) TITLE_CMD="$FORGE_CMD issue view {ticket} --jq .title" ;;
    esac
fi

# The worktree directory is named after the branch, and a full path on Windows runs into the
# 260-character limit, so the slug of a long title is cut.
MAX_SLUG_LEN=60

usage() {
    sed -n '/^# Usage:/,/^$/{ s/^# \{0,1\}//; p; }' "$0" >&2
}

fail() {
    echo "$1" >&2
    exit 1
}

is_windows() {
    case $(uname -s) in
        MINGW* | MSYS* | CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
}

# Git Bash silently copies instead of linking, so Windows' own links are used: a junction for a
# directory, a hard link for a file. Neither needs administrator rights.
link_into_worktree() {
    if ! is_windows; then
        ln -sfn "$1" "$2"
        return
    fi
    if [ -e "$2" ] || [ -L "$2" ]; then
        if [ -d "$2" ]; then
            cmd //c rmdir "$(cygpath -w "$2")" >/dev/null 2>&1 || rm -rf "$2"
        else
            rm -f "$2"
        fi
    fi
    link_kind=//H
    [ ! -d "$1" ] || link_kind=//J
    cmd //c mklink "$link_kind" "$(cygpath -w "$2")" "$(cygpath -w "$1")" >/dev/null
}

# Cyrillic is transliterated the way boards do it when they suggest a branch name; both cases are
# listed because lowercasing Cyrillic depends on the locale, while replacing bytes does not.
TRANSLIT='s/а/a/g;s/б/b/g;s/в/v/g;s/г/g/g;s/д/d/g;s/е/e/g;s/ё/e/g;s/ж/zh/g;s/з/z/g;s/и/i/g;s/й/i/g;s/к/k/g;s/л/l/g;s/м/m/g;s/н/n/g;s/о/o/g;s/п/p/g;s/р/r/g;s/с/s/g;s/т/t/g;s/у/u/g;s/ф/f/g;s/х/h/g;s/ц/c/g;s/ч/ch/g;s/ш/sh/g;s/щ/sh/g;s/ъ//g;s/ы/y/g;s/ь//g;s/э/e/g;s/ю/yu/g;s/я/ya/g;s/А/a/g;s/Б/b/g;s/В/v/g;s/Г/g/g;s/Д/d/g;s/Е/e/g;s/Ё/e/g;s/Ж/zh/g;s/З/z/g;s/И/i/g;s/Й/i/g;s/К/k/g;s/Л/l/g;s/М/m/g;s/Н/n/g;s/О/o/g;s/П/p/g;s/Р/r/g;s/С/s/g;s/Т/t/g;s/У/u/g;s/Ф/f/g;s/Х/h/g;s/Ц/c/g;s/Ч/ch/g;s/Ш/sh/g;s/Щ/sh/g;s/Ъ//g;s/Ы/y/g;s/Ь//g;s/Э/e/g;s/Ю/yu/g;s/Я/ya/g'

slugify() {
    printf '%s' "$1" | sed "$TRANSLIT" | tr '[:upper:]' '[:lower:]' |
        sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//'
}

# GitHub/GitLab issues are numbers. Other boards use PROJECT-<n>; a bare number gets the prefix.
normalize_issue_key() {
    nik_key=${1#\#}
    case $BOARD_KIND in
        github | gitlab)
            case $nik_key in
                '' | *[!0-9]*) fail "Not an issue number: $1" ;;
            esac
            ;;
        *)
            nik_key=$(printf '%s' "$nik_key" | tr '[:lower:]' '[:upper:]')
            case $nik_key in
                *[!0-9]* | '') ;;
                *) nik_key="$BOARD_PROJECT-$nik_key" ;;
            esac
            printf '%s' "$nik_key" | grep -Eqx "$BOARD_PROJECT-[0-9]+" ||
                fail "Not a ticket: $1 (expected $BOARD_PROJECT-<number> or <number>)"
            ;;
    esac
    printf '%s' "$nik_key"
}

# Cut at a word boundary, so the branch name does not end mid-word.
truncate_slug() {
    if [ "${#1}" -le "$MAX_SLUG_LEN" ]; then
        printf '%s' "$1"
        return
    fi
    truncate_cut=$(printf '%s' "$1" | cut -c1-"$MAX_SLUG_LEN")
    printf '%s' "${truncate_cut%-*}"
}

build_branch_name() {
    printf '%s' "$BRANCH_TEMPLATE" | sed "s/{type}/$1/g; s/{ticket}/$2/g; s/{slug}/$3/g"
}

ISSUE=
TITLE=
TYPE=
BRANCH=
BASE=

for arg in "$@"; do
    case $arg in
        ISSUE=*) ISSUE=${arg#ISSUE=} ;;
        TITLE=*) TITLE=${arg#TITLE=} ;;
        TYPE=*) TYPE=${arg#TYPE=} ;;
        BRANCH=*) BRANCH=${arg#BRANCH=} ;;
        BASE=*) BASE=${arg#BASE=} ;;
        -h | --help | help) usage; exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage
            exit 2
            ;;
    esac
done

BASE=${BASE:-$DEFAULT_BASE}
TYPE=${TYPE:-$DEFAULT_TYPE}

[ -n "$ISSUE" ] || [ -n "$BRANCH" ] || { usage; exit 2; }
[ -z "$ISSUE" ] || [ -z "$BRANCH" ] ||
    fail "ISSUE= and BRANCH= are exclusive: a branch name is either built from a task or given whole"
[ -z "$TITLE" ] || [ -n "$ISSUE" ] || fail "TITLE= only means something together with ISSUE="

# Paths are taken from the root of the main working tree, so this runs from anywhere in the project.
main_root=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
! command -v cygpath >/dev/null 2>&1 || main_root=$(cygpath -u "$main_root")
cd "$main_root"

# Linear history rests on pull.rebase. An existing value is the owner's choice and stays.
if [ -z "$(git config --local --get pull.rebase || true)" ]; then
    git config --local pull.rebase true
    echo "Turned on pull.rebase for this repository"
fi

issue_key=
if [ -n "$ISSUE" ]; then
    issue_key=$(normalize_issue_key "$ISSUE")
    if [ -z "$TITLE" ]; then
        [ -n "$TITLE_CMD" ] || fail "No board.title command configured for '$BOARD_KIND' — pass TITLE=\"...\""
        echo "Reading $issue_key..."
        TITLE=$(sh -c "$(printf '%s' "$TITLE_CMD" | sed "s/{ticket}/$issue_key/g")") ||
            fail "Could not read $issue_key from the board; pass the title: TITLE=\"...\""
    fi
    [ -n "$TITLE" ] || fail "$issue_key has no title"
    slug=$(truncate_slug "$(slugify "$TITLE")")
    [ -n "$slug" ] || fail "No slug could be built from \"$TITLE\" — give the branch name with BRANCH="
    BRANCH=$(build_branch_name "$TYPE" "$issue_key" "$slug")
    echo "Task: $issue_key — $TITLE"
fi

# Slashes in a branch name must not become nested directories.
worktree_name=$(printf '%s' "$BRANCH" | tr / -)
worktree_dir="$WORKTREES_DIR/$worktree_name"

if [ -e "$worktree_dir" ]; then
    echo "The directory already exists: $worktree_dir" >&2
    fail "Remove it: just worktree-cleanup NAME=$worktree_name"
fi

echo "Fetching origin..."
git fetch origin --prune

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # A leftover local branch behind origin would have its first push rejected, after work started.
    if git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
        unpulled=$(git rev-list --count "$BRANCH..origin/$BRANCH")
        unpushed=$(git rev-list --count "origin/$BRANCH..$BRANCH")
        if [ "$unpulled" != 0 ]; then
            echo "The local $BRANCH is $unpulled commit(s) behind origin/$BRANCH" >&2
            if [ "$unpushed" = 0 ]; then
                fail "Catch up: git branch -f $BRANCH origin/$BRANCH"
            fi
            echo "The histories have diverged — $unpushed local commit(s) are not on origin" >&2
            fail "Sort out by hand which of them are still wanted"
        fi
    fi
    start_point="the local $BRANCH"
    git worktree add "$worktree_dir" "$BRANCH"
elif git show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
    start_point="origin/$BRANCH"
    git worktree add "$worktree_dir" -b "$BRANCH" "origin/$BRANCH"
else
    git show-ref --verify --quiet "refs/remotes/origin/$BASE" || fail "The base branch origin/$BASE does not exist"

    # A branch for this issue may exist already; a second one is started only on purpose.
    if [ -n "$issue_key" ]; then
        siblings=$(git for-each-ref --format='%(refname:strip=3)' "refs/remotes/origin/*/$issue_key-*")
        if [ -n "$siblings" ]; then
            echo "Note: origin already has branches for this issue:" >&2
            printf '%s\n' "$siblings" | sed 's/^/  /' >&2
            echo "Continue in one of them: BRANCH=<branch name>" >&2
        fi
    fi

    # --no-track: otherwise `git pull` would merge the base branch in. The upstream appears on
    # the first `git push -u origin HEAD`.
    start_point="origin/$BASE"
    git worktree add --no-track "$worktree_dir" -b "$BRANCH" "origin/$BASE"
fi

while IFS= read -r link; do
    [ -n "$link" ] || continue
    if [ -e "$link" ]; then
        link_into_worktree "$main_root/$link" "$main_root/$worktree_dir/$link"
        echo "Linked $link"
    fi
done <<EOF
$LINKS
EOF

if [ -n "$INSTALL_CMD" ]; then
    echo "Installing: $INSTALL_CMD"
    (cd "$worktree_dir" && sh -c "$INSTALL_CMD") || fail "Install failed in $worktree_dir: $INSTALL_CMD"
fi

echo ""
echo "=== The worktree is ready ==="
echo "  Branch:        $BRANCH"
echo "  Branched from: $start_point"
echo "  Directory:     $worktree_dir"
echo "  Author:        $(git config user.name) <$(git config user.email)>"
echo ""
echo "  cd $worktree_dir"

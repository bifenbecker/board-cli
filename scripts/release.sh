#!/bin/sh
# Releases through a request, the same way on any project: everything project-specific is read
# from workflow.toml, so the script is copied between projects unchanged.
#
# Usage:
#   sh scripts/release.sh prepare [VERSION=<tag>]
#   sh scripts/release.sh publish
#
#   prepare   from the tip of the default branch: bump the version, regenerate CHANGELOG.md,
#             commit "chore(release): <tag>" on release/<tag>, push, open or update the request.
#             VERSION overrides the version git-cliff works out from the commits.
#   publish   after that request is merged: tag the release commit and publish the platform
#             release from its CHANGELOG section. Exits 0 with nothing to do when HEAD carries
#             no unpublished release, so CI can run it on every merge.
#
# workflow.toml keys: git.default_branch, release.tag_template, release.version_pattern,
# release.current (prints the version), release.bump (sets it; {version} is substituted),
# tools.forge (the forge command).

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

config() {
    sh "$ROOT/scripts/workflow.sh" get "$@"
}

RELEASE_BRANCH=$(config git.default_branch)
VERSION_PATTERN=$(config release.version_pattern)
TAG_TEMPLATE=$(config release.tag_template)
CURRENT_CMD=$(config release.current)
BUMP_CMD=$(config release.bump)
FORGE_CMD=$(config tools.forge forge)
RUNNER=$(config checks.runner just)

MODE=
VERSION=
TEMP_FILE=
RETURN_TO=

usage() {
    sed -n '/^# Usage:/,/^$/{ s/^# \{0,1\}//; p; }' "$0"
}

for arg in "$@"; do
    case $arg in
        prepare | publish) MODE=$arg ;;
        VERSION=*) VERSION=${arg#VERSION=} ;;
        -h | --help | help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[ -n "$MODE" ] || { usage >&2; exit 2; }
[ "$MODE" = prepare ] || [ -z "$VERSION" ] || { echo "VERSION= only applies to prepare" >&2; exit 2; }

forge() {
    # shellcheck disable=SC2086 # tools.forge may be a command with arguments, e.g. "sh bin/forge"
    $FORGE_CMD "$@"
}

step() {
    printf '\n\033[0;36m==>\033[0m %s\n' "$1"
}

fail() {
    printf '\033[0;31m!!\033[0m %s\n' "$1" >&2
    exit 1
}

cleanup() {
    [ -z "$TEMP_FILE" ] || rm -f "$TEMP_FILE"
    [ -z "$RETURN_TO" ] || git checkout --quiet --force "$RETURN_TO"
}
trap cleanup EXIT

if command jq -b -n null >/dev/null 2>&1; then
    jqx() { command jq -b "$@"; }
else
    jqx() { command jq "$@"; }
fi

TAG_PREFIX=${TAG_TEMPLATE%%"{version}"*}
TAG_SUFFIX=${TAG_TEMPLATE#*"{version}"}

tag_of() {
    printf '%s%s%s' "$TAG_PREFIX" "$1" "$TAG_SUFFIX"
}

# The version inside a tag, or failure when the tag does not fit the template.
version_of() {
    version_of_v=${1#"$TAG_PREFIX"}
    version_of_v=${version_of_v%"$TAG_SUFFIX"}
    [ "$(tag_of "$version_of_v")" = "$1" ] || return 1
    printf '%s' "$version_of_v" | grep -Eqx "$VERSION_PATTERN" || return 1
    printf '%s' "$version_of_v"
}

current_version() {
    # Captured before trimming: in a pipe only the last command's status counts.
    current_raw=$(sh -c "$CURRENT_CMD") || fail "release.current failed: $CURRENT_CMD"
    current_v=$(printf '%s' "$current_raw" | tr -d '\r\n')
    [ -n "$current_v" ] || fail "release.current printed nothing: $CURRENT_CMD"
    printf '%s' "$current_v"
}

# ls-remote --exit-code answers 2 for a missing ref; any other failure says nothing about the tag.
remote_tag_exists() {
    remote_tag_status=0
    git ls-remote --exit-code --tags origin "refs/tags/$1" >/dev/null || remote_tag_status=$?
    case $remote_tag_status in
        0) return 0 ;;
        2) return 1 ;;
        *) fail "Cannot reach origin to check tag $1" ;;
    esac
}

release_exists() {
    release_exists_status=0
    forge release view "$1" >/dev/null 2>&1 || release_exists_status=$?
    case $release_exists_status in
        0) return 0 ;;
        4) return 1 ;;
        *) fail "Cannot tell whether release $1 exists (forge release view exited $release_exists_status)" ;;
    esac
}

changelog_section() {
    awk -v heading="## [$1]" '
        index($0, heading) == 1 { found = 1; next }
        found && /^## \[/ { exit }
        found { lines[++count] = $0 }
        END {
            first = 1
            while (first <= count && lines[first] ~ /^[[:space:]]*$/) first++
            last = count
            while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
            for (i = first; i <= last; i++) print lines[i]
        }
    '
}

short() {
    printf '%s' "$1" | cut -c1-12
}

preflight() {
    step "Preflight"
    [ -z "$(git status --porcelain)" ] || fail "Working tree is dirty — commit or stash first"
    git fetch --quiet --tags --force origin "$RELEASE_BRANCH" || fail "Cannot reach origin"
    git merge-base --is-ancestor HEAD "origin/$RELEASE_BRANCH" ||
        fail "Releases run from $RELEASE_BRANCH: HEAD is not on origin/$RELEASE_BRANCH"
}

publish() {
    publish_version=$(current_version)
    publish_tag=$(tag_of "$publish_version")

    # The squash keeps the request title, so the release commit is found by its subject.
    publish_commit=$(git log -1 --format=%H -E --grep="^chore\(release\): $(printf '%s' "$publish_tag" | sed 's/[][\.^$*+?(){}|/]/\\&/g')( \(|$)" HEAD)
    if [ -z "$publish_commit" ]; then
        echo "Nothing to publish: no \"chore(release): $publish_tag\" commit on HEAD"
        return
    fi
    if remote_tag_exists "$publish_tag" && release_exists "$publish_tag"; then
        echo "Nothing to publish: $publish_tag is already released"
        return
    fi

    TEMP_FILE=$(mktemp)
    git show "$publish_commit:CHANGELOG.md" | changelog_section "$publish_version" >"$TEMP_FILE"
    [ -s "$TEMP_FILE" ] || fail "CHANGELOG.md at $(short "$publish_commit") has no section for $publish_version"

    if ! remote_tag_exists "$publish_tag"; then
        step "Tag $publish_tag on $(short "$publish_commit")"
        if git rev-parse --verify --quiet "refs/tags/$publish_tag" >/dev/null; then
            [ "$(git rev-parse "$publish_tag^{commit}")" = "$publish_commit" ] ||
                fail "Local tag $publish_tag points elsewhere than $(short "$publish_commit")"
        else
            git tag -a "$publish_tag" "$publish_commit" -m "$publish_tag"
        fi
        git push origin "refs/tags/$publish_tag"
    fi

    step "Release $publish_tag"
    forge release publish "$publish_tag" --title "$publish_tag" --body-file "$TEMP_FILE"

    step "Done"
    echo "  Released: $publish_tag"
}

request_description() {
    cat <<EOF
## Context

No ticket — release $1, prepared by \`$RUNNER release\`.

## Changes

The $1 section of CHANGELOG.md, and the version bump. The section is in the diff; it is not
copied here, so a rerun of \`$RUNNER release\` cannot leave this text stale.

## How it was checked

Changelog generated by git-cliff from the commits since $2; nothing edited by hand.

## Review focus

Every change since $2 is listed, and the version fits what it holds.
EOF
}

prepare() {
    prepare_current=$(current_version)

    # git-cliff counts from the newest tag, the version file from itself; they must agree.
    prepare_latest=$(git tag --list --sort=-v:refname "$(tag_of '*')" | while IFS= read -r t; do
        version_of "$t" >/dev/null && { printf '%s' "$t"; break; }
    done)
    if [ -n "$prepare_latest" ] && [ "$prepare_latest" != "$(tag_of "$prepare_current")" ]; then
        fail "The version is $prepare_current but the newest tag is $prepare_latest: reconcile them first"
    fi

    [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$RELEASE_BRANCH")" ] ||
        fail "A release is prepared from the tip of origin/$RELEASE_BRANCH: pull or check it out first"
    command -v git-cliff >/dev/null 2>&1 || fail "git-cliff is required: https://git-cliff.org/docs/installation"

    if [ -z "$VERSION" ]; then
        prepare_cliff_err=$(mktemp)
        VERSION=$(git-cliff --bumped-version 2>"$prepare_cliff_err") || {
            cat "$prepare_cliff_err" >&2
            rm -f "$prepare_cliff_err"
            fail "Could not work out the next version"
        }
        rm -f "$prepare_cliff_err"
        if [ "$VERSION" = "$(tag_of "$prepare_current")" ]; then
            echo "Nothing to release since $VERSION"
            return
        fi
    fi
    prepare_version=$(version_of "$VERSION") ||
        fail "$VERSION does not match $TAG_TEMPLATE with version $VERSION_PATTERN"
    prepare_tag=$(tag_of "$prepare_version")
    [ "$prepare_version" != "$prepare_current" ] &&
        [ "$(printf '%s\n%s\n' "$prepare_current" "$prepare_version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$prepare_version" ] ||
        fail "Version $prepare_version is not above the current $prepare_current"
    prepare_branch="release/$prepare_tag"
    ! remote_tag_exists "$prepare_tag" || fail "Tag $prepare_tag already exists"

    # Captured first: piped straight into jq, a failed list would read as "none open".
    prepare_requests=$(forge request list --limit 100 --json) || fail "Cannot list the open requests"
    prepare_open=$(printf '%s\n' "$prepare_requests" |
        jqx -r --arg branch "$prepare_branch" \
            '.[] | select((.source_branch | startswith("release/")) and .source_branch != $branch) | .url')
    [ -z "$prepare_open" ] || fail "Another release request is open: $prepare_open. Merge or close it first"

    prepare_start=$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)
    RETURN_TO=$prepare_start

    step "Branch $prepare_branch"
    git checkout --quiet -B "$prepare_branch"

    step "Changelog"
    git-cliff --tag "$prepare_tag" -o CHANGELOG.md
    TEMP_FILE=$(mktemp)
    changelog_section "$prepare_version" <CHANGELOG.md >"$TEMP_FILE"
    [ -s "$TEMP_FILE" ] ||
        fail "Nothing for $prepare_tag in the changelog: no commit since $(tag_of "$prepare_current") changes the product"

    step "Version"
    sh -c "$(printf '%s' "$BUMP_CMD" | sed "s/{version}/$prepare_version/g")" || fail "release.bump failed"
    [ "$(current_version)" = "$prepare_version" ] || fail "release.bump did not set the version to $prepare_version"

    step "Commit and push"
    # Tracked files only: the bump changes the version files, and anything it leaves untracked
    # (caches, build output) is not part of the release. CHANGELOG.md may be new.
    git add CHANGELOG.md
    git add -u
    git commit --quiet -m "chore(release): $prepare_tag"
    git push --quiet --force origin "$prepare_branch"

    step "Request"
    request_description "$prepare_tag" "$(tag_of "$prepare_current")" >"$TEMP_FILE"
    # Only "not found" (4) means there is no request; any other failure must not open a second one.
    prepare_id_status=0
    prepare_id=$(forge request id "$prepare_branch") || prepare_id_status=$?
    [ "$prepare_id_status" = 0 ] || [ "$prepare_id_status" = 4 ] || fail "Cannot tell whether a request for $prepare_branch is open"
    if [ -z "$prepare_id" ]; then
        forge request create --target "$RELEASE_BRANCH" --title "chore(release): $prepare_tag" \
            --body-file "$TEMP_FILE" --delete-branch
    else
        forge request url "$prepare_id"
    fi

    RETURN_TO=
    git checkout --quiet "$prepare_start"

    step "Done"
    echo "  Prepared: $prepare_tag; merging the request publishes it"
}

cd "$(git rev-parse --show-toplevel)"
preflight
"$MODE"

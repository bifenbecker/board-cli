# board-cli tasks. Recipes forward their arguments to the script they run.

set shell := ["sh", "-cu"]
set positional-arguments := true

# Show available recipes
help:
    @just --list --unsorted

# Lint every shell file, then check help completeness and the provider contract
lint:
    shellcheck bin/board install.sh lib/*/*.sh scripts/*.sh tests/*.sh tests/lib/*.sh tests/unit/*.sh tests/contract/*.sh tests/fake/*
    sh scripts/check-help.sh
    sh scripts/check-contract.sh

# Run the unit and contract tests against fake provider CLIs. Usage: just test [<file>...]
test *args:
    sh tests/run.sh "$@"

# Run the live suite against the four test boards; it creates and deletes issues. Usage: just live [<kind>...]
live *args:
    sh tests/live/run.sh "$@"

# Run every static check, changing nothing
check:
    sh scripts/run-checks.sh static

# Gate the branch, review it, push it and open a draft request. Usage: just ship [BASE=<branch>] [DRY_RUN=1] [NO_REVIEW=1] [DRAFT=0]
ship *args:
    sh scripts/ship.sh "$@"

# Rebuild CHANGELOG.md from the commit history. Usage: just changelog [<tag>]
changelog tag="":
    git-cliff {{ if tag != "" { "--tag " + tag } else { "" } }} -o CHANGELOG.md

# Prepare the next release as a request. Usage: just release [VERSION=vX.Y.Z]
release *args:
    sh scripts/release.sh prepare "$@"

# Publish the merged release request: tag and platform release; nothing to do is not an error
release-publish:
    sh scripts/release.sh publish

# Install the git hooks (prek)
hooks:
    prek install --hook-type pre-commit --hook-type commit-msg --hook-type pre-push

# Create a worktree for a task. Usage: just worktree-create ISSUE=<n> [TYPE=feature] [TITLE="..."] [BASE=<branch>] | BRANCH=<branch>
worktree-create *args:
    sh scripts/worktree-create.sh "$@"

# Remove a worktree after its request merged. Usage: just worktree-cleanup [NAME=<dir>] [FORCE=1]
worktree-cleanup *args:
    sh scripts/worktree-cleanup.sh "$@"

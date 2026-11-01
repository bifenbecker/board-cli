# Git flow

Request = GitHub pull request / GitLab merge request.

## Principles

- Linear history: rebase, never merge
- Isolated work: one worktree per task
- Review mandatory: nothing pushed to trunk directly
- One grammar for branches and commits, enforced by hooks, not asked for
- Everything in English: commits, branches, request titles and descriptions

## Branches

`main` only long-lived branch. Work branches from it, returns to it. No integration branch: with
one deployable trunk it only adds second place for same change to sit.

Names follow [Conventional Branch](https://conventionalbranch.org/): `<type>/<description>`,
lowercase, hyphens. Issue number first, so branch and issue name same thing; no issue, no number:

```
feature/12-portable-tooling
bugfix/naive-datetime-rejected
```

Types: `feature`, `bugfix`, `hotfix`, `release`, `chore`, `docs`, `refactor`, `test`, `ci`.
`main` carries no prefix. Branch name and commit message checked before recorded, so mistake
reported when made, not at review.

Linear history needs `git pull` to rebase: `git config --local pull.rebase true`.

## Worktrees

Work in isolated worktree, one per task: several tasks at once, no stash, no branch switching. The
project has commands to create and clean up worktrees (`just` lists them). Cleanup refuses while
worktree holds uncommitted or unpushed work.

## Commits

[Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/). Type not decoration:
changelog built from it, sections from scope.

```
<type>(<scope>): <description> (#<request>)

<body>

<footers>
```

Angle brackets mark substitution; parentheses around scope and request number literal.

- `type`: from table below
- `scope`: module; outside a module, the area
- `description`: lower case, no full stop, ~50 chars so subject stays under 72
- breaking change: `!` before colon, explained in `BREAKING CHANGE` footer
- `Refs: #<issue>` footer when work has an issue; subject carries no issue number, never mistaken
  for request number
- `Decision: <choice> — <why>` footer, one per choice made on purpose where another looked equally
  right. Reviewers read them before raising finding; request description collects them

| Type | When | Changelog |
|---|---|---|
| `feat` | New capability | Added |
| `fix` | Behaviour corrected | Fixed |
| `refactor` | Behaviour unchanged | Changed |
| `perf` | Faster or cheaper | Performance |
| `revert` | Undone | Reverted |
| `docs`, `test`, `chore`, `ci`, `build` | Product unchanged | — |

Body: why needed, what it does in summary, what it breaks. Two or three lines of what changed, not
a file list. More than a few lines usually means two commits; rest goes to request description.

Request number known only once request exists, never guessed. Reaches trunk through squash message:
subject composed at merge from request title and number. Squash even for single commit.

## Requests

- Target `main`; sub-branch of large task targets its parent branch
- Squash required: one request = one trunk commit, subject = request title with number
- Branch deleted once merged

Ready to merge, as values so bar moves by changing a number:

- Draft: lifted
- Conflicts with base: none
- CI: pipeline green in full; manual jobs do not count
- Approvals from people: none required; the review findings are closed instead
- Open blocking discussions: 0

**Title** follows commit template: squash turns it into commit message. **Description** follows
request template, never empty; template sits where host looks for it.

**Squash message**: commit like any other, same rules. Body = summary written afresh from all
request's commits, not their bodies pasted, since only it stays on trunk.

## Releases

Release = tag on `main` + platform release; notes = version's `CHANGELOG.md` section. Reaches
`main` through request like any change: version bump gets review, `main` stays protected.

- **Prepare**: manual workflow run from `main` (Actions tab), or `just release` locally. Version
  from commit history (or given), changelog regenerated, version bumped, commit
  `chore(release): <tag>` on `release/<tag>`, request opened or updated.
- **Publish**: merging release request triggers release workflow: tag on release commit, platform
  release from its changelog section. Manual run of same workflow retries failed publish.

Same script for every trigger; logic lives there, not in pipeline config. Version source, bump
command and tag shape set in `workflow.toml`, so any versioning scheme fits; next version worked
out automatically only for semantic versions.

`CHANGELOG.md` generated, never edited by hand: product changes in, housekeeping types out. Edit
commit messages instead: changelog exactly as good as they are.

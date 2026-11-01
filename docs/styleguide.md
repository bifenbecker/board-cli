# Styleguide

How board code is written, and why. The reviewer's engineer role checks changes against this
document.

## Shell

board is POSIX `sh`. It has to run wherever `/bin/sh` is dash, ash or busybox: Alpine and Debian
images in CI, minimal containers, macOS. A construct that only bash knows works on the author's
machine and fails on the user's.

- Shebang `#!/bin/sh`; library files start with `# shellcheck shell=sh` and are sourced, not run.
- Absent in POSIX, so not used: arrays, `[[ ]]`, `local`, `<<<`, `$'..'`, `${x//a/b}`,
  `${x:0:n}`, `mapfile`, `type -P`, `set -o pipefail`, process substitution.
- Argument lists for gh and glab are built with `set -- "$@" --flag "$value"`, after the
  command's own flags have been parsed into variables. That is the only list POSIX gives.
- Lists of values (labels, users) are newline-separated strings. They are read back with
  `while IFS= read -r x; do ...; done <<EOF` and not with a pipe, because a pipe would run the loop
  in a subshell and lose the changes it makes to `"$@"`.
- Without `local`, every variable is global. A function names its variables with its own prefix
  (`gh_merge_subject`, `request_checks_doc`), so a callee cannot overwrite its caller's state.
- Without pipefail, `a | b` reports only `b`. A command whose failure matters is captured first:
  `doc=$(board_capture gh ...) || return $?`. Only then is the result piped into jq.
- `shellcheck` passes with the settings in `.shellcheckrc`. The checks disabled there are the ones
  that cannot see across sourced files.

## Layout

| Path | Holds |
|---|---|
| `bin/board` | Finds `BOARD_HOME`, sources the core, calls `board_main` |
| `lib/core/` | Dispatch, global flags, detection, JSON helpers, help footer |
| `lib/cmd/<group>.sh` | Help text and flag parsing of one command group, for both platforms |
| `lib/github/<group>.sh`, `lib/gitlab/<group>.sh` | What a command does on that platform |

A command is a pair of functions in `lib/cmd/<group>.sh`: `help_<path>` and `cmd_<path>`, where
`<path>` is the command words joined by `_` (`board request comment add` is
`cmd_request_comment_add`). A group or subgroup has only `help_<path>`. The dispatcher walks the
words for as long as a `help_` function exists for them, so adding a command adds no routing code.

`cmd_*` parses flags into `opt_*` variables and positionals into `arg_*`, validates them, and calls
`board_call <group>_<action> [args]`. The platform file defines `github_<group>_<action>` and
`gitlab_<group>_<action>`. A missing platform function makes the command exit 3 on that platform by
itself, so a difference between the hosts needs no special case: the function is simply absent.

Validation lives in `cmd_*`, once for both platforms. Platform functions trust their input.

A new command touches, in one commit: its `help_`/`cmd_` pair; the listing in its parent's
`help_` text, which the dispatcher does not generate; the platform functions, named after the full
path (`board request comment add` calls `board_call request_comment_add`, defined as
`github_request_comment_add` and `gitlab_request_comment_add`); and the command table in
README.md. A command one platform cannot do has no
function there and says so under PLATFORM NOTES.

## Output

- Text mode (default) prints the platform CLI's own output, or one plain value per line for
  commands that return a value (an id, a URL, a ref).
- `--json` prints the normalised shape that the command's help describes under OUTPUT. The GitHub
  and GitLab variants of a command emit the same keys with the same types. A value the host does
  not have is `null`, never a missing key, so `jq` filters work unchanged on both.
- Shapes go through `board_emit` or `board_emit_doc`, which also apply the user's `--jq`.
- Statuses of CI objects pass through `normalise_status`: `success`, `failed`, `running`,
  `pending`, `manual`, `canceled`, `skipped`. An unknown status passes through unchanged, so a new
  state shows up as itself instead of looking like success.
- Diagnostics go to stderr as `board: <message>`. stdout carries only the result, so it can be
  captured.

## Exit codes

| Code | Meaning | Raised with |
|---|---|---|
| 0 | Success | — |
| 1 | The host or a tool failed | `board_die`, or the failed command's own code |
| 2 | Wrong usage | `board_usage_die`, `board_unknown_flag`, `board_unexpected` |
| 3 | Not supported on this platform | `board_unsupported`, or no platform function |
| 4 | Not found | `board_not_found`, or `board_capture` seeing "not found", HTTP 404 or 410 |

An agent branches on these codes, so a failure is never turned into exit 0, and "nothing found" is
4 rather than empty output.

## Help

Every command answers `--help` with the sections `NAME`, `USAGE`, `DESCRIPTION`, `ARGUMENTS`,
`FLAGS`, `OUTPUT`, `PLATFORM NOTES` and `EXAMPLES`, in this order. `ARGUMENTS`, `FLAGS` and
`PLATFORM NOTES` are left out when there is nothing to say. `EXIT CODES` and `GLOBAL FLAGS` are
appended by the dispatcher.

The reader is an agent that has not seen the source, so help states what a careless reader would
get wrong: the default when an argument is omitted, the exact JSON shape, and every place where
the two platforms behave differently. `NAME` reads `  board <path> - <summary>`; the skill reference
is generated from it, and `scripts/check-help.sh` fails without it.

## Comments

About one line in ten. A comment says why: the platform quirk being worked around, the reason a
simpler call does not work. The code already says what it does.

## Naming

- `request`, not pull request or merge request, in code, help and docs. `pr` and `mr` are aliases.
- `id` is the number people use: PR number on GitHub, MR iid on GitLab.
- `run` is a GitHub workflow run or a GitLab pipeline; `job` is a job on both.

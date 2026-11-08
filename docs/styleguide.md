# Styleguide

How board code is written, and why. The reviewer's engineer role checks changes against this
document.

## Shell

board is POSIX `sh`. It has to run wherever `/bin/sh` is dash, ash or busybox: Alpine and Debian
images in CI, minimal containers, macOS, Git Bash. A construct that only bash knows works on the
author's machine and fails on the user's.

- Shebang `#!/bin/sh`; library files start with `# shellcheck shell=sh` and are sourced, not run.
- Absent in POSIX, so not used: arrays, `[[ ]]`, `local`, `<<<`, `$'..'`, `${x//a/b}`,
  `${x:0:n}`, `mapfile`, `type -P`, `set -o pipefail`, process substitution.
- Argument lists are built with `set -- "$@" --flag "$value"`.
- Lists of values (labels, users) are newline-separated strings.
- Without `local`, every variable is global. A function names its variables with its own prefix
  (`github_ic_item`), so a callee cannot overwrite its caller's state.
- Without pipefail, `a | b` reports only `b`. A command whose failure matters is captured first:
  `doc=$(github_gql) || return $?`. Only then is the result piped into jq.
- `set -e` is off inside anything called with `||`. So a function checks its own failures
  explicitly and returns a board exit code.
- Never `echo` data: dash interprets `\n` in it. `printf '%s'` only.
- `shellcheck` passes with the settings in `.shellcheckrc`.

### Windows

- A body never goes in argv: Windows stops at about 32,000 characters. Text goes through stdin.
- A temporary path never goes to a native exe: it cannot open `/tmp/...`. Only shell redirects.
- `_jq` is the only way to call jq: it adds `-b`, without which Windows jq writes CRLF.
- `bin/board` turns off Git Bash's rewriting of arguments. Nothing else depends on the shell.

## Layout

| Path | Holds |
|---|---|
| `bin/board` | Finds `BOARD_HOME`, sources the core, calls `board_main` |
| `lib/core/` | Dispatch, global flags, config, running tools, help footer |
| `lib/cmd/<group>.sh` | Help text and flag parsing of one command group, for every board |
| `lib/<kind>/` | One adapter: what the commands do on that board |
| `lib/jq/` | The common model and its text renderings |
| `lib/schema/` | Keys and types of each normalised object |
| `lib/contract.txt` | Every adapter call, and the command it serves |
| `tests/` | Harness, fake provider CLIs, recorded answers |

A command is a pair of functions in `lib/cmd/<group>.sh`: `help_<path>` and `cmd_<path>`, where
`<path>` is the command words joined by `_` (`board issue comment add` is
`cmd_issue_comment_add`). A group has only `help_<path>`. The dispatcher walks the words for as long
as a `help_` function exists for them, so adding a command adds no routing code.

`cmd_*` parses flags, validates them, builds an intent, and calls `board_call <name> [args]` with
the intent on stdin. That is `<kind>_<name>` in the adapter, found by name. The adapter prints
normalised JSON and returns a board exit code. `cmd_*` hands the JSON to `board_output`.

Validation lives in `cmd_*`, once for every board. Adapters trust their input. A board name in
`lib/cmd` outside help fails `scripts/check-contract.sh`.

A new command touches, in one commit: its `help_`/`cmd_` pair; the listing in its parent's `help_`
text and in `help_root`; its line in `lib/contract.txt`; and each adapter, as a function or as a
line in `lib/<kind>/unsupported.txt` with the reason. `scripts/check-contract.sh` fails on anything
missing.

## Adapters

```
lib/<kind>/core.sh          transport, error classification, auth_status, doctor_checks,
                            init_discover, board_list, board_view, api_call
lib/<kind>/<group>.sh       one per command group, loaded when first used
lib/<kind>/shape.jq         answers of the board into the common model
lib/<kind>/queries/*.graphql  one operation per file, named after the file
lib/<kind>/unsupported.txt  <name> <reason>, for a call this board cannot do
```

- Only `core.sh` runs the provider tool, through `board_exec`. Only it decides the exit code: from
  an HTTP status or a GraphQL error type, never from the wording of a message.
- Every provider tool call passes through `board_exec`, so it has a timeout. A write that times out
  has an unknown result: it is exit 6 and it is not retried.
- A multi-step write that fails after its first step is exit 6, through `board_partial`.
- `shape.jq` ends every object in a `make_*` of `lib/jq/common.jq`. That is what guarantees the key
  set. The contract tests compare it with `lib/schema/`.
- Names are compared with `ieq`, the only comparison that handles Cyrillic and regex characters.
- Live facts that shaped the code go in [providers.md](providers.md).
- `--dry-run` stops every write in `board_call`, before its adapter: an adapter needs nothing for
  it. What a dry run can check is what the core can read: the issue, and the status a move reaches.

## Output

- Text mode prints a board-neutral rendering from `lib/jq/text.jq`. It is for people and may change.
- `--json` prints the normalised shape that the command's help describes under OUTPUT. Every board
  emits the same keys with the same types. A value the board does not have is `null` or an empty
  list, never a missing key.
- A list is a plain array. When more exist than `--limit` allows, a warning goes to stderr.
- After a change, text mode prints the URL and JSON mode prints the whole object as it now is.
- Diagnostics go to stderr as `board: <message>`. stdout carries only the result.
- Under `--dry-run` a write prints its plan instead, `lib/schema/plan.json`, and `board_output`
  renders it with `text_plan` whatever filter the command passed.

## Exit codes

| Code | Meaning | Raised with |
|---|---|---|
| 0 | Success | — |
| 1 | The board or a tool failed | `board_die` |
| 2 | Wrong usage | `board_usage_die`, `board_unknown_flag`, `board_unexpected` |
| 3 | Not supported on this board | `board_unsupported`, or no adapter function |
| 4 | Not found | `board_not_found` |
| 5 | Not authenticated, or not allowed | `board_auth_die` |
| 6 | Partial: a write went through and a later step failed | `board_partial` |
| 7 | Conflict: the issue is not in the `--from` status; nothing written | `board_conflict` |

An agent branches on these codes, so a failure is never turned into exit 0, and "nothing found" for
one object is 4 rather than empty output. A list with nothing in it is `[]` and exit 0. A child's
own exit code never passes through: Linear's CLI uses 3 to 5 for other meanings. `board batch` is
the one exception: its children are board, and their codes mean what they say here.

## Help

`--help` is the whole interface for an agent: board ships no skill and no generated reference.
Every command answers with the sections `NAME`, `USAGE`, `DESCRIPTION`, `ARGUMENTS`, `FLAGS`,
`OUTPUT`, `PLATFORM NOTES` and `EXAMPLES`, in this order. `ARGUMENTS`, `FLAGS` and `PLATFORM NOTES`
are left out when there is nothing to say. `EXIT CODES` and `GLOBAL FLAGS` are appended by the
dispatcher.

The reader is an agent that has not seen the source, so help states what a careless reader would
get wrong: the default when an argument is omitted, the exact JSON shape, and every place where the
boards behave differently. `scripts/check-help.sh` fails when a section is missing.

## Comments

About one line in ten. A comment says why: the board quirk being worked around, the reason a simpler
call does not work. The code already says what it does.

## Naming

- `issue`, not task or ticket, in code, help and docs. [terminology.md](terminology.md) has the rest.
- `kind` is linear, jira, github or gitlab. `board` is the thing a kind has.
- `id` is what the board shows and what every command takes. It is always a string.

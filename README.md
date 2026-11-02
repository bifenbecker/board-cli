# board

One command line for task boards: Linear, Jira, GitHub Projects and GitLab.

The same commands, flags and JSON work on every board. A project declares its board in one section
of `workflow.toml`, so moving to another board changes that section and nothing else. It is written
for AI agents, which learn it from `--help`: there is no skill to install.

```sh
board issue list --assignee @me --json
board issue create --title "Login fails" --label bug --priority high
board issue move KAN-1 "In Progress"
board issue comment add KAN-1 --body-file notes.md
```

## Why

An agent working through a project's tasks should not need to know whether they live in Jira or
Linear. Each tracker has its own CLI, its own words, and its own idea of what a status is. A flow
written for one does not run on another. `board` is a facade: it reduces the four boards to what
they have in common, and says plainly where one of them cannot do something.

- One vocabulary: [docs/terminology.md](docs/terminology.md)
- What works where: [docs/capabilities.md](docs/capabilities.md)
- A JSON shape that does not change between boards, enforced by contract tests
- Exit codes an agent can branch on

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/bifenbecker/board-cli/main/install.sh | sh
```

Needs `sh`, `jq`, `curl`, and the login of your board. Works on Linux, macOS and Windows with Git
Bash. `board self update` moves to a newer release.

From cmd.exe or PowerShell, `board` runs through `board.cmd`, and cmd.exe parses its arguments
first. Pass text that holds quotes through `--body-file`, or run `board` from Git Bash.

| Board  | Log in with                                      |
| ------ | ------------------------------------------------ |
| Linear | `linear auth login`, or set `LINEAR_API_KEY`     |
| Jira   | `jira init` and `JIRA_API_TOKEN`, see below      |
| GitHub | `gh auth login`, with the `project` scope        |
| GitLab | `glab auth login --hostname <host>`              |

Jira is reached over its REST API with the login from the jira-cli config. The token goes only to a
host you named outside any repository: the `server` of your own jira-cli config, or a host in
`BOARD_JIRA_HOSTS`. A `workflow.toml` that arrives with a repository cannot send it elsewhere.

A self-hosted GitHub or GitLab needs its host in `BOARD_TRUSTED_HOSTS`, for the same reason: `gh`
and `glab` send a token from the environment to whatever host they are told.

## Quick start

```sh
board init --url https://linear.app/acme/project/roadmap-982b67e1e776/overview
board doctor
board issue list
```

`board init` reads the board behind a URL and writes `[board]` of `workflow.toml`. Check what it
wrote: statuses get a category guessed from their name, and one it cannot place stays commented
out until you declare it.

## Declaring a board

```toml
[board]
kind      = "github"             # linear, jira, github or gitlab
cli       = "gh"
url       = "https://github.com/acme/app"
project   = "#"
issue_uri = "/issues/{ticket}"

[board.target]                   # what only this kind of board needs
owner  = "acme"
number = 5

[board.statuses]                 # GitHub and GitLab only: they have no category of their own
"Todo"        = "todo"
"In Progress" = "in_progress"
"Done"        = "done"
```

`board` looks for `workflow.toml` at or above the working directory; `WORKFLOW_FILE` names another.
Sections other than `[board]` are not read. Secrets never go here.

## Commands

| Command                          | What it does                                               |
| -------------------------------- | ---------------------------------------------------------- |
| `board issue ...`                | list, view, create, edit, move, close, reopen, delete      |
| `board issue comment ...`        | list, add, edit, delete                                    |
| `board issue link ...`           | list, add, remove                                          |
| `board status ...`               | list, add, rename, delete                                  |
| `board label ...`                | list, create, edit, delete, sync                           |
| `board member list`              | who can be assigned                                        |
| `board sprint ...`               | list, view, current                                        |
| `board milestone ...`            | list, view, create, edit, delete                           |
| `board init`, `view`, `list`     | declare the board, show it, list reachable ones            |
| `board doctor`, `capabilities`   | is it working, and what can this board do                  |
| `board api`                      | the board's own API, for what no command covers            |

`board <command> --help` gives the exact flags, the JSON shape and how each board differs. That help
is the documentation.

## Output

`--json` prints the normalised shape, and `--jq <expr>` filters it. A value the board does not have
is `null` or an empty list, never a missing key. Text output is for people and may change.

```json
{
  "id": "KAN-1", "kind": "jira", "url": "https://...",
  "title": "Login fails", "description": "...", "type": "Task",
  "status": {"name": "In Progress", "category": "in_progress"},
  "assignees": [{"id": "...", "name": "..."}],
  "labels": ["bug"], "priority": "high",
  "parent": null, "subtasks": [], "links": [],
  "sprint": null, "milestone": null, "due_date": null,
  "author": {"id": "...", "name": "..."},
  "created_at": "2026-11-01T12:00:00Z", "updated_at": "2026-11-01T12:30:00Z"
}
```

## Exit codes

| Code | Meaning                                                                         |
| ---- | ------------------------------------------------------------------------------- |
| 0    | Success                                                                         |
| 1    | The board or a tool failed                                                      |
| 2    | Wrong usage                                                                     |
| 3    | This board cannot do it                                                         |
| 4    | Not found                                                                       |
| 5    | Not authenticated, or not allowed                                               |
| 6    | Partial: a write went through and a later step failed. The id is on stdout      |

## For agents

Tell the agent the tool exists. One line in the project's `CLAUDE.md` is enough:

```
Board tasks: use `board`, see `board --help`.
```

`board --help` tells it where to start, how to read results and what to do on each exit code.

## Contributing

`just` lists every task. [docs/index.md](docs/index.md) lists the documents, starting with
[docs/styleguide.md](docs/styleguide.md). `just check` runs the static checks and the tests against
fake provider CLIs. `just live <kind>` runs one scenario against a real test board.

## License

MIT

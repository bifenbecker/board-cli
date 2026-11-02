# Providers

Facts about each board's tools and API, measured on the real test boards. Adapters rest on these;
when one stops being true, fix it here too.

Test targets: Linear workspace `3kd` (team `3KD`, project `Test`), Jira Cloud project `KAN`
(team-managed, board 1), GitHub user project 5 of `bifenbecker`, GitLab
`bulgakovra.w/test-board-cli` (Free tier).

## All boards

- Git Bash: a native exe cannot open a `/c/...` path once `MSYS_NO_PATHCONV=1` is set, and it never
  can open a `/tmp/...` one. Keep paths away from native exes: use shell redirects.
- Windows `jq` writes CRLF without `-b`. A `\r` in a variable breaks every later comparison.
- Windows `jq` reads `env.X` in the ANSI code page: Cyrillic comes out as `??????`. Values go in
  with `--arg`.
- `$(...)` strips trailing newlines, so a description loses its trailing blank lines.
- Argument length stops at about 32,000 characters on Windows. Bodies go through stdin.

## GitHub

Tool: `gh`, tested on 2.96.0. Needs the `project` scope.

- Issue and project item are separate objects. Status is a single-select value on the item.
- `createIssue` accepts `projectV2Ids`, but the item is added **after** the mutation returns:
  `projectItems` is empty in its response. Read it again before setting a status.
- With the "Item added to project" workflow on, the new item gets `Todo` a moment later.
- With the default workflows on:
  - Setting `Done` closes the issue within about 5 seconds.
  - `gh issue reopen` leaves the status at `Done`. Set the status explicitly after a reopen.
  - Closing as `not planned` from `In Progress` still sets `Done`. A `canceled` status set before
    the close can be overwritten: close first, wait, then set it, or accept `Done`.
  - Workflow names and `enabled` are readable; their rules are not.
- `updateProjectV2Field` with `singleSelectOptions` replaces the whole set. Options resent with
  their `id` keep their id and their items; an option left out is removed.
- `items(query:"status:Done")` filters on the server and `totalCount` follows the filter.
- A failed GraphQL query exits 1 and prints JSON on stdout, with `errors[].type` (`NOT_FOUND`).
- `gh project item-list --limit` truncates silently. Use GraphQL.
- The project query language has wildcards (`*`), OR (`,`) and no working escape for `"`, and its
  free text reads `status:Done` as a qualifier and never searches the body. Use it to cut pages,
  and decide on the client.
- `POSITION` is the only order of project items.
- A PATCH with `labels` replaces the set from a read that may be stale. Add and remove through
  their own endpoints. `DELETE .../labels/<name>` answers 404 for a label the issue lacks.
- REST `type` is dropped without a word on a repository with no issue types (all user-owned ones).
- `labels(first:)` and the like stop at 100, and a read that stops early looks complete.

## GitLab

Tool: `glab`, tested on 1.110.0. Always pass `--hostname`: glab may also be logged in elsewhere.

- `glab api --input -` needs `-H 'Content-Type: application/json'`, otherwise HTTP 415.
- `glab api graphql` limits a query to complexity 250. Boards with their lists exceed it: read
  them over REST (`projects/:id/boards`).
- A new project has a board `Development` with no lists; `Open` and `Closed` are implicit.
- REST `PUT projects/:id/issues/:iid` takes `add_labels`, `remove_labels` and `state_event` in one
  atomic call. Unknown labels are created.
- Closing keeps the labels. Reopening puts the issue back in its old list.
- `link_type=blocks` answers HTTP 403 `Blocked issues not available for current license`.
  `relates_to` works on Free.
- Pagination headers: `X-Next-Page`, `X-Total`, `X-Per-Page`, seen with `glab api -i`.
- Notes include system notes: filter on `system == false`.
- `glab api` errors end in `(HTTP <code>)` on stderr and print the JSON body on stdout. A bad token
  is 401. A missing issue is 404. `glab api graphql` exits 0 with `project: null` when the project
  is missing or private: check for it.
- Work item types on Free: Incident, Issue, Task, Ticket.
- The canonical issue URL is `/-/work_items/<iid>`.

## Linear

Tool: `linear` (schpet/linear-cli), tested on 2.5.0. npm `latest` is a Rust rewrite with different
exit codes, so nothing depends on them: only `linear api` is used, and its JSON body is read.

- `linear api -` reads the query from stdin. Variables exist only in argv, so input objects are
  written into the query as literals.
- Errors: not found exits 1 with JSON on **stdout**; an invalid query exits 1 with JSON on
  **stderr**. Read both. `extensions.code` is `AUTHENTICATION_ERROR` or `INPUT_ERROR`;
  `message` is `Entity not found: Issue` when missing.
- `issue(id:)` accepts the identifier (`3KD-13`) as well as the UUID.
- `state.type` values include `duplicate`, on top of `triage backlog unstarted started completed
  canceled`.
- `description` is normalised by Linear: `- a` comes back as `* a`.
- A new issue lands in the team's default state, `Backlog` here, not `Todo`.
- `workflowStateCreate` works. `workflowStateArchive` fails with `INPUT_ERROR` while issues are in
  the state; there is no delete.
- Rate limit: 2,500 requests and 3,000,000 complexity per hour for an API key.

## Jira

Reached over REST with `curl`, using the login from the jira-cli config and `JIRA_API_TOKEN`, else
`~/.netrc`.
`jira` itself is not called: it has no raw API, hides failures behind `No result found`, and has
no command for statuses, transitions, priorities or users.

- REST v2 works on Cloud and Data Center. Descriptions and comments are wiki markup on both.
  v3 would add ADF on Cloud only.
- Rich content written elsewhere comes back through v2 as wiki: `{panel:bgColor=#deebff}`,
  `||H||`, `[~accountid:...]`.
- Search on Cloud: `/rest/api/2/search/jql`, paged by `nextPageToken`, with `isLast`.
  Data Center: `/rest/api/2/search`, paged by `startAt`.
- A bad token on Cloud does not look like one. A read is **HTTP 404**, the same as a missing issue,
  and a write is **HTTP 400** `The target project doesn't exist`. A **search is HTTP 200** with
  `{"issues":[],"isLast":true}`, the same as no results. Only `/rest/api/2/myself` answers 401. On a
  404, a 400 or an empty first page of a search, call it to tell them apart.
- A value JQL does not know is not an error on Cloud: `status = "nope"` and `sprint = "x"` answer 200
  with no issues, even on a site with no sprint field.
- `~` takes Lucene: bare, `NOT x` and `x OR y` are operators, and `a(b` finds nothing. board quotes
  each word, `"NOT" "x"`, so free text stays text. Quoted words are not yet measured on a live
  site: `just live jira` proves them. JQL strings take the escapes of JSON, so `tojson` writes one.
- `PUT /issue` with an `issuetype` the project does not have changed nothing and answered 2xx in
  review, so a type is checked against `issueTypes` of `/project/<key>` before any write.
- A transition is `POST /issue/<key>/transitions`. `GET` lists them with `to.name` and
  `to.statusCategory.key`. Team-managed projects allow any status from any status.
- `POST /issue` needs `project`, `issuetype` and `summary`. `Priority` defaults to `Medium`.
- `editmeta` and `createmeta` do not say what can be set: on KAN they leave out `priority` and
  `fixVersions`, and both are accepted, on create and on edit.
- `priority: null` is **HTTP 400** on Cloud: `Specify the Priority (id or name)`. An issue always
  has one.
- A sub-task sets `parent` and an issue type with `subtask: true`.
- A parent must be one level up (`hierarchyLevel`: Epic 1, Task 0, Subtask -1). A Task under a Task
  is HTTP 400 on `errors.pid`, with `Subtask` in the same `PUT` too. `PUT` cannot change an issue
  between levels, and it cannot clear a subtask's parent: `You can not remove a subtask's parent`.
- `POST /rest/api/2/bulk/issues/move` does both, on Cloud. The target is the key
  `KAN,<type id>,<parent>`, or `KAN,<type id>` back to a level of its own. It answers `taskId`;
  `GET /rest/api/2/task/<id>` reaches `COMPLETE` in under a second on KAN, with `failedIssues`. The
  issue keeps its key and status. Data Center has no such API.
- `POST /issueLink` with `inwardIssue` A and `outwardIssue` B reads on A as an `outwardIssue` B:
  **A blocks B**. Posting a link twice is 201 and adds nothing.
- `update.labels` takes `add` and `remove` in one `PUT`, and removing a label that is not there is
  fine. A label stays in `GET /rest/api/2/label` for a while after its last issue is gone.
- Board type `simple` has no sprints: `The board does not support sprints`, HTTP 400. KAN's site has
  no sprint field at all in `/rest/api/2/field`; the field is found by `schema.custom`
  `com.pyxis.greenhopper.jira:gh-sprint`, since its id differs per site.
- Timestamps carry an offset (`2026-11-02T01:04:07.800+1100`). Normalise them to UTC.
- Cloud has no usernames: an assignee is an `accountId`. `user/assignable/search` takes `query`;
  Data Center takes `username`. It is a bare array with no total.
- Link types on KAN: `Blocks`, `Cloners`, `Duplicate`, `Relates`.
- Labels are free text and appear when first used. `GET /rest/api/2/label` lists them on Cloud.
- `/project/KAN/statuses` repeats the same list under each issue type, in the order `Done`,
  `In Progress`, `To Do`, `In Review`. The board's column order comes from
  `/rest/agile/1.0/board/<id>/configuration`, which names statuses by id.

### curl

`curl -K -` takes its whole configuration from stdin, so token and body stay out of argv. A body
is written as `data-binary = <JSON string>`, which `jq -Rrs tojson` produces. The `-r` matters:
without it the value is encoded twice and Jira answers `Invalid request payload`.

- A config value in double quotes reads the escapes `\\`, `\"`, `\t`, `\n`, `\r`; any other backslash
  just drops. A compact JSON body has no raw control characters, so it is safe.
- `data-binary` reads a file when the value starts with `@`. `board api` therefore takes JSON only.
- Without `globoff`, `[` and `{` in a URL are curl's own ranges and sets.
- curl does not follow a redirect unless asked, so the token cannot be carried to another host.
  `-q` must be its first argument, or `~/.curlrc` is read and a `location` there asks.
- Once a request may have left, its result is unknown. Only a failure before that is a plain failure:
  exit codes 5, 6, 7 (proxy, DNS, connect), 35 and 60 (TLS). Everything else on a write is exit 6.

### Wiki text

- jq compiles a regex on every call, near 50 microseconds here, so the cost of a body is its lines of
  markup. Plain lines take none. A line over 3,000 characters or a text over 3,000 lines of markup
  goes out as it came, with a warning: 32 KB of the worst text then converts in about a second.
- `{code}` and `{noformat}` close only on their own delimiter, and nothing inside can be escaped. A
  block holding `{code}` goes out as `{noformat}`, which has no language.
- Literal text that wiki would read as markup goes out escaped: `\h1.`, `\-x\-`, `\+x\+`, `a\|b` in a
  table cell or a link text, and `&#92;` for a literal backslash pair, since `\\` is a line break.
  `}` that would end `{{...}}` goes out as `&#125;`. These are written to the wiki rules and proved by
  round trip here; how a live site renders the entities is not yet measured.

### Trust

The token goes only to a host the user named outside the repository: `server` in
`JIRA_CONFIG_FILE`, else in `~/.config/.jira/.config.yml`, or a word of `BOARD_JIRA_HOSTS`. A
relative `JIRA_CONFIG_FILE` does not count: it is read from where board runs, which is a repository.
The host is compared whole, port included, ignoring case. `[board] url` cannot add a host, and neither
can `[board] config`: that file may give `login`, `auth_type` and `installation`, and its `server`
is ignored. The user's config gives `auth_type` and `installation` only for its own host, since it
says nothing about another site; its `login` serves any trusted host. Plain `http` needs `http://`
in `server`, or a repository could strip TLS from a trusted host.

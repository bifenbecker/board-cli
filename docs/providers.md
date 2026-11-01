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

Reached over REST with `curl`, using the login from the jira-cli config and `JIRA_API_TOKEN`.
`jira` itself is not called: it has no raw API, hides failures behind `No result found`, and has
no command for statuses, transitions, priorities or users.

- REST v2 works on Cloud and Data Center. Descriptions and comments are wiki markup on both.
  v3 would add ADF on Cloud only.
- Rich content written elsewhere comes back through v2 as wiki: `{panel:bgColor=#deebff}`,
  `||H||`, `[~accountid:...]`.
- Search on Cloud: `/rest/api/2/search/jql`, paged by `nextPageToken`, with `isLast`.
  Data Center: `/rest/api/2/search`, paged by `startAt`.
- A bad token on Cloud is **HTTP 404**, the same as a missing issue, not 401. On a 404, call
  `/rest/api/2/myself` to tell them apart.
- A transition is `POST /issue/<key>/transitions`. `GET` lists them with `to.name` and
  `to.statusCategory.key`. Team-managed projects allow any status from any status.
- `POST /issue` needs `project`, `issuetype` and `summary`. `Priority` defaults to `Medium`.
- A sub-task sets `parent` and an issue type with `subtask: true`.
- Board type `simple` has no sprints: `The board does not support sprints`.
- Timestamps carry an offset (`2026-11-02T01:04:07.800+1100`). Normalise them to UTC.
- Cloud has no usernames: an assignee is an `accountId`.
- Link types on KAN: `Blocks`, `Cloners`, `Duplicate`, `Relates`.
- Labels are free text and appear when first used. `GET /rest/api/2/label` lists them on Cloud.

### curl

`curl -K -` takes its whole configuration from stdin, so token and body stay out of argv. A body
is written as `data-binary = <JSON string>`, which `jq -Rrs tojson` produces. The `-r` matters:
without it the value is encoded twice and Jira answers `Invalid request payload`.

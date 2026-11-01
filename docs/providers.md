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
  written into the query as literals. A 70 KB description went through this way. An enum literal
  takes no quotes: `type: blocks`.
- `linear api --workspace <slug>` picks one of several logins, and fails with a line of text on
  stderr when that login is missing. The tool refuses the flag when `LINEAR_API_KEY` is set.
- Errors: not found exits 1 with JSON on **stdout**; an invalid query exits 1 with JSON on
  **stderr**. Read both. `extensions.code` is `AUTHENTICATION_ERROR` or `INPUT_ERROR`;
  `message` is `Entity not found: Issue` when missing, but `issue not found` for a bad `parentId`.
  `extensions.userPresentableMessage` is the better text for a person.
- With no login at all there is no JSON: one line on stderr that ends in `linear auth login`.
- `issue(id:)` accepts the identifier (`3KD-13`) as well as the UUID. So do `issueUpdate(id:)`,
  `issueDelete(id:)`, `parentId`, `commentCreate`'s `issueId`, both ids of `issueRelationCreate`, and
  the filter `parent: {id: {eq: "3KD-13"}}`.
- `team(id:)` accepts the key. `project(id:)` accepts the `slugId`, the last part of the project's
  URL slug. `teamId` and `projectId` in an input must be UUIDs.
- `state.type` values include `duplicate`, on top of `triage backlog unstarted started completed
  canceled`.
- `team.states` comes back in no useful order: sort by type, then `position`.
- `description` is normalised by Linear: `- a` comes back as `* a`, and the line after a list item
  gets indented.
- A new issue lands in the team's default state, `Backlog` here, not `Todo`.
- A sub-issue does not follow its parent into a project: `projectId` must be set on it too.
- `issueDelete` moves the issue to the trash. `issue(id:)` still answers, with `trashed: true`, and
  `issueUpdate` still works on it. Deleting twice succeeds. `permanentlyDelete: true` removes it at
  once, and only then is the issue not found.
- Two issues hold one relation at a time, whichever way round. A second `issueRelationCreate` of
  the same type returns the first relation; one of another type replaces it. `duplicate` also moves
  the issue to the `Duplicate` state, and deleting the relation moves it back.
- `team.labels` holds the team's labels and the workspace's. `issueLabelCreate` of a name that
  exists in either fails with `INPUT_ERROR`. A label needs no color: Linear picks one.
- `workflowStateCreate` works and needs a color. `workflowStateArchive` fails with `INPUT_ERROR`
  while issues are in the state; there is no delete. An archived state stays, visible only with
  `includeArchived`, and its name can be used again.
- Cycles are a team setting, `cyclesEnabled`, and a cycle often has `name: null`. A new team's first
  cycle starts next week, so nothing is active at first.
- A project milestone has a read-only `status`: `next` while its issues are open, `done` once they
  all are. A milestone with no issues stays `next`.
- `containsIgnoreCase` and `eqIgnoreCase` are exact text comparisons: `_` and `%` match only
  themselves, and case folds in Cyrillic too. So search, label and milestone names can be left to
  the server. A top-level `or` in a filter is ANDed with the keys beside it.
- A read can show the state from before a write that already reported success. Seen on 3KD-59: the
  mutation returned at 21:24:37.9 with `updatedAt` .789, and `issue(id:)` at 21:24:41 to :43 and
  again later still answered with the old labels and the old `updatedAt`; a read at :58 was right.
  About one `issue edit` in twenty-five did this on a loaded client (5 of about 120), and none of
  300 raw update-then-read pairs did, with reads 1 to 20 seconds after the write. The cause is not
  known. So a write waits for a read that has caught up: an issue write returns the new
  `updatedAt`, and an equal or later one in the read proves it. A no-op update leaves `updatedAt`
  as it was. A relation does not touch it, so the link itself is what to wait for.
- The same lag can reach a read made just before a write. It cannot be avoided for
  `removedLabelIds`, which is why that list comes from the issue: naming a label the issue lacks
  fails the whole mutation with `Label not on issue`.
- `first:` on a nested connection stops there without a word. The list reads 50 labels per issue,
  because 250 on 100 issues is a lot of complexity; a single issue reads 250 of everything.
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

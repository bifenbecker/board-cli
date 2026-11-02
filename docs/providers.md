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
- `glab api` prints the JSON body on stdout and exits 1 on an error. A bad token is 401. A missing
  issue is 404. `glab api graphql` exits 0 with `project: null` when the project is missing or
  private: check for it.
- The HTTP code on stderr comes in three forms: `glab: <message> (HTTP <code>)`; `glab: HTTP <code>`
  when the body says `error` instead of `message`; and `glab: map[message:map[...]]+`, with no code
  at all, when `message` is an object of validation errors.
- `glab api graphql` drops the code too: a bad token is exit 1, `{"errors":[{"message":"Invalid
  token"}]}`, and `glab: Invalid token`. Ask `user` to tell it from a bad query.
- A host glab has no login for prints a framed `Unauthenticated.` with no code. It says the same for
  a host that does not exist: it never gets as far as the network.
- Work item types on Free: Incident, Issue, Task, Ticket.
- The canonical issue URL is `/-/work_items/<iid>`, and `web_url` already is that.
- Scoped labels need a paid tier: on Free `status::todo` is a plain label, and GitLab does not make
  it exclusive. Labels are case-sensitive. A name cannot hold a comma, so a comma list is safe.
- `state_event: close` on a closed issue and `reopen` on an open one answer 200 and change nothing.
- `due_date: null`, `milestone_id: 0` and `assignee_ids: []` clear a field. Assignees are numeric
  ids, the whole list at once.
- A work item's global id is `gid://gitlab/WorkItem/<id>`, with the REST `id`, not the `iid`.
- `allowedParentTypes` on the `HIERARCHY` widget of `workItemTypes` states the rule. On Free a Task
  can sit under an Incident, Issue or Ticket, and an Issue under nothing. `workItemUpdate` refuses
  anything else with exit 0 and text in the payload: `errors: ["#5 cannot be added: it's not allowed
  to add this type of parent item"]`, so ask first. `parentId: null` clears a parent, and succeeds
  when there is none.
- A line of a description or a note that starts with `/` runs as a quick action: `/close` closes
  the issue, and the line is gone from the text. A note made only of actions answers with no `id`,
  and a note edited to `/close` is deleted. `\/close` is stored as text and renders as `/close`.
  With 1 to 4 spaces before it a note did not run on gitlab.com; the adapter escapes up to 3 anyway,
  which reads back the same.
- Labels are matched exactly: a write in another case creates a second label, and `remove_labels` in
  another case does nothing, both with exit 0.
- In a list, `labels=Any` and `labels=None` are keywords, and a comma splits a name in two.
  `milestone=` is case-sensitive and has the keywords `Any` and `None`, and `Upcoming` and `Started`
  by the API documentation; those two were accepted, but could not be told apart here.
- `glab api -i` prints `HTTP/2.0 200 OK`, the headers, a blank line and the body, on stdout, also on
  an error. `X-Next-Page` is empty on the last page, so a full page can be told from one that has
  more.
- REST creates a Task with `issue_type: task` but refuses to change an Issue to one: `can not be
  changed to Task`. `workItemConvert` does it, and then the Issue can have a parent.
- Links: `target_project_id` must be the numeric id; the encoded path that works in a URL is `404
  Project Not Found`. A second link between two issues, in either direction, is 409 `Issue(s) already
  assigned`. `references.relative` is `#9` for an issue of the same project.
- Iterations on Free: REST `projects/:id/iterations` is a bare `403 Forbidden`, with nothing about a
  license, so it reads like a missing permission. No work item type has an `ITERATION` widget: ask
  `workItemTypes`.
- `POST labels` requires `color`. A label created by first use gets `#6699cc`.
- Renaming a label keeps its list. Deleting a label deletes its list. A second list for one label
  is `Label has already been taken`.
- `projects/:id/milestones/:id` takes the global `id`, while the URL of a milestone shows the `iid`.
- An iid is not reused after its issue is deleted.

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
- With no login at all there is no JSON: two lines on stderr, and `linear auth login` is only in the
  second. A login missing for `--workspace` is one line that names it.
- Every measured refusal has `extensions.userError: true`. Without it, a failed mutation may have
  gone through.
- The id comparator of a filter refuses anything but a UUID with `Argument Validation Error`.
  `assignee: {or: [{name: ...}, {displayName: ...}]}` finds people outside the team as well.
- A root field names itself in `errors[].path`: `project` or `team` tells which setting is wrong.
- `comment(id:)` answers `Entity not found: Comment` for a word as for a UUID, and its `issue` is
  null when the comment hangs on something else.
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
- A label name takes 80 characters. Longer is `Argument Validation Error`.
- Two states may share a name when their types differ: `Cannot create a duplicate workflow state`
  only comes for the same name and type.
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

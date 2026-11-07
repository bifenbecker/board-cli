# Terminology

One word for one thing, in code, help and JSON. "Issue" is the neutral noun: all four services use
it, while "task" is an issue type on two of them.

| board     | Linear           | Jira                | GitHub                              | GitLab                     |
| --------- | ---------------- | ------------------- | ----------------------------------- | -------------------------- |
| board     | Team             | Project + Board     | ProjectV2 + repository              | Project + issue board      |
| issue     | Issue            | Issue, any type     | Issue on a ProjectV2 item, or draft | Issue                      |
| id        | `3KD-13`         | `KAN-1`             | `12`, `owner/repo#12`, `PVTI_...`   | `42` (iid)                 |
| status    | WorkflowState    | Status              | Option of the `Status` field        | List label + open/closed   |
| category  | `state.type`     | `statusCategory`    | `[board.statuses]`                  | `[board.statuses]`         |
| move      | set `stateId`    | transition          | set field, sometimes close          | swap labels, `state_event` |
| history   | `history`        | changelog           | `ProjectV2ItemStatusChangedEvent`   | label and state events     |
| priority  | 0-4              | Priority            | single-select field                 | label                      |
| sprint    | Cycle            | Sprint              | Iteration field                     | Iteration (Premium)        |
| milestone | ProjectMilestone | Version             | Milestone                           | Milestone                  |
| parent    | parent           | parent              | parent                              | Hierarchy parent           |
| subtask   | child            | Sub-task            | sub-issue                           | child Task                 |
| link      | IssueRelation    | IssueLink           | blockedBy, duplicateOf              | Linked item                |
| comment   | Comment          | Comment             | IssueComment                        | Note, not a system one     |
| type      | none             | Issue type          | Issue type (organisations)          | Work item type             |
| member    | User             | User                | login                               | username                   |
| author    | creator          | reporter            | author                              | author                     |

## Status categories

Every status belongs to one category, the part of a status that means the same on every board.

| category      | Linear                     | Jira            |
| ------------- | -------------------------- | --------------- |
| `todo`        | triage, backlog, unstarted | `new`           |
| `in_progress` | started                    | `indeterminate` |
| `done`        | completed                  | `done`          |
| `canceled`    | canceled, duplicate        | none            |

GitHub and GitLab have no such concept, so `[board.statuses]` declares it. On Jira and Linear the
same table overrides the native category, which is how Jira gets `canceled`. A status with no
category reads as `category: null`, and `board doctor` fails until it is declared: board never
guesses, because a wrong `done` is worse than none.

## History

`board issue history` lists the **moves** of an issue: each change of its status, with `from`,
`to`, `at` and `by`. **since** is when the issue entered the status it is in. A **plan** is what a
write prints under `--dry-run` in place of its result.

## Priorities

`urgent`, `high`, `medium`, `low`, `none`.

| priority | Linear | Jira            |
| -------- | ------ | --------------- |
| `urgent` | 1      | Highest         |
| `high`   | 2      | High            |
| `medium` | 3      | Medium          |
| `low`    | 4      | Low, Lowest     |
| `none`   | 0      | no value        |

GitHub and GitLab declare theirs in `[board.priority]`: the value is the field option or label name.

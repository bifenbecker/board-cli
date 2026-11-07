# Capabilities

What works where. `board capabilities --json` answers the same question at run time, and a command
a board cannot do exits 3. "Declared" means it needs a table in `[board.*]` of `workflow.toml`.
"Premium" means a paid GitLab tier; on Free it exits 3.

| Capability                         | Linear        | Jira          | GitHub                  | GitLab                 |
| ---------------------------------- | ------------- | ------------- | ----------------------- | ---------------------- |
| list, view, search, my issues      | yes           | yes           | yes                     | yes                    |
| status history                     | yes           | yes           | yes; drafts: since only | yes, declared          |
| create, edit, delete               | yes           | yes           | yes                     | yes                    |
| move, close, reopen                | yes           | yes           | yes, declared           | yes, declared          |
| assignees                          | one           | one           | several                 | one; several Premium   |
| labels on an issue                 | yes           | yes           | yes                     | yes                    |
| comments                           | yes           | yes           | yes, not on drafts      | yes                    |
| priority                           | yes           | yes           | declared                | declared               |
| due date                           | yes           | yes           | declared                | yes                    |
| type                               | no            | yes           | organisations only      | yes                    |
| parent, subtasks                   | yes           | yes           | yes                     | yes                    |
| link relates                       | yes           | yes           | yes                     | yes                    |
| link blocks                        | yes           | yes           | yes                     | Premium                |
| link duplicates                    | yes           | yes           | yes                     | no                     |
| sprint read and assign             | yes           | scrum boards  | declared                | Premium                |
| milestone                          | needs project | yes           | yes                     | yes                    |
| members                            | yes           | yes           | yes                     | yes                    |
| board list, view                   | yes           | yes           | yes                     | yes                    |
| status list                        | yes           | yes           | yes                     | yes, declared          |
| status add, rename, delete         | yes           | no            | yes                     | yes                    |
| label list                         | yes           | yes on Cloud  | yes                     | yes                    |
| label create, edit, delete         | yes           | no            | yes                     | yes                    |

Jira cannot change statuses or labels through a portable API: statuses belong to workflows that
differ by project type and need an admin, and a label exists once an issue carries it.

`--dry-run`, `--from` and `board batch` work on every board: the core builds them from the other
commands.

Later: sprint create and close, archive, watchers, external links, bulk edit.

Left out on purpose: epics as their own object (use `parent` and `type`), time tracking, custom
fields, estimates. Each exists on too few boards, or means something different on each.

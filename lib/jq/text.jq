# Text renderings of the normalised objects. For people: --json is the stable interface.

def dash: if . == null or . == "" then "-" else tostring end;

def text_any:
    if type == "string" then .
    elif type == "array" then map(if type == "object" then tojson else tostring end) | join("\n")
    else tojson end;

def text_url: .url // .id;

def text_issue_row: "\(.id)\t\(.status.name | dash)\t\(.title | dash)";

def text_issues: .[] | text_issue_row;

def text_plan:
    "dry run: board \(.command) \(.args | join(" "))",
    (if .issue then "issue:  " + (.issue | text_issue_row) else empty end),
    (if .status then "status: \(.status.name | dash) (\(.status.category | dash))" else empty end),
    "nothing was changed";

def text_issue:
    "\(.id)  \(.title | dash)",
    "status:     \(.status.name | dash) (\(.status.category | dash))",
    "assignees:  \(.assignees | map(.name) | join(", ") | dash)",
    "labels:     \(.labels | join(", ") | dash)",
    "priority:   \(.priority | dash)",
    "type:       \(.type | dash)",
    "parent:     \(.parent | dash)",
    "subtasks:   \(.subtasks | join(", ") | dash)",
    "sprint:     \(.sprint | dash)",
    "milestone:  \(.milestone | dash)",
    "due:        \(.due_date | dash)",
    "url:        \(.url | dash)",
    (if .description then "", .description else empty end),
    (if .comments then (.comments[] | "", "--- \(.author.name | dash), \(.created_at | dash)", .body) else empty end);

def text_batch:
    .[] | "\(.exit // "-")\t\(.args | join(" "))\t\(
        if .exit == null then "not run"
        elif .exit != 0 then (.error // "" | split("\n")[0])
        elif (.result | type) == "object" then
            (if .result.dry_run then "dry run" else (.result.url // .result.id // .result.name // "ok") end)
        elif (.result | type) == "array" then "\(.result | length) items"
        else (.result // "ok" | tostring) end)";

def text_history:
    "\(.id)\t\(.status.name | dash)\tsince \(.since | dash)",
    (.moves[] | "\(.at | dash)\t\(.from.name | dash) -> \(.to.name | dash)\t\(.by.name | dash)");

def text_comments: .[] | "\(.id)  \(.author.name | dash), \(.created_at | dash)", .body, "";

def text_links: .[] | "\(.type)\t\(.id)";

def text_statuses: .[] | "\(.name)\t\(.category | dash)";

def text_labels: .[] | .name;

def text_members: .[] | "\(.id)\t\(.name)";

def text_sprint: "\(.id)\t\(.state)\t\(.name)\t\(.start_date | dash) .. \(.end_date | dash)";

def text_sprints: .[] | text_sprint;

def text_milestone: "\(.id)\t\(.state)\t\(.name)\t\(.due_date | dash)";

def text_milestones: .[] | text_milestone;

def text_boards: .[] | "\(.id)\t\(.name)\t\(.url | dash)";

def text_board:
    "\(.name) (\(.kind))  \(.url | dash)",
    "",
    (.columns[] | "\(.name): \(.statuses | join(", "))");

def text_auth:
    if .authenticated then "\(.kind): logged in as \(.user) on \(.host)"
    else "\(.kind): not logged in on \(.host)" end;

def text_capabilities:
    "supported on \(.kind):", (.supported[] | "  \(.)"),
    (if (.unsupported | length) > 0 then
        "not supported:", (.unsupported[] | "  \(.command): \(.reason)")
     else empty end);

def text_doctor:
    "board \(.version)",
    "file:       \(.file | dash)",
    "board:      \(.kind | dash)  \(.url | dash)",
    "login:      \(if .authenticated then "\(.user)" else "no" end)",
    (.tools | to_entries[] | "tool:       \(.key) \(if .value then "ok" else "MISSING" end)"),
    (.warnings[] | "warning:    \(.)"),
    (.errors[] | "error:      \(.)"),
    (if .ok then "ok" else "problems found" end);

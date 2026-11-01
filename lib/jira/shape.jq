# Jira answers into the common model, and intents into Jira requests. Adapters prepend this file
# through $BOARD_LIB, after lib/jq/common.jq and the converters.

def jira_user:
    if . == null then null
    else {id: (.accountId // .name // .key), name: (.displayName // .name // .accountId)} end;

def jira_status:
    {id, name, native: ({new: "todo", indeterminate: "in_progress", done: "done"}[.statusCategory.key // ""])};

def jira_priority:
    {Highest: "urgent", High: "high", Medium: "medium", Low: "low", Lowest: "low"}[. // ""];

def jira_priority_name:
    {urgent: "Highest", high: "High", medium: "Medium", low: "Low"}[.];

# Read from the side of the issue asked about. A link type outside the model, Cloners on KAN, still
# relates two issues, and hiding it would hide what 'link remove' can take away.
def jira_link_type:
    .type.name as $name
    | if ($name | ieq("Blocks")) then (if .outwardIssue then "blocks" else "blocked-by" end)
      elif ($name | ieq("Duplicate")) then (if .outwardIssue then "duplicates" else "duplicated-by" end)
      else "relates" end;

def jira_links:
    map({link: .id, type: jira_link_type, id: (.outwardIssue // .inwardIssue).key});

# Cloud gives objects. Data Center gives a toString: ...Sprint@1f[id=1,state=ACTIVE,name=S 1,...].
def jira_sprint_of:
    map(if type == "object" then {name, state}
        else {name: (capture("[,\\[]name=(?<v>[^,\\]]*)").v),
              state: (capture("[,\\[]state=(?<v>[^,\\]]*)").v | ascii_downcase)} end)
    | (map(select(.state == "active")) + map(select(.state == "future")) + reverse)[0].name;

def jira_issue($cfg; $base; $sprint):
    .fields as $f
    | {id: .key, kind: "jira", url: "\($base)/browse/\(.key)",
       title: $f.summary,
       description: ($f.description | if . == null then null else wiki2md end),
       type: $f.issuetype.name,
       status: (if $f.status then ($f.status | jira_status) else null end),
       assignees: [$f.assignee | select(. != null) | jira_user],
       labels: ($f.labels // []),
       priority: ($f.priority.name | jira_priority),
       parent: $f.parent.key,
       subtasks: [($f.subtasks // [])[].key],
       links: (($f.issuelinks // []) | jira_links | map({type, id})),
       sprint: (if $sprint == "" then null else (($f[$sprint] // []) | jira_sprint_of) end),
       milestone: (($f.fixVersions // [])[0].name),
       due_date: $f.duedate,
       author: (($f.reporter // $f.creator) | jira_user),
       created_at: $f.created,
       updated_at: $f.updated}
    | make_issue($cfg);

def jql_str: tostring | tojson;

# Lucene's operators, so free text stays text. Data Center refuses a bare one.
def lucene: gsub("(?<c>[+\\-&|!(){}\\[\\]^~*?:\\\\/\"])"; "\\\(.c)");

def jira_category_clause:
    {open: "statusCategory != done", todo: "statusCategory = new",
     in_progress: "statusCategory = indeterminate", done: "statusCategory = done"}[.];

def jira_priority_clause:
    if . == "none" then "priority is EMPTY"
    elif . == "low" then "priority in (\"Low\", \"Lowest\")"
    else "priority = \(jira_priority_name | jql_str)" end;

# Declared statuses move a status between categories, which JQL cannot know: jira_keep decides then.
def jira_jql($cfg; $project):
    . as $f
    | (($cfg.statuses // {}) | length == 0) as $native
    | ["project = \($project | jql_str)"]
      + (if $f.status then ["status = \($f.status | jql_str)"]
         elif $native and ($f.category | jira_category_clause) then [$f.category | jira_category_clause]
         else [] end)
      + (if $f.assignee == null then []
         elif $f.assignee == "@me" then ["assignee = currentUser()"]
         elif $f.assignee == "none" then ["assignee is EMPTY"]
         else ["assignee = \($f.assignee | jql_str)"] end)
      + ($f.labels | map("labels = \(jql_str)"))
      + (if $f.priority then [$f.priority | jira_priority_clause] else [] end)
      + (if $f.type then ["issuetype = \($f.type | jql_str)"] else [] end)
      + (if $f.sprint == "current" then ["sprint in openSprints()"]
         elif $f.sprint then ["sprint = \($f.sprint | jql_str)"] else [] end)
      + (if $f.milestone then ["fixVersion = \($f.milestone | jql_str)"] else [] end)
      + (if $f.parent then ["parent = \($f.parent | jql_str)"] else [] end)
      + (if $f.search then
             ($f.search | lucene | jql_str) as $text
             | ["(summary ~ \($text) OR description ~ \($text))"]
         else [] end)
    | join(" AND ") + " ORDER BY updated DESC";

def jira_keep($f):
    $f.category as $c
    | if $f.status != null or $c == null or $c == "all" then true
      elif $c == "open" then (.status.category != "done" and .status.category != "canceled")
      else .status.category == $c end;

def jira_search_page($cfg; $base; $sprint; $f):
    {nodes: [.issues[] | jira_issue($cfg; $base; $sprint) | select(jira_keep($f))],
     has_next: (if has("isLast") then .isLast == false
                else ((.issues | length) > 0 and .startAt + (.issues | length) < .total) end),
     end_cursor: (if has("isLast") then .nextPageToken else .startAt + (.issues | length) end)};

def jira_person($cloud):
    if . == null then null elif $cloud == "1" then {accountId: .} else {name: .} end;

# What an intent sets on the issue itself. $ids holds what its names resolved to.
def jira_fields($cloud; $ids):
    (.clear // []) as $clear
    | (if .title then {summary: .title} else {} end)
    + (if .body != null then {description: (.body | md2wiki)} else {} end)
    + (if .priority == "none" or ($clear | index("priority")) then {priority: null}
       elif .priority then {priority: {name: (.priority | jira_priority_name)}} else {} end)
    + (if .due then {duedate: .due} elif ($clear | index("due")) then {duedate: null} else {} end)
    + (if .type then {issuetype: {name: .type}} else {} end)
    + (if $ids.milestone then {fixVersions: [{id: $ids.milestone}]}
       elif ($clear | index("milestone")) then {fixVersions: []} else {} end)
    + (if $ids | has("assignee") then {assignee: ($ids.assignee | jira_person($cloud))} else {} end)
    + (if $ids | has("parent") then {parent: (if $ids.parent then {key: $ids.parent} else null end)} else {} end);

def jira_label_update:
    (.add_labels | map({add: .})) + (.remove_labels | map({remove: .}));

def jira_comment($base; $key):
    {id, author: (.author | jira_user), body: ((.body // "") | wiki2md),
     url: "\($base)/browse/\($key)?focusedCommentId=\(.id)",
     created_at: .created, updated_at: .updated}
    | make_comment;

def jira_milestone($base; $project):
    {id, name, description, due_date: .releaseDate,
     state: (if .released then "closed" else "open" end),
     url: "\($base)/projects/\($project)/versions/\(.id)"}
    | make_milestone;

def jira_sprint:
    {id, name, state,
     start_date: (.startDate // null | if . then .[0:10] else null end),
     end_date: (.endDate // null | if . then .[0:10] else null end)}
    | make_sprint;

def jira_board($base; $cloud):
    . as $b
    | {id, name,
       url: (if $cloud == "1" and $b.location.projectKey
             then "\($base)/jira/software/projects/\($b.location.projectKey)/boards/\($b.id)"
             else "\($base)/secure/RapidBoard.jspa?rapidView=\($b.id)" end)}
    | make_board;

# GitLab answers into the common model. Adapters prepend this file through $BOARD_LIB, after
# lib/jq/common.jq. On Free a status and a priority are labels declared in workflow.toml.

def gl_user: if . == null then null else {id: .username, name: (.name // .username)} end;

# ISSUE or TEST_CASE to Issue or Test Case, and back to what REST takes.
def gl_type:
    if . == null then null
    else ascii_downcase | split("_") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ") end;

def gl_type_key: ascii_downcase | gsub(" "; "_");

def gl_status_names($cfg): ($cfg.statuses // {}) | keys_unsorted;

def gl_priority_names($cfg): [($cfg.priority // {})[]];

def gl_has($name): any(.[]; ieq($name));

# The declared statuses among these labels, in declared order.
def gl_statuses_on($cfg):
    . as $on | [gl_status_names($cfg)[] | . as $s | select($on | gl_has($s))];

def gl_priority_on($cfg):
    . as $on
    | [($cfg.priority // {}) | to_entries[] | . as $p | select($on | gl_has($p.value)) | .key] | first;

def gl_plain_labels($cfg):
    (gl_status_names($cfg) + gl_priority_names($cfg)) as $taken
    | map(. as $l | select($taken | gl_has($l) | not));

# A warning for an issue that carries two declared statuses. Input: the raw issue.
def gl_clash($cfg):
    (.labels | gl_statuses_on($cfg)) as $on
    | if ($on | length) > 1
      then "issue \(.iid) carries \($on | join(" and ")): reading it as \($on[0])"
      else empty end;

# Relative is "#9" for an issue of this project, and a longer path for one of another.
def gl_ref:
    if (.references.relative // "" | startswith("#")) then (.iid | tostring) else .references.full end;

def gl_link:
    {type: ({relates_to: "relates", blocks: "blocks", is_blocked_by: "blocked-by"}[.link_type]),
     id: gl_ref} | make_link;

def gl_tree:
    [(.data.project.workItems.nodes[0].widgets // [])[] | select(has("children"))] | first // {};

# Input: {issue, links, tree}, where a list has only the issue.
def gl_issue($cfg):
    (.tree | gl_tree) as $tree
    | (.links // []) as $links
    | .issue as $i
    | ($i.labels | gl_statuses_on($cfg)) as $on
    | {id: $i.iid,
       kind: "gitlab",
       url: $i.web_url,
       title: $i.title,
       description: $i.description,
       type: ($i.type | gl_type),
       status: (if ($on | length) > 0 then {name: $on[0]}
                else {name: null, native: (if $i.state == "closed" then "done" else "todo" end)} end),
       assignees: ($i.assignees | map(gl_user)),
       labels: ($i.labels | gl_plain_labels($cfg)),
       priority: ($i.labels | gl_priority_on($cfg)),
       parent: $tree.parent.iid,
       subtasks: [($tree.children.nodes // [])[].iid],
       links: ($links | map(gl_link)),
       sprint: $i.iteration.title,
       milestone: $i.milestone.title,
       due_date: $i.due_date,
       author: ($i.author | gl_user),
       created_at: $i.created_at,
       updated_at: $i.updated_at}
    | make_issue($cfg);

# The REST query of a list. The state only cuts the pages read: gl_keep has the last word.
def gl_list_query($cfg):
    def q($key; $value): "\($key)=\($value | tostring | @uri)";
    . as $f
    | ($f.labels
       + (if $f.status then [([gl_status_names($cfg)[] | select(ieq($f.status))] | first) // $f.status] else [] end)
       + (if $f.priority_label then [$f.priority_label] else [] end)) as $labels
    | ["per_page=100", "order_by=updated_at", "sort=desc",
       q("state"; if $f.category == "open" or $f.category == "todo" or $f.category == "in_progress"
                  then "opened" else "all" end)]
    + (if ($labels | length) > 0 then [q("labels"; $labels | join(","))] else [] end)
    + (if $f.assignee == "none" then ["assignee_id=None"]
       elif $f.assignee then [q("assignee_username"; $f.assignee)] else [] end)
    + (if $f.milestone then [q("milestone"; $f.milestone)] else [] end)
    + (if $f.type then [q("issue_type"; $f.type | gl_type_key)] else [] end)
    + (if $f.search then [q("search"; $f.search)] else [] end)
    + (if $f.sprint == "current" then ["iteration_id=Current"]
       elif $f.sprint then [q("iteration_title"; $f.sprint)] else [] end)
    + (($f.iids // []) | map("iids%5B%5D=\(.)"))
    | join("&");

# What the list query cannot filter on. Input: a normalised issue.
def gl_keep($f):
    . as $i
    | ($f.category as $c
       | if $c == "all" then true
         elif $c == "open" then ($i.status.category != "done" and $i.status.category != "canceled")
         else $i.status.category == $c end)
    and ($f.priority != "none" or $i.priority == null);

# --- bodies of a write. A move has to stay one call: labels and state change together. --------

# Input: {name, category}, where name is null when no status of the category is declared.
def gl_move_body($cfg):
    . as $s
    | (gl_status_names($cfg) - [$s.name]) as $others
    | (if $s.name then {add_labels: $s.name} else {} end)
    + (if ($others | length) > 0 then {remove_labels: ($others | join(","))} else {} end)
    + {state_event: (if $s.category == "done" or $s.category == "canceled" then "close" else "reopen" end)};

# Input: a resolved intent. Prints {add, remove}: a declared set keeps at most one label.
def gl_label_ops($cfg):
    . as $i
    | (gl_status_names($cfg)) as $statuses
    | (gl_priority_names($cfg)) as $priorities
    | {add: ($i.labels + $i.add_labels), remove: $i.remove_labels}
    | if $i.status_doc then .add += [$i.status_doc.name] | .remove += ($statuses - [$i.status_doc.name])
      else . end
    | if $i.priority == "none" or ($i.clear | index("priority")) then .remove += $priorities
      elif $i.priority_label then .add += [$i.priority_label] | .remove += ($priorities - [$i.priority_label])
      else . end;

def gl_fields:
    . as $i
    | (if $i.title then {title: $i.title} else {} end)
    + (if $i.body != null then {description: $i.body} else {} end)
    + (if $i.due then {due_date: $i.due} elif ($i.clear | index("due")) then {due_date: null} else {} end)
    + (if $i.milestone_id then {milestone_id: $i.milestone_id}
       elif ($i.clear | index("milestone")) then {milestone_id: 0} else {} end)
    + (if $i.assignee_ids then {assignee_ids: $i.assignee_ids} else {} end);

def gl_create_body($cfg):
    gl_fields
    + (if .type then {issue_type: (.type | gl_type_key)} else {} end)
    + (gl_label_ops($cfg) | if (.add | length) > 0 then {labels: (.add | join(","))} else {} end);

def gl_edit_body($cfg):
    gl_fields
    + (gl_label_ops($cfg)
       | (if (.add | length) > 0 then {add_labels: (.add | join(","))} else {} end)
       + (.remove - .add | if length > 0 then {remove_labels: join(",")} else {} end))
    + (if .status_doc then {state_event: (.status_doc | gl_move_body($cfg) | .state_event)} else {} end);

# A new issue starts in the first todo status: an agent reads the status right after creating.
# Only a Task can have a parent, so a parent beats [board.defaults] type, which arrives as .type.
def gl_create_defaults($cfg):
    . as $i
    | ([($cfg.statuses // {}) | to_entries[] | select(.value == "todo") | .key] | first) as $todo
    | .status = ($i.status // $todo)
    | .type = (if $i.parent and ($i.type == null or $i.type == $cfg.defaults.type) then "Task" else $i.type end);

# --- other objects -----------------------------------------------------------------------

def gl_comment($web):
    {id, author: (.author | gl_user), body, url: "\($web)/-/work_items/\(.noteable_iid)#note_\(.id)",
     created_at, updated_at} | make_comment;

def gl_label:
    {id, name, color: (.color // "" | ltrimstr("#") | nullify), description} | make_label;

def gl_milestone:
    {id, name: .title, description, state: (if .state == "active" then "open" else .state end),
     due_date, url: .web_url} | make_milestone;

def gl_sprint:
    {id, name: (.title // "\(.start_date) to \(.due_date)"),
     state: ({"1": "future", "2": "active", "3": "closed"}[.state | tostring] // "future"),
     start_date, end_date: .due_date} | make_sprint;

def gl_board($web):
    {id, name, url: "\($web)/-/boards/\(.id)"} | make_board;

# The message of an answer: a string, or validation errors by field.
def gl_message:
    (if type == "object"
     then (.message // .error // (.errors | if type == "array" then first.message else null end))
     else null end) as $m
    | if ($m | type) == "object"
      then [$m | to_entries[] | "\(.key) \(.value | if type == "array" then join(", ") else tostring end)"]
           | join("; ")
      else $m // empty end;

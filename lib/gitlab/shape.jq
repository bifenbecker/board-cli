# GitLab answers into the common model. Adapters prepend this file through $BOARD_LIB, after
# lib/jq/common.jq. On Free a status and a priority are labels declared in workflow.toml.

def gl_user: if . == null then null else {id: .username, name: (.name // .username)} end;

# ISSUE or TEST_CASE to Issue or Test Case, and back to what REST takes.
def gl_type:
    if . == null then null
    else ascii_downcase | split("_") | map((.[0:1] | ascii_upcase) + .[1:]) | join(" ") end;

def gl_type_key: ascii_downcase | gsub(" "; "_");

# GitLab runs a line that starts with / as a quick action, in a description and in a note: it would
# close the issue, and the text would be gone. One backslash keeps it text and renders as the
# original, and removing one on read gives back exactly what was written.
def gl_lines(f): if . == null then null else split("\n") | map(f) | join("\n") end;

def gl_escape: gl_lines(sub("^(?<s> {0,3})(?<b>\\\\*)/"; "\(.s)\(.b)\\/"));

def gl_unescape: gl_lines(sub("^(?<s> {0,3})(?<b>\\\\*)\\\\/"; "\(.s)\(.b)/"));

def gl_status_names($cfg): ($cfg.statuses // {}) | keys_unsorted;

def gl_priority_names($cfg): [($cfg.priority // {})[]];

# What a write has to clear: gl_real_cfg adds other spellings of the same names.
def gl_status_set($cfg): gl_status_names($cfg) + ($cfg._status_twins // []);

def gl_priority_set($cfg): gl_priority_names($cfg) + ($cfg._priority_twins // []);

def gl_has($name): any(.[]; ieq($name));

# The project's spelling of a name, or the name when it has none. Labels are case-sensitive, and a
# write in another case makes a second label.
def gl_spelled($names; $want):
    ([$names[] | select(. == $want)] + [$names[] | select(ieq($want))] | first) // $want;

# The declaration as the project spells it, order kept.
def gl_real_cfg($names):
    . as $cfg
    | (($cfg.statuses // {}) | with_entries(.key |= gl_spelled($names; .))) as $statuses
    | (($cfg.priority // {}) | map_values(gl_spelled($names; .))) as $priority
    | def twins($declared; $real):
          [$names[] | . as $n | select(($declared | gl_has($n)) and (($real | index($n)) | not))];
      $cfg + {statuses: $statuses, priority: $priority,
              _status_twins: twins(gl_status_names($cfg); ($statuses | keys_unsorted)),
              _priority_twins: twins(gl_priority_names($cfg); [$priority[]])};

# The declared statuses among these labels, in declared order, spelled as the issue has them.
def gl_statuses_on($cfg):
    . as $on | [gl_status_names($cfg)[] | . as $s | $on[] | select(ieq($s))];

def gl_priorities_on($cfg):
    . as $on | [($cfg.priority // {}) | to_entries[] | . as $p | select($on | gl_has($p.value)) | .key];

def gl_plain_labels($cfg):
    (gl_status_names($cfg) + gl_priority_names($cfg)) as $taken
    | map(. as $l | select($taken | gl_has($l) | not));

# Warnings for an issue that carries two of a declared set. Input: the raw issue.
def gl_clash($cfg):
    (.labels | gl_statuses_on($cfg)) as $s
    | (.labels | gl_priorities_on($cfg)) as $p
    | (if ($s | length) > 1 then "issue \(.iid) carries \($s | join(" and ")): reading it as \($s[0])" else empty end),
      (if ($p | length) > 1 then "issue \(.iid) carries priorities \($p | join(" and ")): reading it as \($p[0])" else empty end);

# Relative is "#9" for an issue of this project, and a longer path for one of another.
def gl_ref:
    if (.references.relative // "" | startswith("#")) then (.iid | tostring) else .references.full end;

def gl_link:
    {type: ({relates_to: "relates", blocks: "blocks", is_blocked_by: "blocked-by"}[.link_type]),
     id: gl_ref} | make_link;

def gl_tree:
    [(.data.project.workItems.nodes[0].widgets // [])[] | select(has("children"))] | first // {};

# Input: an iteration. Automatic ones have no title.
def gl_iteration_name: .title // "\(.start_date) to \(.due_date)";

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
       description: ($i.description | gl_unescape),
       type: ($i.type | gl_type),
       status: (if ($on | length) > 0 then {name: $on[0]}
                else {name: null, native: (if $i.state == "closed" then "done" else "todo" end)} end),
       assignees: ($i.assignees | map(gl_user)),
       labels: ($i.labels | gl_plain_labels($cfg)),
       priority: ($i.labels | gl_priorities_on($cfg) | first),
       parent: $tree.parent.iid,
       subtasks: [($tree.children.nodes // [])[].iid],
       links: ($links | map(gl_link)),
       sprint: (if $i.iteration then ($i.iteration | gl_iteration_name) else null end),
       milestone: $i.milestone.title,
       due_date: $i.due_date,
       author: ($i.author | gl_user),
       created_at: $i.created_at,
       updated_at: $i.updated_at}
    | make_issue($cfg)
    # Closing keeps the labels, so the label alone would call a closed issue open work.
    | if $i.state == "closed" and .status.category != "done" and .status.category != "canceled"
      then .status.category = "done" else . end;

# False for a name GitLab reads as a keyword of this filter, or splits at a comma.
def gl_speakable($keywords):
    . as $n | (test(",") | not) and ($keywords | gl_has($n) | not);

# The labels a list can ask the server for: gl_keep decides, this only cuts the pages read.
def gl_server_labels($names):
    . as $f
    | ($f.labels
       + (if $f.status then [$f.status] else [] end)
       + (if $f.priority_label then [$f.priority_label] else [] end))
    | map(gl_spelled($names; .) | select(. as $l | ($names | index($l)) != null and gl_speakable(["Any", "None"])));

# A closed issue is never open, todo or in_progress, so those need no closed ones.
def gl_list_query:
    def q($key; $value): "\($key)=\($value | tostring | @uri)";
    . as $f
    | ["per_page=100", "order_by=updated_at", "sort=desc",
       q("state"; if $f.category == "open" or $f.category == "todo" or $f.category == "in_progress"
                  then "opened" else "all" end)]
    + (if ($f.server_labels | length) > 0 then [q("labels"; $f.server_labels | join(","))] else [] end)
    + (if $f.assignee == "none" then ["assignee_id=None"]
       elif $f.assignee then [q("assignee_username"; $f.assignee)] else [] end)
    + (if $f.server_milestone then [q("milestone"; $f.server_milestone)] else [] end)
    + (if $f.type then [q("issue_type"; $f.type | gl_type_key)] else [] end)
    + (if $f.search then [q("search"; $f.search)] else [] end)
    + (if $f.sprint == "current" then ["iteration_id=Current"] else [] end)
    + (($f.iids // []) | map("iids%5B%5D=\(.)"))
    | join("&");

# Every condition of a list, on the issue as it reads. Input: a normalised issue; $raw is what the
# board has, because status and priority labels are not in .labels.
def gl_keep($f; $raw):
    . as $i
    | (if $f.status != null then ($i.status.name | ieq($f.status))
       elif $f.category == "all" then true
       elif $f.category == "open" then ($i.status.category != "done" and $i.status.category != "canceled")
       else $i.status.category == $f.category end)
    and (if $f.priority == null then true
         elif $f.priority == "none" then $i.priority == null
         else $i.priority == $f.priority end)
    and ($f.labels | all(. as $l | $raw | gl_has($l)))
    and ($f.milestone == null or ($i.milestone | ieq($f.milestone)))
    and ($f.type == null or ($i.type | ieq($f.type)))
    and ($f.sprint == null or $f.sprint == "current" or ($i.sprint | ieq($f.sprint)))
    and (if $f.assignee == null then true
         elif $f.assignee == "none" then ($i.assignees | length) == 0
         else ($i.assignees | any(.id | ieq($f.assignee))) end);

# --- bodies of a write. A move has to stay one call: labels and state change together. --------

# Input: {name, category}, where name is null when no status of the category is declared.
def gl_move_body($cfg):
    . as $s
    | (gl_status_set($cfg) - [$s.name]) as $others
    | (if $s.name then {add_labels: $s.name} else {} end)
    + (if ($others | length) > 0 then {remove_labels: ($others | join(","))} else {} end)
    + {state_event: (if $s.category == "done" or $s.category == "canceled" then "close" else "reopen" end)};

# A label naming a declared status or priority is that change, so a set keeps one label. --status
# and --priority win over it, and the last label named wins over the ones before.
def gl_promote($cfg):
    (.labels + .add_labels) as $named
    | gl_status_names($cfg) as $statuses
    | ([$named[] | . as $l | select($statuses | gl_has($l))] | last) as $status
    | ([$named[] | . as $l | [($cfg.priority // {}) | to_entries[] | select(.value | ieq($l)) | .key]
        | first // empty] | last) as $priority
    | .status = (.status // $status)
    | .priority = (.priority // $priority)
    | .labels |= gl_plain_labels($cfg)
    | .add_labels |= gl_plain_labels($cfg);

# Every label in the project's spelling. Removing takes all spellings of a name.
def gl_spell($names):
    .labels |= map(gl_spelled($names; .))
    | .add_labels |= map(gl_spelled($names; .))
    | .remove_labels |= (map(. as $l | [$names[] | select(ieq($l))] | if length > 0 then . else [$l] end) | add // []);

# Input: a resolved intent. Prints {add, remove}: a declared set keeps at most one label.
def gl_label_ops($cfg):
    . as $i
    | gl_status_set($cfg) as $statuses
    | gl_priority_set($cfg) as $priorities
    | {add: ($i.labels + $i.add_labels), remove: $i.remove_labels}
    | if $i.status_doc then .add += [$i.status_doc.name] | .remove += ($statuses - [$i.status_doc.name])
      else . end
    | if $i.priority == "none" or ($i.clear | index("priority")) then .remove += $priorities
      elif $i.priority_label then .add += [$i.priority_label] | .remove += ($priorities - [$i.priority_label])
      else . end;

def gl_fields:
    . as $i
    | (if $i.title then {title: $i.title} else {} end)
    + (if $i.body != null then {description: ($i.body | gl_escape)} else {} end)
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

# A new issue starts in the first todo status: an agent reads the status right after creating. A
# parent decides the type over [board.defaults] type, which lib/cmd marks with type_default.
def gl_create_defaults($cfg):
    . as $i
    | ([($cfg.statuses // {}) | to_entries[] | select(.value == "todo") | .key] | first) as $todo
    | .status = ($i.status // $todo)
    | .type = (if $i.parent and ($i.type == null or $i.type_default) then "Task" else $i.type end);

# Why a work item of this type cannot go under that parent, or nothing. Input: WorkItemTypes.
def gl_parent_rule($child; $parent):
    ([.data.project.workItemTypes.nodes[] | select(.name | ieq($child)) | .widgetDefinitions[]
      | select(.type == "HIERARCHY") | (.allowedParentTypes.nodes // [])[].name]) as $allowed
    | if ($allowed | gl_has($parent)) then empty
      elif ($allowed | length) == 0 then "type \($child) cannot have a parent: pass --type Task to convert it"
      else "type \($child) can only have a parent of type \($allowed | join(", ")), not \($parent)" end;

# --- other objects -----------------------------------------------------------------------

def gl_comment($web):
    {id, author: (.author | gl_user), body: (.body | gl_unescape),
     url: "\($web)/-/work_items/\(.noteable_iid)#note_\(.id)",
     created_at, updated_at} | make_comment;

def gl_label:
    {id, name, color: (.color // "" | ltrimstr("#") | nullify), description} | make_label;

def gl_milestone:
    {id, name: .title, description, state: (if .state == "active" then "open" else .state end),
     due_date, url: .web_url} | make_milestone;

def gl_sprint:
    {id, name: gl_iteration_name,
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

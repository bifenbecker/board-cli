# Linear answers into the common model. Adapters prepend this file through $BOARD_LIB, after
# lib/jq/common.jq.

def ln_category:
    {triage: "todo", backlog: "todo", unstarted: "todo", started: "in_progress",
     completed: "done", canceled: "canceled", duplicate: "canceled"}[.];

# The API returns states in no useful order. Triage sits behind the other todo statuses: the first
# status of todo is where a reopened issue goes, and that must not be the triage inbox.
def ln_order:
    {backlog: 0, unstarted: 1, triage: 2, started: 3, completed: 4, canceled: 5, duplicate: 6}[.] // 7;

def ln_status($cfg):
    {id, name, native: (.type | ln_category)} | make_status($cfg);

# Input: the nodes of a team's states.
def ln_statuses($cfg):
    sort_by((.type | ln_order), .position) | map(ln_status($cfg));

def ln_user: if . == null then null else {id, name} end;

def ln_priority_name: ["none", "urgent", "high", "medium", "low"][.];

def ln_priority_value: {none: 0, urgent: 1, high: 2, medium: 3, low: 4}[.];

# A cycle often has no name of its own: Linear shows its number.
def ln_cycle_name: if . == null then null else (.name // "Cycle \(.number)") end;

# The side of the relation decides the word. Linear's "similar" is its own guess, not a link.
def ln_links:
    [(.relations.nodes // [])[]
     | {blocks: "blocks", duplicate: "duplicates", related: "relates"}[.type] as $type
     | select($type) | {type: $type, id: .relatedIssue.identifier}]
    + [(.inverseRelations.nodes // [])[]
       | {blocks: "blocked-by", duplicate: "duplicated-by", related: "relates"}[.type] as $type
       | select($type) | {type: $type, id: .issue.identifier}];

def ln_issue($cfg):
    {id: .identifier,
     kind: "linear",
     url,
     title,
     description,
     status: (.state | {name, native: (.type | ln_category)}),
     assignees: [.assignee | select(. != null) | ln_user],
     labels: ((.labels.nodes // []) | map(.name)),
     priority: (.priority | ln_priority_name),
     parent: .parent.identifier,
     subtasks: ((.children.nodes // []) | map(.identifier)),
     links: ln_links,
     sprint: (.cycle | ln_cycle_name),
     milestone: .projectMilestone.name,
     due_date: .dueDate,
     author: (.creator | ln_user),
     created_at: .createdAt,
     updated_at: .updatedAt}
    | make_issue($cfg);

# The state ids a --category names. Goes through make_status so [board.statuses] has its say.
def ln_state_ids($meta; $cfg; $category):
    [$meta.team.states.nodes | ln_statuses($cfg)[]
     | select(if $category == "open" then (.category != "done" and .category != "canceled")
              else .category == $category end)
     | .id];

# A person in a filter. The id comparator refuses anything but a UUID, and a name needs no lookup:
# someone who left the team can still hold issues.
def ln_person($who):
    if ($who | test("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"))
    then {id: {eq: $who}}
    else {or: [{name: {eqIgnoreCase: $who}}, {displayName: {eqIgnoreCase: $who}}]} end;

# Input: the intent of 'board issue list'. $states holds the ids --status names, and $cycle the id
# of --sprint, or "".
def ln_filter($meta; $cfg; $states; $cycle):
    . as $f
    | {and: ([{team: {id: {eq: $meta.team.id}}}]
             + (if $meta.project then [{project: {id: {eq: $meta.project.id}}}] else [] end)
             + (if $f.status then [{state: {id: {in: $states}}}]
                elif $f.category == "all" then []
                else [{state: {id: {in: ln_state_ids($meta; $cfg; $f.category)}}}] end)
             + (if $f.assignee == null then []
                elif $f.assignee == "none" then [{assignee: {null: true}}]
                elif $f.assignee == "@me" then [{assignee: {isMe: {eq: true}}}]
                else [{assignee: ln_person($f.assignee)}] end)
             + [$f.labels[] | {labels: {some: {name: {eqIgnoreCase: .}}}}]
             + (if $f.priority then [{priority: {eq: ($f.priority | ln_priority_value)}}] else [] end)
             + (if $f.sprint == null then []
                elif $f.sprint == "current" then [{cycle: {isActive: {eq: true}}}]
                else [{cycle: {id: {eq: $cycle}}}] end)
             + (if $f.milestone then [{projectMilestone: {name: {eqIgnoreCase: $f.milestone}}}] else [] end)
             + (if $f.parent then [{parent: {id: {eq: $f.parent}}}] else [] end)
             + (if $f.search then
                    [{or: [{title: {containsIgnoreCase: $f.search}},
                           {description: {containsIgnoreCase: $f.search}}]}]
                else [] end))};

# The fields of an intent that map one to one, for issueCreate and issueUpdate.
def ln_fields:
    (if .title != null then {title} else {} end)
    + (if .body != null then {description: .body} else {} end)
    + (if .priority then {priority: (.priority | ln_priority_value)} else {} end)
    + (if .parent then {parentId: .parent} else {} end)
    + (if .due then {dueDate: .due} else {} end);

# What --clear empties. Priority has no null: 0 is "no priority".
def ln_clears:
    reduce .clear[] as $c ({};
        . + {priority: {priority: 0}, parent: {parentId: null}, sprint: {cycleId: null},
             milestone: {projectMilestoneId: null}, due: {dueDate: null}}[$c]);

# The relation behind one link, if there is one. $other is an identifier or a UUID.
# Input: the raw issue.
def ln_relation_id($other; $type):
    (if $type == "blocks" then [.relations.nodes[] | select(.type == "blocks")]
     elif $type == "duplicates" then [.relations.nodes[] | select(.type == "duplicate")]
     elif $type == "blocked-by" then [.inverseRelations.nodes[] | select(.type == "blocks")]
     else [(.relations.nodes + .inverseRelations.nodes)[] | select(.type == "related")] end)
    | map(select((.relatedIssue // .issue) | .id == $other or (.identifier | ieq($other))) | .id)
    | first // "";

def ln_connections: ["labels", "children", "relations", "inverseRelations"];

# The values of IssueMore for the connections of a raw issue that stopped at a page. Nothing when
# none did.
def ln_more:
    . as $i
    | if any(ln_connections[]; $i[.].pageInfo.hasNextPage == true) then
          reduce ln_connections[] as $c ({id: $i.id};
              . + {("\($c)More"): ($i[$c].pageInfo.hasNextPage == true),
                   ("\($c)After"): $i[$c].pageInfo.endCursor})
      else empty end;

# Input: [raw issue, the issue of an IssueMore answer].
def ln_merge:
    .[0] as $i | .[1] as $page
    | reduce ln_connections[] as $c ($i;
          if $page[$c] then
              .[$c].nodes += $page[$c].nodes | .[$c].pageInfo = $page[$c].pageInfo
          else . end);

def ln_comment:
    {id, author: ((.user // .externalUser) | ln_user), body, url,
     created_at: .createdAt, updated_at: .updatedAt}
    | make_comment;

def ln_label:
    {id, name, color: (.color | ltrimstr("#")), description} | make_label;

# A project milestone has no state to set. Linear derives its status from the issues in it.
def ln_milestone:
    {id, name, description, due_date: .targetDate,
     state: (if .status == "done" then "closed" else "open" end)}
    | make_milestone;

# The number is what the board shows, and it reads better than a UUID in 'board sprint view 12'.
def ln_sprint:
    {id: .number,
     name: ln_cycle_name,
     state: (if .isActive then "active" elif .isFuture then "future" else "closed" end),
     start_date: .startsAt[0:10],
     end_date: .endsAt[0:10]}
    | make_sprint;

# The first error of an answer, for the raw text of one stream. Nothing when the text holds none.
def ln_failure:
    (try fromjson catch null) as $doc
    | if ($doc | type) == "object" and (($doc.errors | type) == "array") and ($doc.errors | length) > 0 then
          $doc.errors[0]
          | {code: (.extensions.code // ""),
             raw: (.message // ""),
             path: (.path[0]? // ""),
             user: (.extensions.userError == true),
             message: (.extensions.userPresentableMessage // .message // "the board refused the request")}
      else empty end;

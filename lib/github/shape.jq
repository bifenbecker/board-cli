# GitHub answers into the common model. $repo is the owner/name of [board] url.

include "jq/common";

def gh_user: if . == null then null else {id: .login, name: (.name // .login)} end;

def gh_ref($repo):
    if .repository.nameWithOwner == $repo then (.number | tostring)
    else "\(.repository.nameWithOwner)#\(.number)" end;

# The board's priority name back to a common one, through [board.priority].
def gh_priority($cfg):
    . as $name
    | if $name == null then null
      else ([($cfg.priority // {}) | to_entries[] | select(.value | ieq($name)) | .key] | first) end;

def gh_links($repo):
    [(.blocking.nodes // [])[] | {type: "blocks", id: gh_ref($repo)}]
    + [(.blockedBy.nodes // [])[] | {type: "blocked-by", id: gh_ref($repo)}];

# Input: the issue, draft or pull request, as content or as an Issue.
def gh_content($repo):
    . as $c
    | {kind: "github",
       title: .title,
       description: .body,
       assignees: ((.assignees.nodes // []) | map(gh_user)),
       labels: ((.labels.nodes // []) | map(.name)),
       created_at: .createdAt,
       updated_at: .updatedAt}
    + (if .__typename == "DraftIssue" then
           {author: (.creator | gh_user)}
       else
           {id: gh_ref($repo),
            url: .url,
            type: (.issueType.name // (if .__typename == "PullRequest" then "Pull request" else null end)),
            milestone: .milestone.title,
            parent: (if .parent then (.parent | gh_ref($repo)) else null end),
            subtasks: ((.subIssues.nodes // []) | map(gh_ref($repo))),
            links: gh_links($repo),
            author: (.author | gh_user),
            _closed: (.state != "OPEN")}
       end);

# What an item adds to its content: the fields that live on the project.
def gh_item_fields($cfg):
    {status_name: .status.name,
     priority: (.priority.name | gh_priority($cfg)),
     due_date: .due.date,
     sprint: .sprint.title};

def gh_finish($cfg):
    . as $i
    | ($i + {status: {name: $i.status_name,
                      native: (if $i.status_name == null
                               then (if $i._closed then "done" else "todo" end)
                               else null end)}})
    | del(.status_name, ._closed)
    | make_issue($cfg);

# Input: a ProjectV2Item.
def gh_item($cfg; $repo):
    . as $item
    | (.content | gh_content($repo))
    + ($item | gh_item_fields($cfg))
    + (if $item.content.__typename == "DraftIssue" or $item.content == null then {id: $item.id} else {} end)
    | gh_finish($cfg);

# Input: an Issue with projectItems.
def gh_issue($cfg; $repo; $number):
    . as $issue
    | (($issue.projectItems.nodes // []) | map(select(.project.number == $number)) | first) as $item
    | ({__typename: "Issue"} + $issue | gh_content($repo))
    + (if $item then ($item | gh_item_fields($cfg)) else {} end)
    | gh_finish($cfg);

# Applies what the project query cannot filter on. Input: a normalised issue.
def gh_keep($f):
    . as $i
    | ($f.category as $c
       | if $f.status != null or $c == null or $c == "all" then true
         elif $c == "open" then ($i.status.category != "done" and $i.status.category != "canceled")
         else $i.status.category == $c end)
    and ($f.priority == null or $i.priority == $f.priority)
    and ($f.type == null or ($i.type | ieq($f.type)))
    and ($f.sprint == null or ($i.sprint | ieq($f.sprint)))
    and ($f.milestone == null or ($i.milestone | ieq($f.milestone)))
    and ($f.parent == null or $i.parent == $f.parent);

# The project's own filter language. Cuts the pages read; gh_keep has the last word.
def gh_filter_query($cfg):
    def q: if test("[ \"]") then tojson else . end;
    ([if .status then "status:\(.status | q)" else empty end]
     + [if .assignee == "none" then "no:assignee"
        elif .assignee then "assignee:\(.assignee | q)" else empty end]
     + [.labels[] | "label:\(q)"]
     + [if .search then .search else empty end])
    | join(" ");

def gh_comment:
    {id, author: (.user | gh_user), body, url: .html_url,
     created_at, updated_at} | make_comment;

def gh_label:
    {id: .node_id, name, color, description} | make_label;

def gh_milestone:
    {id: .number, name: .title, description, state, due_date: (.due_on // null | if . then .[0:10] else null end),
     url: .html_url} | make_milestone;

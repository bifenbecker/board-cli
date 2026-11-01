# GitHub answers into the common model. $repo is the owner/name of [board] url. Adapters prepend
# this file through $BOARD_LIB, after lib/jq/common.jq.

def gh_user: if . == null then null else {id: .login, name: (.name // .login)} end;

def gh_same_repo($a; $b): ($a | ascii_downcase) == ($b | ascii_downcase);

def gh_ref($repo):
    if gh_same_repo(.repository.nameWithOwner; $repo) then (.number | tostring)
    else "\(.repository.nameWithOwner)#\(.number)" end;

# An id as gh_ref writes it: owner/repo#12 of the board's own repository is 12.
def gh_short($repo):
    if . == null then null
    elif test("#") and gh_same_repo(split("#")[0]; $repo) then split("#")[1]
    else . end;

# The board's priority name back to a common one, through [board.priority].
def gh_priority($cfg):
    . as $name
    | if $name == null then null
      else ([($cfg.priority // {}) | to_entries[] | select(.value | ieq($name)) | .key] | first) end;

def gh_links($repo):
    [(.blocking.nodes // [])[] | {type: "blocks", id: gh_ref($repo)}]
    + [(.blockedBy.nodes // [])[] | {type: "blocked-by", id: gh_ref($repo)}]
    + [(.relatesTo.nodes // [])[] | {type: "relates", id: gh_ref($repo)}]
    + (if .duplicateOf then [.duplicateOf | {type: "duplicates", id: gh_ref($repo)}] else [] end);

# Input: the issue, draft or pull request, as content or as an Issue.
def gh_content($repo):
    {kind: "github",
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

# The item of this project among the projects an issue is on. A number alone is not enough: the
# same number exists under every owner.
def gh_our_item($number; $owner):
    (. // []) | map(select(.project.number == $number and gh_same_repo(.project.owner.login // ""; $owner))) | first;

# Input: an Issue with projectItems.
def gh_issue($cfg; $repo; $number; $owner):
    . as $issue
    | ($issue.projectItems.nodes | gh_our_item($number; $owner)) as $item
    | ({__typename: "Issue"} + $issue | gh_content($repo))
    + (if $item then ($item | gh_item_fields($cfg)) else {} end)
    | gh_finish($cfg);

# The filter that decides. The project query only cuts the pages read: it cannot express every
# name, so every condition is checked again here. Input: a normalised issue.
def gh_keep($f; $repo):
    . as $i
    | (if $f.status != null then ($i.status.name | ieq($f.status))
       elif $f.category == null or $f.category == "all" then true
       elif $f.category == "open" then ($i.status.category != "done" and $i.status.category != "canceled")
       else $i.status.category == $f.category end)
    and (if $f.priority == null then true
         elif $f.priority == "none" then $i.priority == null
         else $i.priority == $f.priority end)
    and ($f.type == null or ($i.type | ieq($f.type)))
    and ($f.sprint == null or ($i.sprint | ieq($f.sprint)))
    and ($f.milestone == null or ($i.milestone | ieq($f.milestone)))
    and ($f.parent == null or $i.parent == ($f.parent | gh_short($repo)))
    and (($f.labels // []) | all(. as $l | $i.labels | any(ieq($l))))
    and (if $f.assignee == null then true
         elif $f.assignee == "none" then $i.assignees == []
         else ($i.assignees | any(.id | ieq($f.assignee))) end)
    and ($f.search == null
         or (("\($i.title // "")\n\($i.description // "")") | test($f.search | re_escape; "i")));

# The project's own filter language, for names it can express. * is a wildcard there and a comma
# is an OR, and it has no working escape for a quote. Free text is left out: it would read words
# like status:Done as qualifiers, and it never searches the body.
def gh_filter_query:
    def safe: test("^[\\p{L}\\p{N} _.-]+$");
    def q: if test(" ") then "\"\(.)\"" else . end;
    ([if .status and (.status | safe) then "status:\(.status | q)" else empty end]
     + [if .assignee == "none" then "no:assignee"
        elif .assignee and (.assignee | safe) then "assignee:\(.assignee | q)" else empty end]
     + [.labels[] | select(safe) | "label:\(q)"])
    | join(" ");

def gh_comment:
    {id, author: (.user | gh_user), body, url: .html_url,
     created_at, updated_at} | make_comment;

def gh_label:
    {id: .node_id, name, color, description} | make_label;

def gh_milestone:
    {id: .number, name: .title, description, state, due_date: (.due_on // null | if . then .[0:10] else null end),
     url: .html_url} | make_milestone;

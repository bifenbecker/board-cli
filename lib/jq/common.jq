# The common model. Every adapter's shape.jq ends in one of the make_* below, so a key can never
# be missing and the key order is the same on every board.

def nullify: if . == "" then null else . end;

def re_escape: gsub("(?<c>[.*+?^${}()|\\[\\]\\\\/])"; "\\\(.c)");

# Equal ignoring case, Cyrillic too: ascii_downcase leaves it alone. The only way names are compared.
def ieq($other): . != null and test("^" + ($other | re_escape) + "$"; "i");

# A timestamp in UTC at one-second precision, whatever the board wrote.
def utc:
    if . == null or . == "" then null
    else
        (capture("^(?<d>\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})(\\.\\d+)?(?<z>Z|[+-]\\d{2}:?\\d{2})$")
            | (.d + "Z" | fromdateiso8601) as $t
            | (if .z == "Z" then 0
               else ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60)
                    * (if .z[0:1] == "+" then 1 else -1 end)
               end) as $offset
            | ($t - $offset) | todate)
        // .
    end;

def make_user:
    if . == null then null else {id: (.id | tostring), name: (.name // .id | tostring)} end;

# Declared in [board.statuses], or the board's own category, or null: never a guess.
def category_of($cfg; $name; $native):
    ([($cfg.statuses // {}) | to_entries[] | select(.key | ieq($name)) | .value] | first) // $native;

# Input: {id?, name, native?}, where native is the board's own category in common terms.
def make_status($cfg):
    {id: (if .id == null then null else (.id | tostring) end),
     name: .name,
     category: category_of($cfg; .name; .native)};

def make_issue($cfg):
    {id: (.id | tostring),
     kind: .kind,
     url: (.url // null),
     title: (.title // null),
     description: (.description | if . == "" then null else . end),
     type: (.type // null),
     status: (if .status == null then {name: null, category: null}
              else (.status | make_status($cfg) | {name, category}) end),
     assignees: ((.assignees // []) | map(make_user)),
     labels: (.labels // []),
     priority: (.priority // null),
     parent: (if .parent == null then null else (.parent | tostring) end),
     subtasks: ((.subtasks // []) | map(tostring)),
     links: (.links // []),
     sprint: (.sprint // null),
     milestone: (.milestone // null),
     due_date: (.due_date // null),
     author: (.author | make_user),
     created_at: (.created_at | utc),
     updated_at: (.updated_at | utc)};

def make_comment:
    {id: (.id | tostring),
     author: (.author | make_user),
     body: (.body // null),
     url: (.url // null),
     created_at: (.created_at | utc),
     updated_at: (.updated_at | utc)};

def make_link:
    {type: .type, id: (.id | tostring)};

def make_label:
    {id: (if .id == null then null else (.id | tostring) end),
     name: .name,
     color: (.color // null),
     description: (.description // null)};

def make_member:
    {id: (.id | tostring), name: (.name // .id | tostring)};

def make_sprint:
    {id: (.id | tostring),
     name: .name,
     state: .state,
     start_date: (.start_date // null),
     end_date: (.end_date // null)};

def make_milestone:
    {id: (.id | tostring),
     name: .name,
     description: (.description // null),
     state: .state,
     due_date: (.due_date // null),
     url: (.url // null)};

def make_board:
    {id: (.id | tostring), name: .name, url: (.url // null)};

# Jira wiki markup to markdown, best effort. Macros are put on lines of their own, then a line at a
# time. Panels read as quotes, tables as markdown tables, a mention as @id.

def w2m_token:
    if . == "\\\\" then "  \n"
    elif startswith("\\") then (if test("^\\\\[{}\\[\\]|]") then .[1:] else . end)
    elif startswith("{{") then "`" + .[2:-2] + "`"
    elif startswith("[~accountid:") then "@" + .[12:-1]
    elif startswith("[~") then "@" + .[2:-1]
    elif startswith("[^") then .[2:-1]
    elif startswith("[") then
        (.[1:-1] | split("|")) as $p
        | if ($p | length) > 1 then "[\($p[0])](\($p[1]))"
          elif ($p[0] | test("^[a-z+]+:")) then "<\($p[0])>"
          else "[\($p[0])]" end
    elif startswith("!") then (.[1:-1] | split("|")[0]) as $u | "![\($u)](\($u))"
    else . end;

def w2m_inline:
    gsub("\\{color(:[^}]*)?\\}"; "")
    | . as $s
    | reduce ([match("\\\\\\\\|\\\\.|\\{\\{.+?\\}\\}|\\[~[^\\]]+\\]|\\[\\^[^\\]]+\\]|\\[[^\\]]+\\]|!(?=[^\\s!])[^\\s!|]+(\\|[^!]*)?!|https?://[^\\s|\\]]+"; "g")] | reverse | .[]) as $m
        ({t: $s, kept: []};
         .t = .t[:$m.offset] + "\(.kept | length)" + .t[$m.offset + $m.length:]
         | .kept += [$m.string | w2m_token])
    | .kept as $kept
    | .t
    | gsub("(?<![\\w*])\\*(?=\\S)(?<t>[^*]*?\\S)\\*(?![\\w*])"; "\(.t)")
    | gsub("(?<![\\w_])_(?=\\S)(?<t>[^_]*?\\S)_(?![\\w_])"; "*\(.t)*")
    | gsub("(?<![\\w-])-(?=\\S)(?<t>[^-]*?\\S)-(?![\\w-])"; "~~\(.t)~~")
    | gsub("(?<![\\w+])\\+(?=\\S)(?<t>[^+]*?\\S)\\+(?![\\w+])"; .t)
    | gsub(""; "**")
    | gsub("(?<i>\\d+)"; $kept[.i | tonumber])
    | rtrimstr("\n");

def w2m_row:
    w2m_inline | gsub("^\\s*\\|+|\\|+\\s*$"; "") | [splits("\\|+")] | map(gsub("^\\s+|\\s+$"; ""));

def w2m_cells: "| " + join(" | ") + " |";

# {code:java}, {code:language=java|title=x} and {code:title=x|java}.
def w2m_lang:
    [capture("^\\{code:(?<p>.*)\\}$").p | split("|")[] | select(contains("=") | not), (capture("^language=(?<l>.*)").l)]
    | first // "";

# A number per depth: the markers only say the kind of list.
def w2m_item($li):
    ($li.m | length) as $d
    | ($li.m[:-1] | explode | map(if . == 35 then "   " else "  " end) | join("")) as $indent
    | .nums = ((.nums + [0, 0, 0, 0, 0, 0, 0, 0])[:$d] | .[$d - 1] += 1)
    | [$indent + (if $li.m[-1:] == "#" then "\(.nums[$d - 1])." else "-" end) + " " + ($li.t | w2m_inline)] as $line
    | .add = $line;

def w2m_line($l):
    ($l | [capture("^\\s*(?<m>[*#-]+) +(?<t>.*)$")] | first) as $li
    | ($l | [capture("^\\s*h(?<n>[1-6])\\.\\s+(?<t>.*)$")] | first) as $hd
    | ($l | [capture("^\\s*bq\\.\\s+(?<t>.*)$")] | first) as $bq
    | if ($l | test("^\\s*-{4,}\\s*$")) then .add = ["---"] | .nums = []
      elif ($l | test("^\\s*\\|\\|.*\\|\\|\\s*$")) then
          ($l | w2m_row) as $c
          | .add = [($c | w2m_cells), ($c | map("---") | w2m_cells)] | .nums = []
      elif ($l | test("^\\s*\\|.*\\|\\s*$")) then .add = [$l | w2m_row | w2m_cells] | .nums = []
      elif $li then w2m_item($li)
      elif $hd then .add = [("#" * ($hd.n | tonumber)) + " " + ($hd.t | w2m_inline)] | .nums = []
      elif $bq then .add = ["> " + ($bq.t | w2m_inline)] | .nums = []
      else .add = [$l | w2m_inline] | .nums = [] end;

def w2m_step($l):
    .add = []
    | if .code then
          if ($l | test("^\\{(code|noformat)\\}$")) then .add = ["```"] | .code = false
          else .add = [$l] end
      elif ($l | test("^\\{(code|noformat)(:.*)?\\}$")) then
          .add = ["```" + ($l | w2m_lang)] | .code = true
      elif ($l | test("^\\{quote\\}$")) then .quote = (.quote | not)
      elif ($l | test("^\\{panel(:.*)?\\}$")) then
          .quote = (.quote | not)
          | ($l | [capture("title=(?<t>[^|}]*)")] | first) as $title
          | if $title then .add = ["**\($title.t)**"] else . end
      else w2m_line($l) end
    | (if .quote then .add |= map("> " + .) else . end)
    | .out += .add;

def wiki2md:
    gsub("\r\n?"; "\n")
    | gsub("\n?(?<o>(?<!\\{)\\{(?:code|noformat|quote|panel)(?::[^}\n]*)?\\}(?!\\}))\n?"; "\n\(.o)\n")
    | ltrimstr("\n") | rtrimstr("\n")
    | split("\n")
    | reduce .[] as $l ({out: [], nums: [], code: false, quote: false, add: []}; w2m_step($l))
    | .out | join("\n");

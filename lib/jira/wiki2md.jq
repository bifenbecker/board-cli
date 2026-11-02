# Jira wiki markup to markdown, best effort. A line at a time, cut at each macro: inside {code} and
# {noformat} only that block's own delimiter means anything. Panels read as quotes, tables as
# markdown tables, a mention as @id. Lines leave through foreach, as in md2wiki.jq.

def w2m_code:
    gsub("&#125;"; "}") | if contains("`") then "`` \(.) ``" else "`\(.)`" end;

def w2m_token:
    if . == "\\\\" then "  \n"
    elif . == "&#92;" then "\\\\"
    elif test("^\\\\(?:h[1-6]|bq)\\.\\s") then .[1:]
    elif test("^\\\\[-+]\\s") then .
    elif startswith("\\") then (if test("^\\\\[{}\\[\\]+-]") then .[1:] else . end)
    elif startswith("{{") then (.[2:-2] | w2m_code)
    elif startswith("[~accountid:") then "@" + .[12:-1]
    elif startswith("[~") then "@" + .[2:-1]
    elif startswith("[^") then .[2:-1]
    elif startswith("[") then
        (.[1:-1] | [splits("(?<!\\\\)\\|")]) as $p
        | if ($p | length) > 1 then "[\($p[0] | gsub("\\\\\\|"; "|"))](\($p[1]))"
          elif ($p[0] | test("^[a-z+]+:")) then "<\($p[0])>"
          else "[\($p[0])]" end
    elif startswith("!") then (.[1:-1] | split("|")[0]) as $u | "![\($u)](\($u))"
    else . end;

def w2m_inline:
    if jira_bare then .
    elif length > jira_line_limit then jira_too_long
    else
    jira_if("{color"; gsub("\\{color(:[^}]*)?\\}"; ""))
    | . as $s
    | reduce ([match("^\\\\(?:h[1-6]|bq)\\.\\s|^\\\\[-+]\\s|\\\\\\\\|\\\\.|&#92;|\\{\\{.+?\\}\\}|\\[~[^\\]]+\\]|\\[\\^[^\\]]+\\]|\\[(?:\\\\.|[^\\]\\\\])+\\]|!(?=[^\\s!])[^\\s!|]+(\\|[^!]*)?!|https?://[^\\s|\\]]+"; "g")] | reverse | .[]) as $m
        ({t: $s, kept: []};
         .t = .t[:$m.offset] + "\(.kept | length)" + .t[$m.offset + $m.length:]
         | .kept += [$m.string | w2m_token])
    | .kept as $kept
    | .t
    | jira_if("*"; gsub("(?<![\\w*])\\*(?=\\S)(?<t>[^*]*?\\S)\\*(?![\\w*])"; "\(.t)"))
    | jira_if("_"; gsub("(?<![\\w_])_(?=\\S)(?<t>[^_]*?\\S)_(?![\\w_])"; "*\(.t)*"))
    | jira_if("-"; gsub("(?<![\\w-])-(?=\\S)(?<t>[^-]*?\\S)-(?![\\w-])"; "~~\(.t)~~"))
    | jira_if("+"; gsub("(?<![\\w+])\\+(?=\\S)(?<t>[^+]*?\\S)\\+(?![\\w+])"; .t))
    | jira_if(""; gsub(""; "**"))
    | jira_if(""; gsub("(?<i>\\d+)"; $kept[.i | tonumber]))
    | rtrimstr("\n")
    end;

# An escaped pipe stays in its cell, and stays escaped: bare, it would end a markdown cell too.
def w2m_row:
    w2m_inline | gsub("^\\s*\\|+|\\|+\\s*$"; "") | [splits("(?<!\\\\)\\|+")] | map(gsub("^\\s+|\\s+$"; ""));

def w2m_cells: "| " + join(" | ") + " |";

# {code:java}, {code:language=java|title=x} and {code:title=x|java}.
def w2m_lang:
    [split("|")[] | select(contains("=") | not), (capture("^language=(?<l>.*)").l)] | first // "";

def w2m_put($x): .add += [(if .quote then "> " else "" end) + $x];

# A number per depth: the markers only say the kind of list.
def w2m_item($li):
    ($li.m | length) as $d
    | ($li.m[:-1] | explode | map(if . == 35 then "   " else "  " end) | join("")) as $indent
    | .nums = ((.nums + [0, 0, 0, 0, 0, 0, 0, 0])[:$d] | .[$d - 1] += 1)
    | w2m_put($indent + (if $li.m[-1:] == "#" then "\(.nums[$d - 1])." else "-" end) + " " + ($li.t | w2m_inline));

def w2m_block_line($l):
    ($l | [capture("^\\s*(?<m>[*#-]+) +(?<t>.*)$")] | first) as $li
    | ($l | [capture("^\\s*h(?<n>[1-6])\\.\\s+(?<t>.*)$")] | first) as $hd
    | ($l | [capture("^\\s*bq\\.\\s+(?<t>.*)$")] | first) as $bq
    | if ($l | test("^\\s*-{4,}\\s*$")) then w2m_put("---") | .nums = []
      elif ($l | test("^\\s*\\|\\|.*\\|\\|\\s*$")) then
          ($l | w2m_row) as $c
          | w2m_put($c | w2m_cells) | w2m_put($c | map("---") | w2m_cells) | .nums = []
      elif ($l | test("^\\s*\\|.*\\|\\s*$")) then w2m_put($l | w2m_row | w2m_cells) | .nums = []
      elif $li then w2m_item($li)
      elif $hd then w2m_put(("#" * ($hd.n | tonumber)) + " " + ($hd.t | w2m_inline)) | .nums = []
      elif $bq then w2m_put("> " + ($bq.t | w2m_inline)) | .nums = []
      else w2m_put($l | w2m_inline) | .nums = [] end;

# Only these can start a line that is more than text.
def w2m_line($l):
    if " \t*#-|hb" | contains($l[:1]) then w2m_block_line($l) else w2m_put($l | w2m_inline) | .nums = [] end;

# The first macro of a line, past what is escaped: pairs are eaten, so \{code} is text and \\{code}
# is a break before a macro. Prints {a, m, p, b}, or null.
def w2m_open:
    if contains("{") | not then null
    elif test("\\{(?:code|noformat|quote|panel)") | not then null
    else [capture("^(?<a>(?:\\\\.|[^\\\\])*?)(?<!\\{)\\{(?<m>code|noformat|quote|panel)(?::(?<p>[^}]*))?\\}(?!\\})(?<b>.*)$")] | first end;

# What is left of a line, in .rest.
def w2m_piece:
    if .rest == null then .
    elif .code then
        .code as $c
        | (.rest | split($c)) as $p
        | if ($p | length) < 2 then w2m_put($p[0] // "") | .rest = null
          else (if $p[0] != "" then w2m_put($p[0]) else . end)
               | w2m_put(.tick) | .code = null
               | .rest = ($p[1:] | join($c) | if . == "" then null else . end)
               | w2m_piece end
    else
        (.rest | w2m_open) as $o
        | if $o == null then w2m_line(.rest) | .rest = null
          else (if $o.a | test("\\S") then w2m_line($o.a) else . end)
               | .rest = (if $o.b == "" then null else $o.b end)
               | if $o.m == "code" or $o.m == "noformat" then
                     .code = "{\($o.m)}"
                     | w2m_put(.tick + (if $o.m == "code" then ($o.p // "" | w2m_lang) else "" end))
                 else
                     .quote = (.quote | not)
                     | (($o.p // "") | [capture("title=(?<t>[^|]*)")] | first) as $title
                     | if $title then w2m_put("**\($title.t)**") else . end
                 end
               | w2m_piece end
    end;

def w2m_step($l):
    .add = [] | .rest = $l
    | if .code == null and ($l | length) > jira_line_limit then w2m_put($l | jira_too_long) | .rest = null
      else w2m_piece end;

# One fence for the whole text, longer than any run of backticks that opens a line in it.
def w2m_fence:
    ([.[] | select(contains("```")) | [capture("^\\s*(?<t>`{3,})").t | length] | first // 0] | max // 0) as $run
    | "`" * ([3, $run + 1] | max);

def wiki2md:
    gsub("\r\n?"; "\n")
    | split("\n") as $lines
    | if $lines | jira_heavy then jira_too_heavy
      else
          [foreach ($lines[], null) as $l
              ({add: [], rest: null, nums: [], code: null, quote: false, tick: ($lines | w2m_fence)};
               if $l == null then .add = (if .code then [.tick] else [] end) else w2m_step($l) end;
               .add[])]
          | join("\n") | rtrimstr("\n")
      end;

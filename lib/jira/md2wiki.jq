# Markdown to Jira wiki markup, best effort. A line at a time, with the open list and code fence as
# state. Code spans and links are set aside first, so emphasis cannot reach inside them.

def m2w_token:
    if startswith("`") then "{{" + .[1:-1] + "}}"
    elif startswith("![") then "!" + capture("\\]\\((?<u>[^)]+)\\)").u + "!"
    elif startswith("[") then
        capture("^\\[(?<t>.*)\\]\\((?<u>[^)]+)\\)$")
        | if .t == .u or .t == "" then "[\(.u)]" else "[\(.t)|\(.u)]" end
    elif startswith("<") then "[" + .[1:-1] + "]"
    else . end;

def m2w_inline:
    . as $s
    | reduce ([match("\\\\[[:punct:]]|`[^`]+`|!\\[[^\\]]*\\]\\([^)\\s]+\\)|\\[[^\\]]*\\]\\([^)\\s]+\\)|<https?://[^>\\s]+>|https?://[^\\s<>)\\]]+"; "g")] | reverse | .[]) as $m
        ({t: $s, kept: []};
         .t = .t[:$m.offset] + "\(.kept | length)" + .t[$m.offset + $m.length:]
         | .kept += [$m.string | m2w_token])
    | .kept as $kept
    | .t
    | gsub("(?<c>[{\\[])"; "\\\(.c)")
    | gsub("\\*\\*(?<t>\\S|\\S.*?\\S)\\*\\*"; "\(.t)")
    | gsub("(?<![\\w_])__(?<t>\\S|\\S.*?\\S)__(?![\\w_])"; "\(.t)")
    | gsub("(?<![\\w*])\\*(?<t>\\S|\\S[^*]*?\\S)\\*(?![\\w*])"; "_\(.t)_")
    | gsub("~~(?<t>\\S|\\S.*?\\S)~~"; "-\(.t)-")
    | gsub(""; "*")
    | gsub("(?<i>\\d+)"; $kept[.i | tonumber]);

def m2w_cells:
    gsub("^\\s*\\||\\|\\s*$"; "") | split("|") | map(gsub("^\\s+|\\s+$"; "") | m2w_inline);

# Depth comes from the indent: everything at or below it closes.
def m2w_item($li):
    ($li.i | length) as $n
    | (if ($li.m | test("\\d")) then "#" else "*" end) as $mark
    | .list = (.list | map(select(.n < $n))) + [{n: $n, mark: $mark}]
    | .out += [(.list | map(.mark) | join("")) + " " + ($li.t | m2w_inline)];

def m2w_text($l):
    ($l | test("(  |\\\\)$")) as $break
    | ($l | sub("(  +|\\\\)$"; "") | m2w_inline) as $text
    | .out += [$text + (if $break then "\\\\" else "" end)];

def m2w_step($l):
    if .fence then
        if ($l | test("^\\s*(```|~~~)\\s*$")) then .out += ["{code}"] | .fence = false
        else .out += [$l] end
    elif ($l | test("^\\s*(```|~~~)")) then
        ($l | gsub("^\\s*[`~]+\\s*|\\s+$"; "")) as $lang
        | .out += [if $lang == "" then "{code}" else "{code:\($lang)}" end]
        | .fence = true | .list = [] | .cells = null
    elif ($l | test("^ {0,3}(-{3,}|\\*{3,}|_{3,}) *$")) then
        .out += ["----"] | .list = [] | .cells = null
    elif .cells and ($l | test("^\\s*\\|(\\s*:?-+:?\\s*\\|)+\\s*$")) then
        .out[-1] = "||" + (.cells | join("||")) + "||"
    elif ($l | test("^\\s*\\|.*\\|\\s*$")) then
        ($l | m2w_cells) as $c | .out += ["|" + ($c | join("|")) + "|"] | .cells = $c | .list = []
    else
        ($l | [capture("^(?<i> *)(?<m>[-*+]|\\d+[.)]) +(?<t>.*)$")] | first) as $li
        | ($l | [capture("^ {0,3}(?<h>#{1,6}) +(?<t>.*?) *#* *$")] | first) as $hd
        | ($l | [capture("^ {0,3}> ?(?<t>.*)$")] | first) as $bq
        | .cells = null
        | if $li then m2w_item($li)
          elif $hd then .out += ["h\($hd.h | length). \($hd.t | m2w_inline)"] | .list = []
          elif $bq then .out += ["bq. \($bq.t | m2w_inline)"] | .list = []
          elif ($l | test("^\\s*$")) then .out += [""] | .list = []
          elif (.list | length) > 0 and ($l | test("^\\s")) then
              .out[-1] += " " + ($l | sub("^\\s+"; "") | m2w_inline)
          else m2w_text($l) | .list = [] end
    end;

def md2wiki:
    gsub("\r\n?"; "\n") | split("\n")
    | reduce .[] as $l ({out: [], list: [], fence: false, cells: null}; m2w_step($l))
    | .out + (if .fence then ["{code}"] else [] end)
    | join("\n");

# Markdown to Jira wiki markup, best effort. A line at a time, with the open list and code block as
# state. Code spans and links are set aside first, so emphasis cannot reach inside them. Lines leave
# through foreach: an array kept in the state would be copied on every line.

# The regexes grow with the square of a line, so a longer line goes out as it came.
def jira_line_limit: 3000;

# jq compiles a regex on every call, near 50 microseconds, so a body with more lines of markup than
# this goes out as it came too. It would take seconds, and a body must not outlast a timeout.
def jira_markup_limit: 3000;

def jira_too_long:
    . as $line | ("board: a line of \(length) characters was left unconverted\n" | stderr) | $line;

def jira_too_heavy:
    . as $text | ("board: a text with this much markup was left unconverted\n" | stderr) | $text;

# True when a line holds nothing inline to convert. No regex, so a plain line costs next to nothing.
def jira_bare:
    (contains("*") or contains("_") or contains("[") or contains("{") or contains("\\") or contains("`")
     or contains("-") or contains("+") or contains("~") or contains("!") or contains("<") or contains("&")
     or contains("|")) | not;

def jira_heavy: map(select(jira_bare | not)) | length > jira_markup_limit;

# Runs a regex step only on a line that holds what it looks for.
def jira_if($s; f): if contains($s) then f else . end;

def m2w_token:
    if startswith("``") then "{{" + (.[2:-2] | ltrimstr(" ") | rtrimstr(" ") | gsub("\\}(?=\\}|$)"; "&#125;")) + "}}"
    elif startswith("`") then "{{" + (.[1:-1] | gsub("\\}(?=\\}|$)"; "&#125;")) + "}}"
    elif startswith("![") then "!" + capture("\\]\\((?<u>[^)]+)\\)").u + "!"
    elif startswith("[") then
        capture("^\\[(?<t>.*)\\]\\((?<u>[^)]+)\\)$")
        | if .t == .u or .t == "" then "[\(.u)]" else "[\(.t | gsub("\\|"; "\\|"))|\(.u)]" end
    elif startswith("<") then "[" + .[1:-1] + "]"
    elif . == "\\\\" then "&#92;"
    else . end;

def m2w_inline:
    if jira_bare then .
    elif length > jira_line_limit then jira_too_long
    else
    . as $s
    | reduce ([match("\\\\[[:punct:]]|``.+?``|`[^`]+`|!\\[[^\\]]*\\]\\([^)\\s]+\\)|\\[[^\\]]*\\]\\([^)\\s]+\\)|<https?://[^>\\s]+>|https?://[^\\s<>)\\]]+"; "g")] | reverse | .[]) as $m
        ({t: $s, kept: []};
         .t = .t[:$m.offset] + "\uE000\(.kept | length)\uE001" + .t[$m.offset + $m.length:]
         | .kept += [$m.string | m2w_token])
    | .kept as $kept
    | .t
    | if contains("{") or contains("[") then gsub("(?<c>[{\\[])"; "\\\(.c)") else . end
    | jira_if("**"; gsub("\\*\\*(?<t>\\S|\\S.*?\\S)\\*\\*"; "\uE002\(.t)\uE002"))
    | jira_if("__"; gsub("(?<![\\w_])__(?<t>\\S|\\S.*?\\S)__(?![\\w_])"; "\uE002\(.t)\uE002"))
    | jira_if("*"; gsub("(?<![\\w*])\\*(?<t>\\S|\\S[^*]*?\\S)\\*(?![\\w*])"; "_\(.t)_"))
    | jira_if("~~"; gsub("~~(?<t>\\S|\\S.*?\\S)~~"; "\uE003\(.t)\uE003"))
    | if contains("-") or contains("+") then
          gsub("(?<![\\w\\\\])(?<d>[-+])(?=\\S)(?<t>[^-+]*?\\S)\\k<d>(?!\\w)"; "\\\(.d)\(.t)\\\(.d)")
      else . end
    | jira_if("\uE003"; gsub("\uE003"; "-"))
    | jira_if("\uE002"; gsub("\uE002"; "*"))
    | jira_if("\uE000"; gsub("\uE000(?<i>\\d+)\uE001"; $kept[.i | tonumber]))
    end;

# Cells end at a pipe that is not escaped.
def m2w_cells:
    gsub("^\\s*\\||\\|\\s*$"; "") | [splits("(?<!\\\\)\\|")] | map(gsub("^\\s+|\\s+$"; "") | m2w_inline);

# Holds a line back, so the next one can still change it: a table header, a wrapped list item.
def m2w_put($x):
    .emit += (if .last == null then [] else [.last] end) | .last = $x;

# Depth comes from the indent: everything at or below it closes.
def m2w_item($li):
    ($li.i | length) as $n
    | (if ($li.m | test("\\d")) then "#" else "*" end) as $mark
    | .list = (.list | map(select(.n < $n))) + [{n: $n, mark: $mark}]
    | m2w_put((.list | map(.mark) | join("")) + " " + ($li.t | m2w_inline));

# A hard break is an odd number of backslashes, or two spaces. Wiki reads more at a line's start
# than markdown does, so what would turn into markup there is escaped.
def m2w_text($l):
    ($l | (endswith(" ") or endswith("\\")) and test("  $|(?:^|[^\\\\])(?:\\\\\\\\)*\\\\$")) as $break
    | (if $break then ($l | sub("(  +|\\\\)$"; "")) else $l end | m2w_inline) as $text
    | ("hb*#-|" | contains($text[:1]) and $text != "") as $maybe
    | m2w_put((if $maybe and ($text | test("^(?:[*#-]+\\s|(?:h[1-6]|bq)\\.\\s|\\|)")) then "\\" else "" end)
              + $text + (if $break then "\\\\" else "" end));

def m2w_fence_open($l):
    if ($l | contains("```") or contains("~~~")) then
        ($l | [capture("^ {0,3}(?<f>`{3,}(?=[^`]*$)|~{3,})\\s*(?<lang>[A-Za-z0-9_+#.-]*)")] | first) as $o
        | if $o == null then null else {c: $o.f[:1], n: ($o.f | length), lang: $o.lang} end
    else null end;

def m2w_step($l; $b):
    .emit = []
    | .fence as $f
    | if $f then
          if ($l | contains($f.c * 3)) and ($l | test("^ {0,3}\($f.c){\($f.n),} *$")) then
              m2w_put(.close) | .fence = null | .blank = false
          else m2w_put($l) end
      elif .ind and ($l == "" or ($l | startswith("    ") or startswith("\t"))) then m2w_put($l)
      elif (.ind | not) and $l == "" then m2w_put("") | .cells = null | .blank = true
      elif (.ind | not) and (" \t|#>-*+_~`0123456789" | contains($l[:1]) | not) then
          m2w_text($l) | .list = [] | .cells = null | .blank = false
      else
          (if .ind then m2w_put(.close) | .ind = false else . end)
          | m2w_fence_open($l) as $open
          | if $open then
                .fence = $open | .list = [] | .cells = null
                | .close = (if $open.lang != "" and ($b.code == "{code}") then "{code}" else $b.code end)
                | m2w_put(if $open.lang != "" and ($b.code == "{code}") then "{code:\($open.lang)}" else $b.code end)
            elif ($l | test("^ {0,3}(-{3,}|\\*{3,}|_{3,}) *$")) then
                m2w_put("----") | .list = [] | .cells = null | .blank = false
            elif .cells and ($l | test("^\\s*\\|(\\s*:?-+:?\\s*\\|)+\\s*$")) then
                .last = "||" + (.cells | join("||")) + "||"
            elif ($l | test("^\\s*\\|.*\\|\\s*$")) then
                ($l | m2w_cells) as $c | m2w_put("|" + ($c | join("|")) + "|") | .cells = $c | .list = [] | .blank = false
            elif .blank and (.list | length) == 0 and ($l | test("^(    |\\t)\\s*\\S")) then
                .ind = true | .close = $b.plain | m2w_put($b.plain) | m2w_put($l)
            else
                ($l | [capture("^(?<i> *)(?<m>[-*+]|\\d+[.)]) +(?<t>.*)$")] | first) as $li
                | ($l | [capture("^ {0,3}(?<h>#{1,6}) +(?<t>.*?) *#* *$")] | first) as $hd
                | ($l | [capture("^ {0,3}> ?(?<t>.*)$")] | first) as $bq
                | ($l | test("^\\s*$")) as $empty
                | .cells = null
                | if $li then m2w_item($li)
                  elif $hd then m2w_put("h\($hd.h | length). \($hd.t | m2w_inline)") | .list = []
                  elif $bq then m2w_put("bq. \($bq.t | m2w_inline)") | .list = []
                  elif $empty then m2w_put("")
                  elif (.list | length) > 0 and ($l | test("^\\s")) then
                      ($l | sub("^\\s+"; "") | m2w_inline) as $more
                      | if .blank then m2w_put($more) else .last += " " + $more end
                  else m2w_text($l) | .list = [] end
                | .blank = $empty
            end
      end;

# A block closes on the first delimiter of its kind, and nothing in it can be escaped, so a text
# holding one needs the other kind. {noformat} has no language.
def m2w_blocks:
    (test("\\{code[:}]")) as $code | contains("{noformat}") as $plain
    | {code: (if $code then "{noformat}" else "{code}" end),
       plain: (if $plain and ($code | not) then "{code}" else "{noformat}" end)};

def md2wiki:
    gsub("\r\n?"; "\n")
    | m2w_blocks as $b
    | split("\n") as $lines
    | if $lines | jira_heavy then jira_too_heavy
      else
          [foreach ($lines[], null) as $l
              ({emit: [], last: null, list: [], fence: null, ind: false, close: null, cells: null, blank: true};
               if $l == null then .emit = (if .last == null then [] else [.last] end)
                                  + (if .fence or .ind then [.close] else [] end)
               else m2w_step($l; $b) end;
               .emit[])]
          | join("\n")
      end;

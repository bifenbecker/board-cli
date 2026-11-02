#!/bin/sh
# Reads workflow.toml: workflow.sh get <dotted.key> [default]
#
#   workflow.sh get git.default_branch
#   workflow.sh get worktree.diff_paths     # arrays come back one element per line
#
# A missing key with no default is an error, so a typo fails loudly instead of becoming "".
set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
file=${WORKFLOW_FILE:-$root/workflow.toml}

[ "${1:-}" = get ] && [ -n "${2:-}" ] || {
    echo "usage: workflow.sh get <dotted.key> [default]" >&2
    exit 2
}
[ -f "$file" ] || {
    echo "workflow.sh: no such file: $file" >&2
    exit 1
}

# Single-line values only: scalars, quoted strings, and one-line arrays.
status=0
value=$(awk -v wanted="$2" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function strip_comment(s,    out, i, c, q) {
        out = ""; q = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (q == "" && (c == "\"" || c == "\047")) q = c
            else if (c == q) q = ""
            else if (c == "#" && q == "") break
            out = out c
        }
        return trim(out)
    }
    function unquote(s) {
        if (s ~ /^".*"$/ || s ~ /^\047.*\047$/) return substr(s, 2, length(s) - 2)
        return s
    }
    { line = trim($0) }
    line == "" || line ~ /^#/ { next }
    line ~ /^\[.*\]/ { section = strip_comment(line); gsub(/^\[|\].*$/, "", section); next }
    index(line, "=") == 0 { next }
    {
        key = trim(substr(line, 1, index(line, "=") - 1))
        if (section != "") key = section "." key
        if (key != wanted) next
        v = strip_comment(substr(line, index(line, "=") + 1))
        if (v ~ /^\[/) {
            if (v !~ /\]$/) { print "workflow.sh: keep arrays on one line" > "/dev/stderr"; exit 3 }
            v = substr(v, 2, length(v) - 2)
            # Split on commas outside quotes, so a quoted item may hold one.
            item = ""; q = ""
            for (i = 1; i <= length(v); i++) {
                c = substr(v, i, 1)
                if (q == "" && (c == "\"" || c == "\047")) q = c
                else if (c == q) q = ""
                else if (c == "," && q == "") { item = trim(item); if (item != "") print unquote(item); item = ""; continue }
                item = item c
            }
            item = trim(item); if (item != "") print unquote(item)
        } else {
            print unquote(v)
        }
        found = 1
        exit
    }
    END { if (!found) exit 4 }
' "$file") || status=$?

case $status in
    0) printf '%s\n' "$value" ;;
    4)
        if [ $# -ge 3 ]; then
            printf '%s\n' "$3"
        else
            echo "workflow.sh: key not found: $2" >&2
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac

# shellcheck shell=sh

# Stand-ins for the provider CLIs. An answer is a file named after the request:
#   $FAKE_OVERRIDE/<key>[.<n>].json, then $FAKE_FIXTURES/<kind>/<key>[.<n>].json
# where n counts calls to that key, for paged answers. <key>.status holds the exit status (the HTTP
# status for curl) and <key>.err the stderr. A request with no answer fails loudly: exit 99.

fake_log() {
    [ -z "${FAKE_LOG:-}" ] || printf '%s\n' "$*" >>"$FAKE_LOG"
}

# Keeps stdin for assertions and prints it.
fake_stdin() {
    fake_in=$(cat)
    [ -z "${FAKE_LOG:-}" ] || printf '%s\n' "$fake_in" >>"$FAKE_LOG.stdin"
    printf '%s' "$fake_in"
}

# The name of the GraphQL operation in a request text.
fake_operation() {
    printf '%s' "$1" | tr '\n' ' ' | sed -n 's/^[^a-z]*[a-z]*[ ]\{1,\}\([A-Za-z0-9_]*\).*/\1/p' | head -n 1
}

fake_counter() {
    fake_dir=${T_TMP:-${TMPDIR:-/tmp}}/.fake
    mkdir -p "$fake_dir"
    fake_count=$(cat "$fake_dir/$1" 2>/dev/null || echo 0)
    fake_count=$((fake_count + 1))
    printf '%s' "$fake_count" >"$fake_dir/$1"
    printf '%s' "$fake_count"
}

# Usage: fake_find <kind> <key>  — sets FAKE_FILE and FAKE_BASE, or leaves them empty.
fake_find() {
    FAKE_FILE=
    FAKE_BASE=
    fake_n=$(fake_counter "$2")
    for fake_d in "${FAKE_OVERRIDE:-}" "$FAKE_FIXTURES/$1"; do
        [ -n "$fake_d" ] || continue
        if [ -f "$fake_d/$2.$fake_n.json" ]; then
            FAKE_FILE=$fake_d/$2.$fake_n.json
            FAKE_BASE=$fake_d/$2
            return 0
        fi
        if [ -f "$fake_d/$2.json" ]; then
            FAKE_FILE=$fake_d/$2.json
            FAKE_BASE=$fake_d/$2
            return 0
        fi
    done
}

# Usage: fake_reply <kind> <key>  — prints the answer and exits with its status.
fake_reply() {
    fake_find "$1" "$2"
    if [ -z "$FAKE_FILE" ]; then
        echo "fake $1: no answer for $2" >&2
        exit 99
    fi
    cat "$FAKE_FILE"
    [ ! -f "$FAKE_BASE.err" ] || cat "$FAKE_BASE.err" >&2
    if [ -f "$FAKE_BASE.status" ]; then
        exit "$(tr -d '\r\n' <"$FAKE_BASE.status")"
    fi
    exit 0
}

# Usage: fake_rest_key <method> <path>
fake_rest_key() {
    printf '%s_%s' "$1" "${2%%\?*}" | sed 's/[^A-Za-z0-9.-]\{1,\}/_/g; s/_$//'
}

# The words of a command up to its first flag, joined by _.
fake_words() {
    fake_key=
    for fake_a in "$@"; do
        case $fake_a in
            -*) break ;;
        esac
        fake_key="${fake_key}${fake_key:+_}$fake_a"
    done
    printf '%s' "$fake_key"
}

#!/bin/sh
# Installs board: curl -fsSL https://raw.githubusercontent.com/bifenbecker/board-cli/main/install.sh | sh
set -eu

BOARD_REPO_SLUG=bifenbecker/board-cli

usage() {
    cat <<'EOF'
Usage: install.sh [--prefix <dir>] [--version <tag>] [--from <dir>] [--uninstall]

Installs board into <prefix>/share/board and a board command into <prefix>/bin.

  --prefix <dir>    Where to install (default: ~/.local)
  --version <tag>   Release to install, e.g. v0.1.0 (default: the latest release)
  --from <dir>      Install from a local checkout instead of downloading
  --uninstall       Remove board from <prefix>
  -h, --help        Show this help

Requires: sh, tar, and curl or wget. board itself needs jq, curl, and the CLI of your board: linear, gh or glab.
EOF
}

say() {
    printf 'board-install: %s\n' "$*"
}

die() {
    printf 'board-install: %s\n' "$*" >&2
    exit 1
}

prefix=${BOARD_PREFIX:-}
prefix_given=${BOARD_PREFIX:+1}
version=
from=
uninstall=
while [ $# -gt 0 ]; do
    case $1 in
        --prefix) [ $# -ge 2 ] || die "--prefix needs a value"; prefix=$2; prefix_given=1; shift 2 ;;
        --version) [ $# -ge 2 ] || die "--version needs a value"; version=$2; shift 2 ;;
        --from) [ $# -ge 2 ] || die "--from needs a value"; from=$2; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

if [ -z "$prefix_given" ]; then
    [ -n "${HOME:-}" ] || die "HOME is not set; pass --prefix <dir>"
    prefix=$HOME/.local
fi
# Empty would mean /share and /bin. It comes from an unset variable, never from intent.
[ -n "$prefix" ] || die "--prefix is empty"

# A relative prefix would be written into the wrapper and break it everywhere else.
case $prefix in
    /* | [A-Za-z]:[/\]*) ;;
    *) mkdir -p "$prefix" && prefix=$(CDPATH='' cd -- "$prefix" && pwd) ;;
esac

home="$prefix/share/board"
bin="$prefix/bin/board"
MARKER=.board-install

# Only what install.sh wrote is removed: the wrapper names BOARD_HOME, the home carries the
# marker and is not a git checkout. Both are checked before either is deleted.
check_ours() {
    if [ -e "$bin" ]; then
        # The exec line is the wrapper's alone: a checkout's bin/board mentions BOARD_HOME too.
        grep -qx 'exec sh "$BOARD_HOME/bin/board" "$@"' "$bin" 2>/dev/null ||
            die "$bin was not installed by board; not touching it"
    fi
    if [ -e "$home" ]; then
        [ -f "$home/$MARKER" ] && [ ! -e "$home/.git" ] ||
            die "$home was not installed by install.sh; not touching it"
    fi
}

remove_install() {
    check_ours
    if [ -e "$bin" ]; then
        rm -f "$bin"
        say "removed $bin"
    fi
    if [ -e "$home" ]; then
        rm -rf "$home"
        say "removed $home"
    fi
}

if [ -n "$uninstall" ]; then
    [ -e "$bin" ] || [ -e "$home" ] || die "board is not installed in $prefix"
    remove_install
    exit 0
fi

fetch() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$1"
    else
        die "curl or wget is required"
    fi
}

# Empty output means the repository has no release yet. A failure to ask is fatal: guessing
# "no release" would install unreleased code.
latest_tag() {
    if command -v curl >/dev/null 2>&1; then
        latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$BOARD_REPO_SLUG/releases/latest") ||
            die "cannot reach GitHub to find the latest release; pass --version <tag>"
        case $latest_url in
            */releases/tag/*) printf '%s' "${latest_url##*/releases/tag/}" ;;
        esac
    else
        latest_json=$(fetch "https://api.github.com/repos/$BOARD_REPO_SLUG/releases?per_page=1") ||
            die "cannot reach GitHub to find the latest release; pass --version <tag>"
        printf '%s\n' "$latest_json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
    fi
}

work=$(mktemp -d 2>/dev/null) || die "cannot create a temporary directory"
trap 'rm -rf "$work"' EXIT

if [ -n "$from" ]; then
    [ -f "$from/bin/board" ] && [ -f "$from/VERSION" ] || die "$from is not a board checkout"
    src=$(CDPATH='' cd -- "$from" && pwd)
else
    command -v tar >/dev/null 2>&1 || die "tar is required"
    [ -n "$version" ] || version=$(latest_tag)
    if [ -n "$version" ]; then
        url="https://github.com/$BOARD_REPO_SLUG/archive/refs/tags/$version.tar.gz"
    else
        say "the repository has no release yet; installing the main branch"
        url="https://github.com/$BOARD_REPO_SLUG/archive/refs/heads/main.tar.gz"
    fi
    say "downloading $url"
    fetch "$url" >"$work/board.tar.gz" || die "download failed: $url"
    tar -xzf "$work/board.tar.gz" -C "$work" || die "cannot unpack $url"
    src=$(find "$work" -mindepth 2 -maxdepth 2 -type f -name VERSION -exec dirname {} \; | head -n 1)
    [ -n "$src" ] && [ -f "$src/bin/board" ] || die "the archive does not contain board"
fi

check_ours

stage="$work/stage"
mkdir -p "$stage"
for item in bin lib VERSION install.sh LICENSE README.md; do
    [ ! -e "$src/$item" ] || cp -R "$src/$item" "$stage/"
done
: >"$stage/$MARKER"

mkdir -p "$prefix/share" "$prefix/bin" || die "cannot write to $prefix"
[ ! -e "$home" ] && [ ! -e "$bin" ] || remove_install
mv "$stage" "$home"

quoted_home=$(printf '%s' "$home" | sed "s/'/'\\\\''/g")
cat >"$bin" <<EOF
#!/bin/sh
BOARD_HOME='$quoted_home'
export BOARD_HOME
exec sh "\$BOARD_HOME/bin/board" "\$@"
EOF
chmod +x "$bin" "$home/bin/board"

say "installed board $(tr -d '\r\n' <"$home/VERSION") into $home"
case ":$PATH:" in
    *":$prefix/bin:"*) ;;
    *) say "add $prefix/bin to PATH:  export PATH=\"$prefix/bin:\$PATH\"" ;;
esac
for tool in jq curl; do
    command -v "$tool" >/dev/null 2>&1 || say "warning: $tool is not installed; board needs it"
done

# shellcheck shell=sh disable=SC2317,SC2329

# install.sh and board self update, with curl stubbed: nothing here reaches GitHub.

# Usage: stub_curl <body>  — a curl first on PATH that runs <body> with curl's arguments.
stub_curl() {
    mkdir -p "$T_TMP/stub"
    {
        printf '#!/bin/sh\n'
        printf '%s\n' "$1"
    } >"$T_TMP/stub/curl"
    chmod +x "$T_TMP/stub/curl"
    PATH=$T_TMP/stub:$PATH
    export PATH
}

test_install_adds_v_to_a_bare_version() {
    stub_curl 'exit 22'
    t_run sh "$BOARD_TEST_ROOT/install.sh" --prefix "$T_TMP/p" --version 0.2.0
    t_status 1
    t_contains "$T_ERR" 'archive/refs/tags/v0.2.0.tar.gz'
}

test_install_keeps_a_tag_with_v() {
    stub_curl 'exit 22'
    t_run sh "$BOARD_TEST_ROOT/install.sh" --prefix "$T_TMP/p" --version v0.2.0
    t_status 1
    t_contains "$T_ERR" 'archive/refs/tags/v0.2.0.tar.gz'
    t_lacks "$T_ERR" vv0
}

# A native Windows curl run with path conversion off opens no path of sh, not even /dev/null.
test_install_finds_the_latest_release_without_a_file_for_curl() {
    stub_curl '
for a; do
    case $a in
        -o | --output | -D | --dump-header | -*o) echo "curl: (23) client returned ERROR on write" >&2; exit 23 ;;
    esac
done
case " $* " in
    *" -w "*) printf "HTTP/2 302\r\nlocation: x\r\n\r\nHTTP/2 200\r\n\r\n\nhttps://github.com/bifenbecker/board-cli/releases/tag/v9.9.9" ;;
    *) exit 22 ;;
esac'
    t_run sh "$BOARD_TEST_ROOT/install.sh" --prefix "$T_TMP/p"
    t_status 1
    t_lacks "$T_ERR" 'cannot reach GitHub'
    t_contains "$T_ERR" 'archive/refs/tags/v9.9.9.tar.gz'
}

test_self_update_runs_install_without_board_settings() {
    t_run sh "$BOARD_TEST_ROOT/install.sh" --from "$BOARD_TEST_ROOT" --prefix "$T_TMP/p"
    t_status 0
    # The downloaded install.sh reports what it was given instead of installing.
    stub_curl "cat <<'EOF'
printf 'msys=[%s%s]\\n' \"\${MSYS_NO_PATHCONV-}\" \"\${MSYS2_ARG_CONV_EXCL-}\"
printf 'args=%s\\n' \"\$*\"
EOF"
    t_run sh "$T_TMP/p/bin/board" self update --version 0.2.0
    t_status 0
    t_contains "$T_OUT" 'msys=[]'
    t_contains "$T_OUT" '--version 0.2.0'
}

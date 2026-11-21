#!/usr/bin/env bats
# luti_url, luti_safe_url and luti_open_url (bash/lib/open.sh).

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
	lt_load_lib
	luti_connect https://x.test "" v4
	BIN="$BATS_TEST_TMPDIR/bin"
	mkdir -p "$BIN"
}

# launcher NAME: a fake launcher that records its arguments in $BIN/NAME.args
launcher() {
	printf '#!/bin/sh\nprintf "%%s\\n" "$@" >"%s/%s.args"\n' "$BIN" "$1" >"$BIN/$1"
	chmod +x "$BIN/$1"
}

waitfor() { for _ in $(seq 20); do [[ -s $1 ]] && return 0; sleep 0.1; done; return 1; }

@test "page URLs need no request" {
	[ "$(luti_url post 5)" = https://x.test/post/5 ]
	[ "$(luti_url comment 7)" = https://x.test/comment/7 ]
	[ ! -e "$STUB_DIR/calls" ]
	run luti_url post x
	[ "$status" -ne 0 ]
	run luti_url comment 7 link
	[ "$status" -ne 0 ]
}

@test "link, media and origin come from the post" {
	stub_respond 200 "$(jq -c '.post_view.post += {url: "https://e.test/a.png", thumbnail_url: "https://e.test/t.jpg"}' "$FIXTURES/v4/post_get.json")"
	[ "$(luti_url post 6 link)" = https://e.test/a.png ]
	[ "$(luti_url post 6 media)" = https://e.test/a.png ]
	[ "$(luti_url post 6 origin)" = http://lemmy10.localhost/post/6 ]
	stub_respond 200 "$(jq -c '.post_view.post += {url: "https://e.test/page", thumbnail_url: "https://e.test/t.jpg"}' "$FIXTURES/v4/post_get.json")"
	[ "$(luti_url post 6 media)" = https://e.test/t.jpg ]
	stub_respond 200 "$(cat "$FIXTURES/v4/post_get.json")"
	run luti_url post 6 link
	[ "$status" -ne 0 ]
	[[ $output == *"has no link"* ]]
}

@test "only http(s) URLs are accepted" {
	luti_safe_url https://a.test/x
	luti_safe_url HTTP://a.test
	local bad
	for bad in "file:///etc/passwd" "javascript:alert(1)" "-x" "https://" "https://a.test/ b" $'https://a.test/\nx' "ftp://a.test" ""; do
		refute luti_safe_url "$bad"
		BROWSER=true run luti_open_url "$bad"
		[ "$status" -eq 2 ]
		[[ $output == *"refusing to open"* ]]
	done
}

@test "xdg-open gets the URL as one argument" {
	launcher xdg-open
	BROWSER="" PATH="$BIN:$PATH" luti_open_url 'https://a.test/?q=1&r=$(id)'
	waitfor "$BIN/xdg-open.args"
	[ "$(cat "$BIN/xdg-open.args")" = 'https://a.test/?q=1&r=$(id)' ]
}

@test "\$BROWSER wins, with arguments and a :-separated fallback list" {
	launcher mybrowser
	launcher xdg-open
	BROWSER="nosuchbrowser:mybrowser --new-tab" PATH="$BIN:$PATH" luti_open_url https://a.test/p
	waitfor "$BIN/mybrowser.args"
	[ "$(cat "$BIN/mybrowser.args")" = $'--new-tab\nhttps://a.test/p' ]
	[ ! -e "$BIN/xdg-open.args" ]
}

@test "no launcher: prints the URL and returns 1" {
	mkdir -p "$BATS_TEST_TMPDIR/empty"
	for t in jq uname; do ln -sf "$(command -v "$t")" "$BATS_TEST_TMPDIR/empty/$t"; done
	BROWSER="" PATH="$BATS_TEST_TMPDIR/empty" run luti_open_url https://a.test/p
	[ "$status" -eq 1 ]
	[ "${lines[-1]}" = https://a.test/p ]
}

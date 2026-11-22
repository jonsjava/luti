#!/usr/bin/env bats
# bash/lib/luti.sh as a library: sourcing is side-effect free.

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
}

@test "sourcing in a clean shell under set -u defines only luti names and changes nothing else" {
	run env -i PATH="$PATH" HOME="$HOME" bash --norc --noprofile -c '
		set -u
		f0=$(compgen -A function | sort)
		v0=$(compgen -v | sort)
		o0="$-|$(set -o)|$(shopt -p)"
		i0=$(printf %q "$IFS")
		t0=$(trap -p)
		u0=$(umask)
		d0=$PWD
		. "$1" || exit 9
		f1=$(compgen -A function | sort)
		v1=$(compgen -v | sort)
		echo "FUNCS: $(comm -13 <(printf "%s\n" "$f0") <(printf "%s\n" "$f1") | grep -v "^_\{0,1\}luti_" | tr "\n" " ")"
		echo "VARS: $(comm -13 <(printf "%s\n" "$v0") <(printf "%s\n" "$v1") | grep -Ev "^(LUTI_|f0|v0|o0|i0|t0|u0|d0|f1|_$|BASH_|PIPESTATUS$)" | tr "\n" " ")"
		[[ "$-|$(set -o)|$(shopt -p)" == "$o0" ]] && echo OPTS same
		[[ $(printf %q "$IFS") == "$i0" ]] && echo IFS same
		[[ $(trap -p) == "$t0" ]] && echo TRAPS same
		[[ $(umask) == "$u0" && $PWD == "$d0" ]] && echo ENV same
		[[ $(compgen -A function | grep -c "^luti_") -gt 40 ]] && echo PUBLIC ok
	' _ "$REPO_ROOT/bash/lib/luti.sh"
	[ "$status" -eq 0 ]
	[ "${lines[0]}" = "FUNCS: " ]
	[ "${lines[1]}" = "VARS: " ]
	[ "${lines[2]}" = "OPTS same" ]
	[ "${lines[3]}" = "IFS same" ]
	[ "${lines[4]}" = "TRAPS same" ]
	[ "${lines[5]}" = "ENV same" ]
	[ "${lines[6]}" = "PUBLIC ok" ]
}

@test "sourcing makes no request, reads no config and does not exit on errors" {
	mkdir -p "$XDG_CONFIG_HOME/luti/default"
	printf 'instance="https://cfg.test"\n' >"$XDG_CONFIG_HOME/luti/default/config"
	run bash -c '. "$1"; echo "inst=[$LUTI_INSTANCE]"; luti_post_get abc; echo "rc=$?"; luti_api post.list; echo "rc=$?"' _ "$REPO_ROOT/bash/lib/luti.sh"
	[ "$status" -eq 0 ]
	[[ $output == *"inst=[]"* ]]
	[[ $output == *"expected a numeric id"*"rc=1"* ]]
	[[ $output == *"no instance set"*"rc=2"* ]]
	[ ! -e "$STUB_DIR/calls" ]
}

@test "settings from the environment are kept; the spec is found from any directory" {
	run bash -c 'cd /; LUTI_INSTANCE=https://env.test LUTI_API=v4 LUTI_TOKEN=t; . "$1"; luti_post_list "{\"limit\": 1}" >/dev/null; echo "$LUTI_INSTANCE $LUTI_API"' _ "$REPO_ROOT/bash/lib/luti.sh"
	[ "$status" -eq 0 ]
	[ "$output" = "https://env.test v4" ]
	[ "$(cat "$STUB_DIR/calls")" = "GET https://env.test/api/v4/post/list?limit=1" ]
}

@test "data functions print the common shape, or raw JSON with LUTI_RAW=1" {
	lt_load_lib
	luti_connect https://x.test "" v4
	stub_respond 200 "$(cat "$FIXTURES/v4/post_list.json")"
	run luti_post_list '{"limit": 2}'
	[ "$(jq -c '[(.items | map(.id)), .next]' <<<"$output")" = '[[3,6],"BU0KBxiIGgGjd-BKyU0KBxiIGZ"]' ]
	LUTI_RAW=1 run luti_post_list '{"limit": 2}'
	jq -e '.items[0].post_view // .items[0].post | .id == 3' <<<"$output"
	luti_connect https://x.test "" v3
	stub_respond 200 "$(cat "$FIXTURES/v3/post_list.json")"
	run luti_post_list '{"limit": 2, "page": 4}'
	[ "$(jq -c '[(.items | map(.id)), .next]' <<<"$output")" = '[[3,6],5]' ]
	[[ $(tail -1 "$STUB_DIR/calls") == *"page=4"* ]]
}

@test "the CLI is not needed: luti.sh does not define cli_ functions" {
	lt_load_lib
	refute declare -F cli_main
	refute declare -F cli_jq
	[ ! -e "$REPO_ROOT/bash/lib/display.jq" ]
}

@test "make install/uninstall honor PREFIX and DESTDIR; the installed copy finds lib, cli and spec" {
	command -v make >/dev/null || skip "make not installed"
	local d="$BATS_TEST_TMPDIR/pkg" p=/opt/luti
	make -s -C "$REPO_ROOT/bash" install DESTDIR="$d" PREFIX="$p"
	[ -x "$d$p/bin/luti" ]
	[ -f "$d$p/share/luti/lib/luti.sh" ] && [ -f "$d$p/share/luti/cli/display.jq" ] && [ -f "$d$p/share/luti/spec/endpoints.json" ]
	ln -s "$d$p/bin/luti" "$BATS_TEST_TMPDIR/luti-link"
	run env -u LUTI_SPEC "$BATS_TEST_TMPDIR/luti-link" --version
	[[ $output == "luti "* ]]
	lt_write_profile default https://x.test v4
	run env -u LUTI_SPEC "$d$p/bin/luti" feed --limit 1
	[ "$status" -eq 0 ]
	[ "$(cat "$STUB_DIR/calls")" = "GET https://x.test/api/v4/post/list?limit=1" ]
	make -s -C "$REPO_ROOT/bash" uninstall DESTDIR="$d" PREFIX="$p"
	[ ! -e "$d$p/bin/luti" ] && [ ! -e "$d$p/share/luti" ]
}

#!/usr/bin/env bats
# Stars and the stargaze queue (bash/lib/stars.sh) with a stubbed server.

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
	lt_load_lib
	luti_connect https://x.test tok v4
	STARS="$XDG_CONFIG_HOME/luti/default/stars"
	GAZE="$XDG_STATE_HOME/luti/default/stargaze"
	# person.get answers with alice; post.list with posts 3 (alice) and 6 (bob),
	# so every user "has" both posts in this stub.
	stub_route "GET api/v4/person" "$(cat "$FIXTURES/v4/person_get.json")"
	stub_route "GET api/v4/post/list" '{"items":[]}'
}

posts() { # posts ID... -> v4 post.list response by alice
	jq -c --argjson ids "$(printf '%s\n' "$@" | jq -sc .)" \
		'.items[0] as $p | {items: [$ids | sort | reverse | .[] as $i | $p | .post.id = $i]}' "$FIXTURES/v4/post_list.json"
}

@test "stars file: comments and blanks are ignored, names are written sorted and unique" {
	mkdir -p "$(dirname "$STARS")"
	printf '# my stars\n\nzed@b.test   # trailing comment\r\n  bob@a.test\nbob@a.test\n' >"$STARS"
	run luti_stars_list
	[ "$(jq -c 'map(.user)' <<<"$output")" = '["bob@a.test","zed@b.test"]' ]
	luti_stars_remove zed >/dev/null
	[ "$(cat "$STARS")" = $'# my stars\nbob@a.test' ]
	[ "$(stat -c %a "$STARS")" = 600 ]
	ls "$(dirname "$STARS")" | refute grep -q 'stars\.'
}

@test "star add qualifies the name and sets the baseline to the newest post" {
	stub_route "GET api/v4/post/list" "$(posts 10 12)"
	run luti_stars_add alice
	[ "$status" -eq 0 ]
	[ "$(jq -c . <<<"$output")" = '[{"user":"alice@lemmy10.localhost","last_seen":12}]' ]
	[ "$(cat "$STARS")" = alice@lemmy10.localhost ]
	[ "$(cat "$GAZE")" = $'alice@lemmy10.localhost\t12' ]
	grep -q 'creator_username=alice%40lemmy10.localhost' "$STUB_DIR/calls"
	grep -q 'sort=new' "$STUB_DIR/calls"
	# Adding again keeps the baseline.
	stub_route "GET api/v4/post/list" "$(posts 10 12 14)"
	luti_stars_add alice >/dev/null
	[ "$(cut -f2 "$GAZE")" = 12 ]
}

@test "--backfill N queues the N latest posts" {
	stub_route "GET api/v4/post/list" "$(posts 10 11 12)"
	luti_stars_add --backfill 2 alice >/dev/null
	[ "$(cut -f2 "$GAZE")" = 10 ]
	run luti_stargaze_poll --peek
	[ "$(jq -c '.items | map(.id)' <<<"$output")" = '[11,12]' ]
}

@test "a user with no posts gets baseline 0" {
	luti_stars_add alice >/dev/null
	[ "$(cut -f2 "$GAZE")" = 0 ]
}

@test "unread: posts newer than last_seen, oldest first; peek keeps them, poll marks them" {
	stub_route "GET api/v4/post/list" "$(posts 10)"
	luti_stars_add alice >/dev/null
	stub_route "GET api/v4/post/list" "$(posts 10 11 13)"
	run luti_stargaze_poll --peek
	[ "$(jq -c '.items | map([.id, .star])' <<<"$output")" = '[[11,"alice@lemmy10.localhost"],[13,"alice@lemmy10.localhost"]]' ]
	run luti_stars_list
	[ "$(jq -c '.[0].last_seen' <<<"$output")" = 10 ]
	run luti_stargaze_poll --limit 1
	[ "$(jq -c '.items | map(.id)' <<<"$output")" = '[11]' ]
	[ "$(cut -f2 "$GAZE")" = 11 ]
	run luti_stargaze_poll
	[ "$(jq -c '.items | map(.id)' <<<"$output")" = '[13]' ]
	run luti_stargaze_poll
	[ "$(jq -c '.items' <<<"$output")" = '[]' ]
	run luti_stargaze_poll --all
	[ "$(jq -c '.items | map(.id)' <<<"$output")" = '[13,11,10]' ]
}

@test "mark never moves last_seen backwards; clear empties the queue" {
	stub_route "GET api/v4/post/list" "$(posts 10)"
	luti_stars_add alice >/dev/null
	luti_stargaze_mark alice 20
	luti_stargaze_mark alice 15
	[ "$(cut -f2 "$GAZE")" = 20 ]
	stub_route "GET api/v4/post/list" "$(posts 20 21 22)"
	luti_stargaze_clear
	[ "$(cut -f2 "$GAZE")" = 22 ]
	run luti_stargaze_mark alice x
	[ "$status" -ne 0 ]
}

@test "unknown users: add fails with a message, poll only warns" {
	stub_route "GET api/v4/person" '{"error":"not_found"}'
	printf 404 >"$STUB_DIR/code"
	run luti_stars_add ghost
	[ "$status" -ne 0 ]
	[[ $output == *"unknown user 'ghost'"* ]]
	[ ! -e "$STARS" ] || refute grep -q ghost "$STARS"
	mkdir -p "$(dirname "$STARS")"
	printf 'ghost@x.test\n' >"$STARS"
	stub_respond 404 '{"error":"not_found"}'
	rm -rf "$STUB_DIR/routes"
	run luti_stargaze_poll --peek
	[ "$status" -eq 0 ]
	[[ $output == *"warning: cannot fetch posts of ghost@x.test"* ]]
	[[ ${lines[-1]} == '{"items":[]}' ]]
}

@test "remove matches a bare name only when it is unique" {
	mkdir -p "$(dirname "$STARS")"
	printf 'bob@a.test\nbob@b.test\ncarol@a.test\n' >"$STARS"
	run luti_stars_remove bob
	[ "$status" -ne 0 ]
	run luti_stars_remove bob@b.test carol
	[ "$status" -eq 0 ]
	[ "$(jq -c . <<<"$output")" = '["bob@b.test","carol@a.test"]' ]
	[ "$(cat "$STARS")" = bob@a.test ]
}

@test "v3 fetches posts with person.get sort=New" {
	luti_connect https://x.test tok v3
	stub_route "GET api/v3/user" "$(jq -c '.posts = [.posts[0] // empty]' "$FIXTURES/v3/person_get.json")"
	luti_stars_add alice >/dev/null
	[ "$(cat "$STARS")" = alice@lemmy019.localhost ]
	grep -q 'GET https://x.test/api/v3/user?.*sort=New' "$STUB_DIR/calls"
}

#!/usr/bin/env bats
# New-item detection (luti_watch_diff, luti_watch_poll).

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
	lt_load_lib
	STATE="$BATS_TEST_TMPDIR/state/w"
}

items() { # items KEY... -> watch items JSON
	printf '%s\n' "$@" | jq -Rsc 'split("\n") | map(select(. != "") | {key: ., id: (split(":")[1] | tonumber)})'
}

@test "first poll is a baseline: nothing is new and the state is written" {
	run luti_watch_diff "$STATE" <<<"$(items post:1 comment:2)"
	[ "$status" -eq 0 ]
	[ "$(jq -c '[.baseline, (.new | length), .pending]' <<<"$output")" = '[true,0,2]' ]
	[ "$(cat "$STATE")" = $'post:1\ncomment:2' ]
}

@test "a new item is detected by id" {
	luti_watch_diff "$STATE" <<<"$(items post:1)" >/dev/null
	run luti_watch_diff "$STATE" <<<"$(items post:1 post:5)"
	[ "$(jq -c '[.baseline, (.new | map(.key)), .pending]' <<<"$output")" = '[false,["post:5"],2]' ]
	run luti_watch_diff "$STATE" <<<"$(items post:1 post:5)"
	[ "$(jq -c '.new' <<<"$output")" = '[]' ]
}

@test "one resolved and one new: count unchanged, still detected" {
	luti_watch_diff "$STATE" <<<"$(items post:1 post:2)" >/dev/null
	run luti_watch_diff "$STATE" <<<"$(items post:2 post:3)"
	[ "$(jq -c '[(.new | map(.key)), .pending]' <<<"$output")" = '[["post:3"],2]' ]
}

@test "empty result, then the same id again counts as new" {
	luti_watch_diff "$STATE" <<<"$(items post:1)" >/dev/null
	run luti_watch_diff "$STATE" <<<"[]"
	[ "$(jq -c '[.baseline, .new, .pending]' <<<"$output")" = '[false,[],0]' ]
	[ ! -s "$STATE" ]
	run luti_watch_diff "$STATE" <<<"$(items post:1)"
	[ "$(jq -c '.new | map(.key)' <<<"$output")" = '["post:1"]' ]
}

@test "duplicate keys count once" {
	luti_watch_diff "$STATE" <<<"[]" >/dev/null
	run luti_watch_diff "$STATE" <<<"$(items post:4 post:4)"
	[ "$(jq -c '[(.new | length), .pending]' <<<"$output")" = '[1,1]' ]
}

@test "luti_watch_poll tags items with kind and key, needs a token and a state file" {
	luti_connect https://x.test "" v4
	run luti_watch_poll reports "$STATE"
	[ "$status" -eq 4 ]
	LUTI_TOKEN=tok
	run luti_watch_poll reports
	[ "$status" -eq 2 ]
	run luti_watch_poll nonsense "$STATE"
	[ "$status" -eq 2 ]
	stub_route "GET api/v4/report/list" "$(jq -c '{items: [.post.items[0]]}' "$FIXTURES/v4/reports.json")"
	run luti_watch_poll reports "$STATE"
	[ "$(jq -c '[.kind, .baseline, .pending, .items[0].watch, .items[0].key]' <<<"$output")" = '["reports",true,1,"reports","post:2"]' ]
	stub_route "GET api/v4/account/notification/list" "$(cat "$FIXTURES/v4/inbox.json")"
	run luti_watch_poll inbox "$STATE.inbox"
	jq -e '.kind == "inbox" and (.items | length > 0) and (.items | all(.watch == "inbox" and (.key | test("^[a-z_]+:[0-9]+$"))))' <<<"$output"
}

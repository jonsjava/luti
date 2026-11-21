#!/usr/bin/env bats
# Request transforms in luti.jq: enum case, sort/time, vote, pagination, next page.

setup() {
	load test_helper
	lt_load_lib
}

@test "enums are PascalCase on v3 and snake_case on v4" {
	LUTI_API=v3
	[ "$(_luti_enum most_comments)" = MostComments ]
	[ "$(_luti_enum moderator_view)" = ModeratorView ]
	[ "$(_luti_enum local)" = Local ]
	LUTI_API=v4
	[ "$(_luti_enum most_comments)" = most_comments ]
	[ "$(_luti_enum ModeratorView)" = moderator_view ]
	[ "$(_luti_enum TopSixHour)" = top_six_hour ]
}

@test "top + time becomes TopDay on v3" {
	LUTI_API=v3
	[ "$(_luti_sort_json top day)" = '{"sort":"TopDay"}' ]
	[ "$(_luti_sort_json top six_hour)" = '{"sort":"TopSixHour"}' ]
	[ "$(_luti_sort_json top)" = '{"sort":"TopAll"}' ]
	[ "$(_luti_sort_json hot)" = '{"sort":"Hot"}' ]
	[ "$(_luti_sort_json most_comments)" = '{"sort":"MostComments"}' ]
	[ "$(_luti_sort_json top_week)" = '{"sort":"TopWeek"}' ]
	[ "$(_luti_sort_json "" "")" = '{}' ]
}

@test "top + time becomes sort=top and time_range_seconds on v4" {
	LUTI_API=v4
	[ "$(_luti_sort_json top day)" = '{"sort":"top","time_range_seconds":86400}' ]
	[ "$(_luti_sort_json top year)" = '{"sort":"top","time_range_seconds":31536000}' ]
	[ "$(_luti_sort_json top all)" = '{"sort":"top"}' ]
	[ "$(_luti_sort_json top)" = '{"sort":"top"}' ]
	[ "$(_luti_sort_json Hot)" = '{"sort":"hot"}' ]
	[ "$(_luti_sort_json TopMonth)" = '{"sort":"top","time_range_seconds":2592000}' ]
}

@test "unknown time range is an error with a plain message" {
	LUTI_API=v4
	run _luti_sort_json top fortnight
	[ "$status" -ne 0 ]
	[[ $output == "luti: unknown time 'fortnight'"* ]]
}

@test "votes map to score on v3 and is_upvote on v4" {
	LUTI_API=v3
	[ "$(_luti_vote_json up)" = '{"score":1}' ]
	[ "$(_luti_vote_json down)" = '{"score":-1}' ]
	[ "$(_luti_vote_json clear)" = '{"score":0}' ]
	LUTI_API=v4
	[ "$(_luti_vote_json up)" = '{"is_upvote":true}' ]
	[ "$(_luti_vote_json down)" = '{"is_upvote":false}' ]
	[ "$(_luti_vote_json clear)" = '{"is_upvote":null}' ]
	run _luti_vote_json sideways
	[ "$status" -ne 0 ]
}

@test "pagination: page on v3, cursor on v4, next on both" {
	LUTI_API=v3
	[ "$(_luti_page_json '{"page":3}')" = '{"page":3}' ]
	[ "$(_luti_page_json '{"next":4}')" = '{"page":4}' ]
	[ "$(_luti_page_json '{}')" = '{}' ]
	run _luti_page_json '{"cursor":"abc"}'
	[ "$status" -ne 0 ]
	LUTI_API=v4
	[ "$(_luti_page_json '{"cursor":"abc"}')" = '{"page_cursor":"abc"}' ]
	[ "$(_luti_page_json '{"next":"abc"}')" = '{"page_cursor":"abc"}' ]
	run _luti_page_json '{"page":2}'
	[ "$status" -ne 0 ]
}

@test "next page: v3 page number, v4 cursor, null at the end" {
	np() { jq -c -L "$REPO_ROOT/bash/lib" --arg v "$1" --argjson req "$2" --argjson n "$3" 'include "luti"; next_page($v; $req; $n)' <<<"$4"; }
	[ "$(np v3 '{"page":2}' 5 '{}')" = 3 ]
	[ "$(np v3 '{}' 5 '{}')" = 2 ]
	[ "$(np v3 '{"page":2}' 0 '{}')" = null ]
	[ "$(np v4 '{}' 1 '{"next_page":"Xyz"}')" = '"Xyz"' ]
	[ "$(np v4 '{}' 0 '{}')" = null ]
	[ "$(np v4 '{}' 3 '{"next_page":"none,none,none"}')" = null ]
}

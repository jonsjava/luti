#!/usr/bin/env bats
# Enum case, sort/time, vote and pagination transforms (bash/lib/transform.sh).

setup() {
	load test_helper
	lt_load_lib
}

@test "snake and pascal case conversion" {
	[ "$(lt_pascal most_comments)" = MostComments ]
	[ "$(lt_pascal moderator_view)" = ModeratorView ]
	[ "$(lt_pascal hot)" = Hot ]
	[ "$(lt_snake MostComments)" = most_comments ]
	[ "$(lt_snake TopSixHour)" = top_six_hour ]
	[ "$(lt_snake new_comments)" = new_comments ]
}

@test "enums are PascalCase on v3 and snake_case on v4" {
	LT_VER=v3
	[ "$(lt_enum most_comments)" = MostComments ]
	[ "$(lt_enum moderator_view)" = ModeratorView ]
	[ "$(lt_enum local)" = Local ]
	LT_VER=v4
	[ "$(lt_enum most_comments)" = most_comments ]
	[ "$(lt_enum ModeratorView)" = moderator_view ]
}

@test "top + time becomes TopDay on v3" {
	LT_VER=v3
	[ "$(lt_sort_json top day)" = '{"sort":"TopDay"}' ]
	[ "$(lt_sort_json top six_hour)" = '{"sort":"TopSixHour"}' ]
	[ "$(lt_sort_json top)" = '{"sort":"TopAll"}' ]
	[ "$(lt_sort_json hot)" = '{"sort":"Hot"}' ]
	[ "$(lt_sort_json most_comments)" = '{"sort":"MostComments"}' ]
	[ "$(lt_sort_json top_week)" = '{"sort":"TopWeek"}' ]
	[ "$(lt_sort_json "" "")" = '{}' ]
}

@test "top + time becomes sort=top&time_range_seconds on v4" {
	LT_VER=v4
	[ "$(lt_sort_json top day)" = '{"sort":"top","time_range_seconds":86400}' ]
	[ "$(lt_sort_json top year)" = '{"sort":"top","time_range_seconds":31536000}' ]
	[ "$(lt_sort_json top all)" = '{"sort":"top"}' ]
	[ "$(lt_sort_json top)" = '{"sort":"top"}' ]
	[ "$(lt_sort_json Hot)" = '{"sort":"hot"}' ]
	[ "$(lt_sort_json TopMonth)" = '{"sort":"top","time_range_seconds":2592000}' ]
}

@test "unknown time range is an error" {
	LT_VER=v4
	run lt_sort_json top fortnight
	[ "$status" -ne 0 ]
	[[ $output == *"unknown --time"* ]]
}

@test "votes map to score on v3 and is_upvote on v4" {
	LT_VER=v3
	[ "$(lt_vote_json up)" = '{"score":1}' ]
	[ "$(lt_vote_json down)" = '{"score":-1}' ]
	[ "$(lt_vote_json clear)" = '{"score":0}' ]
	LT_VER=v4
	[ "$(lt_vote_json up)" = '{"is_upvote":true}' ]
	[ "$(lt_vote_json down)" = '{"is_upvote":false}' ]
	[ "$(lt_vote_json clear)" = '{"is_upvote":null}' ]
	run lt_vote_json sideways
	[ "$status" -ne 0 ]
}

@test "pagination: --page on v3, --cursor on v4" {
	LT_VER=v3
	[ "$(lt_page_json 3 "")" = '{"page":3}' ]
	[ "$(lt_page_json "" "")" = '{}' ]
	run lt_page_json "" abc
	[ "$status" -ne 0 ]
	LT_VER=v4
	[ "$(lt_page_json "" abc)" = '{"page_cursor":"abc"}' ]
	run lt_page_json 2 ""
	[ "$status" -ne 0 ]
}

@test "next page hint" {
	LT_VER=v3
	[ "$(lt_next_page '{"posts":[]}' 2 5)" = "--page 3" ]
	[ -z "$(lt_next_page '{"posts":[]}' 2 0)" ]
	LT_VER=v4
	[ "$(lt_next_page '{"items":[],"next_page":"Xyz"}' 1 1)" = "--cursor Xyz" ]
	[ -z "$(lt_next_page '{"items":[]}' 1 0)" ]
	[ -z "$(lt_next_page '{"next_page":"none,none,none"}' 1 3)" ]
}

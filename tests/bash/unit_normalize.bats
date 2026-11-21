#!/usr/bin/env bats
# Response normalization (bash/lib/luti.jq) on real v3 and v4 responses
# captured from the dev servers (tests/bash/fixtures/).

setup() {
	load test_helper
}

# norm VERSION FIXTURE FILTER
norm() {
	jq -c -L "$REPO_ROOT/bash/lib" --arg v "$1" "include \"luti\"; $3" "$FIXTURES/$1/$2.json"
}

POST_KEYS='["alt_text","ap_id","body","comments","community","creator","deleted","downvotes","embed_video_url","featured","id","locked","media_kind","my_vote","published","removed","saved","score","thumbnail_url","title","upvotes","url","url_content_type"]'

@test "post: same shape and values on v3 and v4" {
	for v in v3 v4; do
		run norm "$v" post_get '.post_view | post($v)'
		[ "$status" -eq 0 ]
		[ "$(jq -c 'keys' <<<"$output")" = "$POST_KEYS" ]
		[ "$(jq -r '.title' <<<"$output")" = "manual test $v edited" ]
		[ "$(jq -c '[.community.name, .creator.name, .score, .comments, .saved, .my_vote]' <<<"$output")" = '["lutidev","bob",1,2,true,null]' ]
		[[ $(jq -r '.published' <<<"$output") == 2026-* ]]
	done
}

@test "post list: every item normalizes" {
	for v in v3 v4; do
		run norm "$v" post_list '(.posts // .items) | map(post($v)) | map(.id | type) | unique'
		[ "$output" = '["number"]' ]
	done
}

@test "comment: thread position from path, my_vote from score or is_upvote" {
	for v in v3 v4; do
		run norm "$v" comment_list '(.comments // .items) | map(comment($v)) | sort_by(.id)
			| map([.id, .parent_id, .depth, .content, .my_vote, .creator.name])'
		[ "$output" = '[[7,null,0,"alice comment edited","up","alice"],[8,7,1,"bob reply to alice",null,"bob"]]' ]
	done
}

@test "community: counts and subscription state" {
	run norm v3 community_get '.community_view | community($v) | [.name, .posts, .subscribed, .blocked]'
	[ "$output" = '["lutidev",5,"subscribed",false]' ]
	run norm v4 community_get '.community_view | community($v) | [.name, .posts, .subscribed, .blocked]'
	[ "$output" = '["lutidev",5,"not_subscribed",false]' ]
}

@test "community list normalizes" {
	for v in v3 v4; do
		run norm "$v" community_list '(.communities // .items) | map(community($v)) | .[0] | [.name, .title]'
		[ "$output" = '["lutidev","luti dev"]' ]
	done
}

@test "person: post/comment counts from counts (v3) or person (v4)" {
	for v in v3 v4; do
		run norm "$v" person_get '.person_view | person($v) | [.name, .posts, .comments, .is_admin, .banned]'
		[ "$output" = '["alice",4,2,false,false]' ]
	done
}

@test "reports: post, comment and pm reports share one shape" {
	for v in v3 v4; do
		run norm "$v" reports 'to_entries | map(.key as $t | .value | (.post_reports // .comment_reports // .private_message_reports // .items)[] | report($v; $t))
			| map([.type, .reason, .text, .reporter.name, .target_creator.name])'
		[ "$status" -eq 0 ]
		[ "$output" = '[["post","manual test report","manual test '"$v"' edited","bob","bob"],["comment","manual comment report","alice comment edited","bob","alice"],["private_message","fixture pm report","spammy pm","alice","bob"]]' ]
	done
}

@test "registration applications: status from admin_id and accepted_application" {
	for v in v3 v4; do
		run norm "$v" registrations '(.registration_applications // .items) | map(registration($v) | .status)'
		[ "$output" = '["denied","approved"]' ]
	done
}

@test "modlog: v3 object of arrays and v4 items become one list, newest first" {
	run norm v3 modlog 'modlog($v) | map(.kind) | .[0:3]'
	[ "$output" = '["admin_purge_post","mod_ban","mod_ban"]' ]
	run norm v3 modlog 'modlog($v) | map(select(.kind == "mod_ban")) | map(.revert)'
	[ "$output" = '[true,false]' ]
	run norm v4 modlog 'modlog($v) | map([.kind, .revert, .moderator.name, .target.name])'
	[ "$output" = '[["admin_purge_post",false,"luti_admin",null],["admin_ban",true,"luti_admin","bob"]]' ]
	run norm v3 modlog 'modlog($v) | map(.published) | . == (sort | reverse)'
	[ "$output" = true ]
}

@test "private messages: v3 list and v4 notifications share one shape" {
	for v in v3 v4; do
		run norm "$v" pm_list '(.private_messages // .items) | map(pm($v) | [.content, .creator.name, .recipient.name])'
		[ "$output" = '[["hi bob from '"$v"'","alice","bob"],["spammy pm","bob","alice"]]' ]
	done
}

@test "inbox: v3 replies/mentions/messages and v4 notifications" {
	run norm v3 inbox 'inbox_v3 | map(.kind) | unique'
	[ "$output" = '["mention","private_message","reply"]' ]
	run norm v3 inbox 'inbox_v3 | map(.published) | . == (sort | reverse)'
	[ "$output" = true ]
	run norm v4 inbox '[.items[] | notif_v4] | map([.kind, .text, .creator.name])'
	[ "$output" = '[["reply","bob reply to alice","bob"],["private_message","spammy pm","bob"]]' ]
}

@test "search: users/persons and the other lists" {
	for v in v3 v4; do
		run norm "$v" search 'search($v) | map_values(map(.name // .title))'
		[ "$output" = '{"posts":["Welcome to lutidev"],"comments":[],"communities":["lutidev"],"users":[]}' ]
	done
}

@test "counts: v3 report_count and v4 unread_counts" {
	run norm v3 report_count 'counts($v) | [.reports, .post_reports, .comment_reports]'
	[ "$output" = '[4,1,2]' ]
	run norm v4 report_count 'counts($v) | [.reports, .registrations, .notifications]'
	[ "$output" = '[3,1,0]' ]
}

@test "spec_list handles string and array list keys" {
	run jq -c -L "$REPO_ROOT/bash/lib" 'include "luti"; spec_list("items")' <<<'{"items":[1,2]}'
	[ "$output" = '[1,2]' ]
	run jq -c -L "$REPO_ROOT/bash/lib" 'include "luti"; spec_list(["posts","comments"])' <<<'{"posts":[1],"comments":[2]}'
	[ "$output" = '[1,2]' ]
	run jq -c -L "$REPO_ROOT/bash/lib" 'include "luti"; spec_list("posts")' <<<'{}'
	[ "$output" = '[]' ]
}

@test "media_kind: content type first, then the URL extension" {
	mk() { jq -rn -L "$REPO_ROOT/bash/lib" --arg u "$1" --arg c "$2" 'include "luti"; media_kind(if $u == "" then null else $u end; if $c == "" then null else $c end)'; }
	[ "$(mk https://x.test/a.png "")" = image ]
	[ "$(mk 'https://x.test/A.JPEG?size=2#f' "")" = image ]
	[ "$(mk https://x.test/clip.webm "")" = video ]
	[ "$(mk https://x.test/page "image/jpeg")" = image ]
	[ "$(mk https://x.test/a.png "video/mp4")" = video ]
	[ "$(mk https://x.test/article.html "")" = link ]
	[ "$(mk https://x.test/ "text/html")" = link ]
	[ "$(mk "" "")" = none ]
}

@test "post media fields on v3 and v4" {
	for v in v3 v4; do
		run jq -c -L "$REPO_ROOT/bash/lib" --arg v "$v" 'include "luti";
			.post_view.post += {url: "https://e.test/v.mp4", thumbnail_url: "https://e.test/t.jpg", alt_text: "a clip", url_content_type: null}
			| .post_view | post($v) | [.url, .media_kind, .thumbnail_url, .alt_text, (.ap_id | test("/post/"))]' "$FIXTURES/$v/post_get.json"
		[ "$output" = '["https://e.test/v.mp4","video","https://e.test/t.jpg","a clip",true]' ]
		run norm "$v" post_get '.post_view | post($v) | [.url, .media_kind]'
		[ "$output" = '[null,"none"]' ]
	done
}

# display.jq is CLI-only (bash/cli); the library never formats text.
disp() { jq -r -L "$REPO_ROOT/bash/cli" -L "$REPO_ROOT/bash/lib" --argjson w 100 "include \"display\"; $1"; }

@test "table output pads columns and shows - for nulls" {
	run disp '[["1", null, "x"], ["22", "b", "yy"]] | table(["ID", "A", "B"])' <<<'null'
	[ "${lines[0]}" = "ID  A  B" ]
	[ "${lines[1]}" = "1   -  x" ]
	[ "${lines[2]}" = "22  b  yy" ]
}

@test "display reads only normalized data, with media tags" {
	run disp 'posts_table($w)' < <(norm v4 post_list '.items | map(post($v)) | .[0] += {url: "https://e.test/p.gif", media_kind: "image"}')
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == ID*SCORE*CMTS*COMMUNITY*AUTHOR*TITLE ]]
	[[ $output == *"[image] "* ]]
	run disp 'post_full' < <(norm v3 post_get '.post_view | post($v) + {url: "https://e.test/v.mp4", media_kind: "video"}')
	[[ $output == *"link: [video] https://e.test/v.mp4"* ]]
	run disp 'comments_thread' < <(norm v3 comment_list '.comments | map(comment($v))')
	[[ ${lines[0]} == "[7] alice"* ]]
	[[ ${lines[2]} == "  [8] bob"* ]]
}

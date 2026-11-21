#!/usr/bin/env bats
# Integration tests: every luti subcommand against a live dev server.
#
# This file runs against Lemmy 0.19 (API v3, :8536). integration_v4.bats is a
# symlink to it and runs against Lemmy 1.0 (API v4, :8537); the version is
# taken from the file name.
#
# Start the servers first:  docker compose -f dev/docker-compose.yml up -d && dev/seed.sh
# Tests create their own posts, comments and users (tagged with a run id) and
# never rely on exact counts, since other test suites share the servers.

setup_file() {
	load test_helper
	case $BATS_TEST_FILENAME in
		*v4*) export IT_VER=v4 IT_BASE=http://localhost:8537 ;;
		*) export IT_VER=v3 IT_BASE=http://localhost:8536 ;;
	esac
	if ! curl -sf --max-time 5 "$IT_BASE/api/$IT_VER/site" >/dev/null; then
		export IT_SKIP="dev server $IT_BASE not reachable (docker compose -f dev/docker-compose.yml up -d && dev/seed.sh)"
		return 0
	fi
	export XDG_CONFIG_HOME="$BATS_FILE_TMPDIR/config"
	mkdir -p "$XDG_CONFIG_HOME"
	export IT_RUN="lbt$(date +%s)$RANDOM"
	local u
	it_login admin luti_admin luti-dev-admin-pw
	for u in alice bob; do
		it_login "$u" "$u" luti-dev-user-pw
	done
	# Throwaway users with pending applications (registration is not a luti command).
	export IT_USER1="${IT_RUN}a" IT_USER2="${IT_RUN}d"
	for u in "$IT_USER1" "$IT_USER2"; do
		it_register "$u"
	done
	# A post by alice (a moderator of lutidev) that most tests work on.
	export IT_POST
	IT_POST=$("$LUTI" --profile alice --norm post create --community lutidev \
		--title "$IT_RUN post" --body "created by tests/bash" | jq -r .id)
}

# it_login PROFILE USER PASSWORD (retried: the shared servers may be busy or restarting)
it_login() {
	local i
	for i in 1 2 3; do
		printf '%s\n' "$3" | "$LUTI" --profile "$1" login --instance "$IT_BASE" --username "$2" >/dev/null && return 0
		sleep 2
	done
	return 1
}

it_register() {
	local path
	[[ $IT_VER == v3 ]] && path=user/register || path=account/auth/register
	curl -sf -H 'Content-Type: application/json' "$IT_BASE/api/$IT_VER/$path" \
		-d "$(jq -n --arg u "$1" '{username: $u, password: "luti-dev-user-pw",
			password_verify: "luti-dev-user-pw", answer: "luti bash integration test"}')" >/dev/null
}

setup() {
	load test_helper
	[[ -z ${IT_SKIP:-} ]] || {
		[[ ${LUTI_REQUIRE_SERVERS:-0} == 1 ]] && {
			echo "$IT_SKIP" >&2
			return 1
		}
		skip "$IT_SKIP"
	}
}

# lt PROFILE ARGS...: run luti as PROFILE
lt() {
	"$LUTI" --profile "$1" "${@:2}"
}

@test "login: saves config and a 0600 token, never the password" {
	run bash -c "printf 'luti-dev-user-pw\n' | '$LUTI' --profile login-test login --instance '$IT_BASE' --username bob"
	[ "$status" -eq 0 ]
	[[ $output == *"API $IT_VER"* ]]
	local d="$XDG_CONFIG_HOME/luti/login-test"
	[ "$(stat -c %a "$d")" = 700 ]
	[ "$(stat -c %a "$d/token")" = 600 ]
	grep -qx "instance=\"$IT_BASE\"" "$d/config"
	refute grep -rq luti-dev-user-pw "$d"
}

@test "login: wrong password fails with a message" {
	run bash -c "printf 'wrong\n' | '$LUTI' --profile bad login --instance '$IT_BASE' --username bob"
	[ "$status" -ne 0 ]
	[[ $output == *"auth.login failed"* ]]
	[ ! -e "$XDG_CONFIG_HOME/luti/bad/token" ]
}

@test "whoami" {
	run lt admin whoami
	[ "$status" -eq 0 ]
	[[ $output == *"luti_admin"*"[admin]"* ]]
	[[ $output == *"api: $IT_VER"* ]]
	run lt alice --norm whoami
	[ "$(jq -c '[.name, .admin, (.moderates | index("lutidev") != null)]' <<<"$output")" = '["alice",false,true]' ]
}

@test "feed: default, sort/time/type/community options" {
	run lt alice feed
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == ID*TITLE ]]
	run lt alice --norm feed --community lutidev --sort new --limit 50
	[ "$status" -eq 0 ]
	jq -e --arg t "$IT_RUN post" '.items | map(.title) | index($t) != null' <<<"$output"
	local s
	for s in "--sort top --time day" "--sort top --time six_hour" "--sort top" "--sort most_comments" \
		"--sort hot --type local" "--type subscribed" "--type moderator_view" "--saved"; do
		# shellcheck disable=SC2086
		run lt alice --norm feed $s --limit 3
		[ "$status" -eq 0 ] || {
			echo "feed $s: $output"
			return 1
		}
		jq -e '.items | type == "array"' <<<"$output"
	done
}

@test "feed: pagination hint fetches the next page" {
	run lt alice feed --community lutidev --sort new --limit 1
	[ "$status" -eq 0 ]
	local hint
	hint=$(printf '%s\n' "${lines[@]}" | sed -n 's/^next: //p')
	if [[ $IT_VER == v3 ]]; then [[ $hint == "--page 2" ]]; else [[ $hint == --cursor* ]]; fi
	local first second
	first=$(lt alice --norm feed --community lutidev --sort new --limit 1 | jq '.items[0].id')
	# shellcheck disable=SC2086
	second=$(lt alice --norm feed --community lutidev --sort new --limit 1 $hint | jq '.items[0].id')
	[ -n "$second" ] && [ "$first" != "$second" ]
	# The other version's flag is refused.
	if [[ $IT_VER == v3 ]]; then run lt alice feed --cursor abc; else run lt alice feed --page 2; fi
	[ "$status" -ne 0 ]
}

@test "post: create, view, edit" {
	run lt bob --norm post create --community lutidev --title "$IT_RUN bob post" --body "body one" --url "https://example.com/$IT_RUN"
	[ "$status" -eq 0 ]
	local id
	id=$(jq .id <<<"$output")
	[ "$(jq -r '.creator.name' <<<"$output")" = bob ]
	run lt bob post edit "$id" --title "$IT_RUN bob post edited" --body "body two"
	[ "$status" -eq 0 ]
	run lt alice post view "$id"
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "#$id  $IT_RUN bob post edited" ]]
	[[ $output == *"body two"* ]]
	[[ $output == *"link: https://example.com/$IT_RUN"* ]]
}

@test "post: vote up, down, clear" {
	run lt bob --norm post vote "$IT_POST" up
	[ "$status" -eq 0 ]
	[ "$(lt bob --norm post view "$IT_POST" | jq -r .post.my_vote)" = up ]
	lt bob post vote "$IT_POST" down
	[ "$(lt bob --norm post view "$IT_POST" | jq -r .post.my_vote)" = down ]
	run lt bob post vote "$IT_POST" clear
	[[ $output == *"your vote: none"* ]]
	[ "$(lt bob --norm post view "$IT_POST" | jq -r .post.my_vote)" = null ]
	run lt bob post vote "$IT_POST" sideways
	[ "$status" -ne 0 ]
}

@test "post: save and unsave" {
	lt bob post save "$IT_POST"
	[ "$(lt bob --norm post view "$IT_POST" | jq .post.saved)" = true ]
	lt bob post save "$IT_POST" --undo
	[ "$(lt bob --norm post view "$IT_POST" | jq .post.saved)" = false ]
}

@test "post: delete and undelete" {
	local id
	id=$(lt bob --norm post create --community lutidev --title "$IT_RUN to delete" | jq .id)
	run lt bob post delete "$id"
	[ "$status" -eq 0 ]
	[ "$(lt bob --norm post view "$id" | jq .post.deleted)" = true ]
	lt bob post delete "$id" --undo
	[ "$(lt bob --norm post view "$id" | jq .post.deleted)" = false ]
}

@test "comment: reply, threaded reply, edit, vote, delete" {
	run lt bob --norm comment reply --post "$IT_POST" --text "$IT_RUN top comment"
	[ "$status" -eq 0 ]
	local c1 c2
	c1=$(jq .id <<<"$output")
	run lt alice --norm comment reply "$c1" --text "$IT_RUN nested reply"
	[ "$status" -eq 0 ]
	c2=$(jq .id <<<"$output")
	[ "$(jq .parent_id <<<"$output")" = "$c1" ]
	lt bob comment edit "$c1" --text "$IT_RUN top comment edited"
	run lt alice --norm comment vote "$c1" up
	[ "$status" -eq 0 ]
	run lt alice --norm post view "$IT_POST"
	jq -e --argjson c "$c1" '.comments[] | select(.id == $c) | .content == "'"$IT_RUN"' top comment edited" and .my_vote == "up"' <<<"$output"
	jq -e --argjson c "$c2" --argjson p "$c1" '.comments[] | select(.id == $c) | .parent_id == $p and .depth == 1' <<<"$output"
	lt alice comment vote "$c1" clear
	run lt alice post view "$IT_POST"
	[[ $output == *"  [$c2] alice"* ]]
	run lt alice comment delete "$c2"
	[ "$status" -eq 0 ]
	lt alice --norm post view "$IT_POST" | jq -e --argjson c "$c2" '.comments[] | select(.id == $c) | .deleted'
}

@test "inbox: a reply shows up, notify read clears it" {
	lt bob comment reply --post "$IT_POST" --text "$IT_RUN reply for inbox"
	run lt alice --norm inbox --unread --limit 50
	[ "$status" -eq 0 ]
	jq -e --arg t "$IT_RUN reply for inbox" '.items | map(select(.text == $t and .kind == "reply" and .creator.name == "bob")) | length == 1' <<<"$output"
	if [[ $IT_VER == v4 ]]; then
		local nid
		nid=$(jq --arg t "$IT_RUN reply for inbox" '.items | map(select(.text == $t))[0].id' <<<"$output")
		run lt alice notify read "$nid"
		[ "$status" -eq 0 ]
		run lt alice --norm inbox --unread --limit 50
		jq -e --arg t "$IT_RUN reply for inbox" '.items | map(select(.text == $t)) | length == 0' <<<"$output"
	else
		run lt alice notify read 1
		[ "$status" -ne 0 ]
		[[ $output == *"needs an API v4 server"* ]]
	fi
	run lt alice notify read
	[ "$status" -eq 0 ]
	run lt alice --norm inbox --unread --limit 50
	jq -e --arg t "$IT_RUN" '.items | map(select(.kind == "reply" and (.text | startswith($t)))) | length == 0' <<<"$output"
	run lt alice inbox
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == ID*KIND*TEXT ]]
}

@test "pm: send and list" {
	run lt alice pm send bob --text "$IT_RUN private hello"
	[ "$status" -eq 0 ]
	run lt bob --norm pm list --limit 50
	[ "$status" -eq 0 ]
	jq -e --arg t "$IT_RUN private hello" '.items | map(select(.content == $t and .creator.name == "alice")) | length == 1' <<<"$output"
	run lt bob --norm inbox --limit 50
	jq -e --arg t "$IT_RUN private hello" '.items | map(select(.text == $t and .kind == "private_message")) | length == 1' <<<"$output"
	run lt bob pm list
	[[ ${lines[0]} == ID*FROM*TO*MESSAGE ]]
}

@test "community: list and show" {
	run lt bob --norm community list --limit 50
	[ "$status" -eq 0 ]
	jq -e '.items | map(.name) | index("lutidev") != null' <<<"$output"
	run lt bob community show lutidev
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "!lutidev"* ]]
	[[ $output == *"moderators:"*"alice"* ]]
	run lt bob --norm community show 2
	[ "$(jq -r .community.name <<<"$output")" = lutidev ]
}

@test "search finds a post by its unique title" {
	run lt bob --norm search "$IT_RUN post"
	[ "$status" -eq 0 ]
	jq -e --arg t "$IT_RUN post" '.posts | map(.title) | index($t) != null' <<<"$output"
	run lt bob --norm search lutidev --type communities
	jq -e '.communities | map(.name) | index("lutidev") != null' <<<"$output"
	run lt bob search alice --type users
	[ "$status" -eq 0 ]
}

@test "user show" {
	run lt bob user show alice
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "@alice"* ]]
	run lt bob --norm user show alice --limit 50
	jq -e --arg t "$IT_RUN post" '.person.name == "alice" and (.posts | map(.title) | index($t) != null)' <<<"$output"
}

@test "post report, mod reports, mod resolve" {
	run lt bob post report "$IT_POST" --reason "$IT_RUN report reason"
	[ "$status" -eq 0 ]
	run lt alice --norm mod reports --type post --limit 50
	[ "$status" -eq 0 ]
	local rid
	rid=$(jq --arg r "$IT_RUN report reason" '.items | map(select(.reason == $r))[0].id' <<<"$output")
	[[ $rid =~ ^[0-9]+$ ]]
	run lt alice mod reports
	[[ $output == *"$IT_RUN"* ]]
	run lt alice mod resolve post "$rid"
	[ "$status" -eq 0 ]
	run lt alice --norm mod reports --type post --all --limit 50
	jq -e --argjson id "$rid" '.items | map(select(.id == $id))[0].resolved' <<<"$output"
	run lt alice --norm mod reports --type post --limit 50
	jq -e --argjson id "$rid" '.items | map(select(.id == $id)) | length == 0' <<<"$output"
}

@test "comment report and resolve" {
	local cid rid
	cid=$(lt alice --norm comment reply --post "$IT_POST" --text "$IT_RUN reportable" | jq .id)
	run lt bob comment report "$cid" --reason "$IT_RUN comment reason"
	[ "$status" -eq 0 ]
	rid=$(lt alice --norm mod reports --type comment --limit 50 | jq --arg r "$IT_RUN comment reason" '.items | map(select(.reason == $r))[0].id')
	[[ $rid =~ ^[0-9]+$ ]]
	run lt alice mod resolve comment "$rid"
	[ "$status" -eq 0 ]
	lt alice --norm mod reports --type comment --all --limit 50 | jq -e --argjson id "$rid" '.items | map(select(.id == $id))[0].resolved'
}

@test "mod: remove/restore, lock, feature" {
	local id
	id=$(lt bob --norm post create --community lutidev --title "$IT_RUN moderated" | jq .id)
	lt alice mod remove post "$id" --reason "$IT_RUN removal"
	[ "$(lt admin --norm post view "$id" | jq .post.removed)" = true ]
	lt alice mod restore post "$id"
	[ "$(lt admin --norm post view "$id" | jq .post.removed)" = false ]
	lt alice mod lock "$id"
	[ "$(lt alice --norm post view "$id" | jq .post.locked)" = true ]
	lt alice mod lock "$id" --undo
	[ "$(lt alice --norm post view "$id" | jq .post.locked)" = false ]
	lt alice mod feature "$id"
	[ "$(lt alice --norm post view "$id" | jq .post.featured)" = true ]
	lt alice mod feature "$id" --undo
	[ "$(lt alice --norm post view "$id" | jq .post.featured)" = false ]
	lt admin mod feature "$id" --local
	[ "$(lt alice --norm post view "$id" | jq .post.featured)" = true ]
	lt admin mod feature "$id" --local --undo
	local cid
	cid=$(lt bob --norm comment reply --post "$id" --text "$IT_RUN removable comment" | jq .id)
	run lt alice mod remove comment "$cid"
	[ "$status" -eq 0 ]
	lt alice --norm post view "$id" | jq -e --argjson c "$cid" '.comments[] | select(.id == $c) | .removed'
	lt alice mod restore comment "$cid"
	run lt alice modlog --community lutidev --limit 50
	[[ $output == *"$IT_RUN removal"* ]]
}

@test "admin: registrations, approve, deny" {
	run lt admin --norm admin registrations --limit 50
	[ "$status" -eq 0 ]
	jq -e --arg a "$IT_USER1" --arg d "$IT_USER2" '.items | map(.username) | (index($a) != null and index($d) != null)' <<<"$output"
	run lt admin admin registrations
	[[ ${lines[0]} == ID*STATUS*USER* ]]
	run lt admin admin approve "$IT_USER1"
	[ "$status" -eq 0 ]
	[[ $output == *"approved"* ]]
	local appid
	appid=$(lt admin --norm admin registrations --limit 50 | jq --arg d "$IT_USER2" '.items | map(select(.username == $d))[0].id')
	run lt admin admin deny "$appid" --reason "$IT_RUN denied"
	[ "$status" -eq 0 ]
	[[ $output == *"denied"* ]]
	run lt admin --norm admin registrations --all --limit 50
	jq -e --arg a "$IT_USER1" --arg d "$IT_USER2" '
		.items | (map(select(.username == $a))[0].status == "approved") and (map(select(.username == $d))[0].status == "denied")' <<<"$output"
	# The approved user can log in now.
	run bash -c "printf 'luti-dev-user-pw\n' | '$LUTI' --profile newuser login --instance '$IT_BASE' --username '$IT_USER1'"
	[ "$status" -eq 0 ]
}

@test "community: follow, unfollow, block, unblock" {
	run lt newuser community follow lutidev
	[ "$status" -eq 0 ]
	local s
	s=$(lt newuser --norm community show lutidev | jq -r .community.subscribed)
	[[ $s == subscribed || $s == pending ]]
	lt newuser community follow lutidev --undo
	[ "$(lt newuser --norm community show lutidev | jq -r .community.subscribed)" = not_subscribed ]
	lt newuser community block lutidev
	[ "$(lt newuser --norm community show lutidev | jq .community.blocked)" = true ]
	lt newuser community block lutidev --undo
	[ "$(lt newuser --norm community show lutidev | jq .community.blocked)" = false ]
}

@test "mod ban and unban in a community, shown in the modlog" {
	run lt alice mod ban "$IT_USER1" --community lutidev --reason "$IT_RUN community ban" --days 1
	[ "$status" -eq 0 ]
	run lt newuser post create --community lutidev --title "$IT_RUN while banned"
	[ "$status" -ne 0 ]
	run lt alice mod unban "$IT_USER1" --community lutidev
	[ "$status" -eq 0 ]
	run lt alice --norm modlog --community lutidev --limit 50
	jq -e --arg u "$IT_USER1" --arg r "$IT_RUN community ban" '
		.items | map(select(.target.name == $u and .reason == $r and (.kind | test("ban")))) | length == 1' <<<"$output"
	run lt alice mod ban "$IT_USER1"
	[ "$status" -ne 0 ]
	[[ $output == *"--community is required"* ]]
}

@test "admin ban and unban (site)" {
	run lt admin admin ban "$IT_USER1" --reason "$IT_RUN site ban" --days 2
	[ "$status" -eq 0 ]
	[ "$(lt admin --norm user show "$IT_USER1" | jq .person.banned)" = true ]
	run lt admin admin unban "$IT_USER1"
	[ "$status" -eq 0 ]
	[ "$(lt admin --norm user show "$IT_USER1" | jq .person.banned)" = false ]
	run lt admin --norm modlog --user "$IT_USER1" --limit 50
	jq -e --arg r "$IT_RUN site ban" '.items | map(select(.reason == $r)) | length == 1' <<<"$output"
}

@test "modlog: table and filters" {
	run lt bob modlog --limit 5
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == WHEN*ACTION*MOD* ]]
	run lt bob --norm modlog --type mod_ban_from_community --limit 50
	[ "$status" -eq 0 ]
	jq -e '.items | length > 0 and all(.kind == "mod_ban_from_community")' <<<"$output"
}

@test "admin purge asks for confirmation, --yes purges" {
	local id
	id=$(lt bob --norm post create --community lutidev --title "$IT_RUN purge me" | jq .id)
	run lt admin admin purge post "$id" </dev/null
	[ "$status" -ne 0 ]
	lt admin --norm post view "$id" >/dev/null
	run lt admin --yes admin purge post "$id"
	[ "$status" -eq 0 ]
	run lt admin post view "$id"
	[ "$status" -ne 0 ]
}

@test "watch --once: baseline, then a new report from bob, then nothing new" {
	export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	local id
	id=$(lt alice --norm post create --community lutidev --title "$IT_RUN watched" | jq .id)
	run lt alice watch --once reports --community lutidev
	[ "$status" -eq 1 ]
	[[ $output == *"baseline saved"* ]]
	[ -f "$XDG_STATE_HOME/luti/alice/watch-reports" ]
	run lt alice watch --once reports --community lutidev
	[ "$status" -eq 1 ]
	lt bob post report "$id" --reason "$IT_RUN watch report"
	run lt alice --norm watch --once reports --community lutidev
	[ "$status" -eq 0 ]
	jq -e --arg r "$IT_RUN watch report" '(.new | map(select(.reason == $r)) | length == 1) and .summary.reports.new >= 1' <<<"$output"
	run lt alice watch --once reports --community lutidev
	[ "$status" -eq 1 ]
}

@test "watch --once --exec gets each new item as JSON; the loop redraws until stopped" {
	export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	local id
	id=$(lt alice --norm post create --community lutidev --title "$IT_RUN exec watched" | jq .id)
	lt alice watch --once reports || true
	lt bob post report "$id" --reason "$IT_RUN exec report"
	run lt alice watch --once reports --exec "jq -r .reason >>'$BATS_TEST_TMPDIR/got'"
	[ "$status" -eq 0 ]
	grep -qx "$IT_RUN exec report" "$BATS_TEST_TMPDIR/got"
	run lt admin watch --once all
	[[ $status -le 1 ]]
	[[ $output == *"reports:"* && $output == *"registrations:"* && $output == *"inbox:"* ]]
	run timeout 3 "$LUTI" --profile alice watch reports --refresh 10 --quiet
	[ "$status" -eq 124 ]
	[[ $output == *"reports"* ]]
	run lt alice watch reports --refresh 5
	[ "$status" -ne 0 ]
}

@test "open --print builds post, link, media, origin and comment URLs" {
	local id cid host
	id=$(lt bob --norm post create --community lutidev --title "$IT_RUN open me" --url "https://example.com/$IT_RUN.png" | jq .id)
	cid=$(lt bob --norm comment reply --post "$id" --text "$IT_RUN open comment" | jq .id)
	run lt bob open post "$id" --print
	[ "$output" = "$IT_BASE/post/$id" ]
	run lt bob open post "$id" --link --print
	[ "$output" = "https://example.com/$IT_RUN.png" ]
	run lt bob open post "$id" --media --print
	[ "$output" = "https://example.com/$IT_RUN.png" ]
	run lt bob open post "$id" --origin --print
	[[ $output == http*://*/post/"$id" ]]
	run lt bob open comment "$cid" --print
	[ "$output" = "$IT_BASE/comment/$cid" ]
	run lt bob open post "$IT_POST" --link --print
	[ "$status" -ne 0 ]
	# post view shows the media tag.
	run lt bob post view "$id"
	[[ $output == *"[image]"*"https://example.com/$IT_RUN.png"* ]]
	# A stubbed xdg-open receives the URL.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\nprintf "%%s\\n" "$1" >"%s/opened"\n' "$BATS_TEST_TMPDIR" >"$BATS_TEST_TMPDIR/bin/xdg-open"
	chmod +x "$BATS_TEST_TMPDIR/bin/xdg-open"
	BROWSER='' PATH="$BATS_TEST_TMPDIR/bin:$PATH" run lt bob open post "$id"
	[ "$status" -eq 0 ]
	for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -s $BATS_TEST_TMPDIR/opened ]] && break; sleep 0.2; done
	[ "$(cat "$BATS_TEST_TMPDIR/opened")" = "$IT_BASE/post/$id" ]
}

@test "stars: star alice, alice posts, peek, stargaze marks it seen, then empty" {
	export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
	run lt bob star add alice
	[ "$status" -eq 0 ]
	grep -q '^alice@' "$XDG_CONFIG_HOME/luti/bob/stars"
	run lt bob --norm stargaze --peek
	[ "$(jq '.items | length' <<<"$output")" = 0 ]
	run lt bob watch --once stars
	[ "$status" -eq 1 ]
	local id
	id=$(lt alice --norm post create --community lutidev --title "$IT_RUN starred post" | jq .id)
	run lt bob star list
	[[ $output == *"alice@"*" 1 "* ]]
	run lt bob --norm stargaze --peek
	jq -e --argjson id "$id" '.items | map(.id) | index($id) != null' <<<"$output"
	run lt bob --norm stargaze --peek
	jq -e --argjson id "$id" '.items | map(.id) | index($id) != null' <<<"$output"
	run lt bob watch --once stars
	[ "$status" -eq 0 ]
	run lt bob stargaze next
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "★ alice@"* && ${lines[1]} == "#$id  $IT_RUN starred post" ]]
	run lt bob stargaze next
	[ "$status" -eq 1 ]
	run lt bob --norm stargaze --peek
	[ "$(jq '.items | length' <<<"$output")" = 0 ]
	run lt bob star add nosuchuser_luti
	[[ $output == *"nosuchuser_luti"* ]]
	run lt bob star remove alice
	[ "$status" -eq 0 ]
	refute grep -q '^alice@' "$XDG_CONFIG_HOME/luti/bob/stars"
}

@test "library: used directly under set -euo pipefail, without the CLI" {
	run env -i PATH="$PATH" HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state" \
		LUTI_SPEC="$LUTI_SPEC" IT_BASE="$IT_BASE" IT_VER="$IT_VER" IT_RUN="$IT_RUN" REPO_ROOT="$REPO_ROOT" bash -c '
		set -euo pipefail
		. "$REPO_ROOT/bash/lib/luti.sh"
		luti_connect "$IT_BASE"
		[[ $LUTI_API == "$IT_VER" ]]
		LUTI_TOKEN=$(luti_login bob luti-dev-user-pw)
		[[ $(luti_whoami | jq -r .name) == bob ]]
		id=$(luti_post_create "$(jq -nc --arg t "$IT_RUN lib post" "{community: \"lutidev\", title: \$t, url: \"https://example.com/v.mp4\"}")" | jq .id)
		[[ $(luti_post_get "$id" | jq -r .post.media_kind) == video ]]
		luti_post_list "{\"community\": \"lutidev\", \"sort\": \"new\", \"limit\": 5}" | jq -e --argjson id "$id" ".items | map(.id) | index(\$id) != null" >/dev/null
		[[ $(luti_url post "$id") == "$IT_BASE/post/$id" ]]
		luti_post_vote "$id" up >/dev/null
		luti_watch_poll inbox "$XDG_STATE_HOME/w" | jq -e ".baseline == true" >/dev/null
		luti_config_load alice
		[[ $LUTI_USERNAME == alice && -n $LUTI_TOKEN ]]
		luti_whoami | jq -r .name
	'
	[ "$status" -eq 0 ] || {
		echo "$output"
		return 1
	}
	[ "${lines[-1]}" = alice ]
}

@test "--json prints the raw API response" {
	run lt bob --json feed --limit 2
	[ "$status" -eq 0 ]
	if [[ $IT_VER == v3 ]]; then jq -e '.posts | type == "array"' <<<"$output"; else jq -e '.items | type == "array"' <<<"$output"; fi
	run lt bob --json community show lutidev
	jq -e '.community_view.community.name == "lutidev"' <<<"$output"
}

@test "--api override and cached detection" {
	[ "$(cut -d' ' -f1 "$XDG_CONFIG_HOME/luti/bob/api_cache")" = "$IT_VER" ]
	if [[ $IT_VER == v4 ]]; then
		# A 1.0 server also serves a reduced /api/v3.
		run lt bob --api v3 --norm feed --limit 1
		[ "$status" -eq 0 ]
	fi
	run lt bob --api "$IT_VER" whoami
	[[ $output == *"api: $IT_VER"* ]]
}

@test "logout deletes the token" {
	run lt login-test logout
	[ "$status" -eq 0 ]
	[ ! -e "$XDG_CONFIG_HOME/luti/login-test/token" ]
	run lt login-test whoami
	[ "$status" -ne 0 ]
	[[ $output == *"not logged in"* ]]
}

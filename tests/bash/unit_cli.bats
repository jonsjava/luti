#!/usr/bin/env bats
# Command-line behaviour that needs no server: help, argument errors, luti.sh.

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
}

@test "luti --help lists the commands" {
	run "$LUTI" --help
	[ "$status" -eq 0 ]
	[[ $output == *"Usage: luti"* ]]
	for c in login logout whoami feed post comment inbox notify pm community user search mod modlog admin watch open star stargaze; do
		[[ $output == *"$c"* ]]
	done
}

@test "every command and subcommand has --help" {
	local cmds=(login logout whoami feed search inbox modlog watch
		"post view" "post create" "post edit" "post delete" "post save" "post vote" "post report"
		"comment reply" "comment edit" "comment delete" "comment vote" "comment report"
		"notify read" "pm send" "pm list" "community list" "community show" "community follow" "community block"
		"user show" "mod reports" "mod resolve" "mod remove" "mod restore" "mod lock" "mod feature" "mod ban" "mod unban"
		"admin registrations" "admin approve" "admin deny" "admin ban" "admin unban" "admin purge"
		"open post" "open comment" "star add" "star remove" "star list" "stargaze next" "stargaze clear"
		"watch reports" "watch stars" "watch all"
		post comment notify pm community user mod admin open star stargaze)
	local c
	for c in "${cmds[@]}"; do
		# shellcheck disable=SC2086
		run "$LUTI" $c --help
		if [ "$status" -ne 0 ] || [[ $output != *Usage* ]]; then
			echo "no help for: $c (status $status): $output"
			return 1
		fi
	done
	# No request was made.
	[ ! -e "$STUB_DIR/calls" ]
}

@test "unknown command and option fail" {
	run "$LUTI" frobnicate
	[ "$status" -ne 0 ]
	[[ $output == *"unknown command"* ]]
	lt_write_profile default https://x.test v4 tok
	run "$LUTI" feed --bogus
	[ "$status" -ne 0 ]
	[[ $output == *"unknown option"* ]]
}

@test "commands that need a login say so" {
	lt_write_profile default https://x.test v4
	run "$LUTI" whoami
	[ "$status" -ne 0 ]
	[[ $output == *"not logged in"* ]]
}

@test "no instance configured" {
	run "$LUTI" feed
	[ "$status" -ne 0 ]
	[[ $output == *"no instance configured"* ]]
}

@test "--api must be v3 or v4" {
	run "$LUTI" --api v2 feed
	[ "$status" -ne 0 ]
}

@test "bad profile names are rejected" {
	run "$LUTI" --profile ../x whoami
	[ "$status" -ne 0 ]
	[[ $output == *"invalid profile"* ]]
}

@test "feed sends v3 enum and sort transforms" {
	lt_write_profile default https://x.test v3
	stub_respond 200 '{"posts":[]}'
	run "$LUTI" feed --sort top --time day --type moderator_view --community lutidev --page 2
	[ "$status" -eq 0 ]
	[ "$(cat "$STUB_DIR/calls")" = "GET https://x.test/api/v3/post/list?limit=20&sort=TopDay&page=2&type_=ModeratorView&community_name=lutidev" ]
}

@test "feed sends v4 enum and sort transforms" {
	lt_write_profile default https://x.test v4
	stub_respond 200 '{"items":[],"next_page":"CUR2"}'
	run "$LUTI" feed --sort top --time week --type local --cursor CUR1
	[ "$status" -eq 0 ]
	[ "$(cat "$STUB_DIR/calls")" = "GET https://x.test/api/v4/post/list?limit=20&sort=top&time_range_seconds=604800&page_cursor=CUR1&type_=local" ]
	[[ $output == *"next: --cursor CUR2"* ]]
}

@test "--profile and --api can come after the command" {
	lt_write_profile other https://other.test v3
	stub_respond 200 '{"posts":[]}'
	run "$LUTI" feed --profile other --api v4
	[ "$(cat "$STUB_DIR/calls")" = "GET https://other.test/api/v4/post/list?limit=20" ]
}

@test "--json prints the raw response" {
	lt_write_profile default https://x.test v4
	stub_respond 200 '{"items":[],"next_page":null,"extra":1}'
	run "$LUTI" --json feed
	[ "$(jq -c . <<<"$output")" = '{"items":[],"next_page":null,"extra":1}' ]
}

@test "login reads the password from stdin, stores the token, not the password" {
	stub_respond 200 '{"version":"1.0.0","jwt":"JWT123"}'
	run bash -c "printf 'sekrit\n' | '$LUTI' login --instance https://x.test --username me"
	[ "$status" -eq 0 ]
	[ "$(cat "$XDG_CONFIG_HOME/luti/default/token")" = JWT123 ]
	[ "$(jq -c . "$STUB_DIR/body")" = '{"username_or_email":"me","password":"sekrit"}' ]
	refute grep -rq sekrit "$XDG_CONFIG_HOME"
	refute grep -q sekrit "$STUB_DIR/args"
	grep -qx 'instance="https://x.test"' "$XDG_CONFIG_HOME/luti/default/config"
	grep -qx 'username="me"' "$XDG_CONFIG_HOME/luti/default/config"
	grep -qx 'mfa="false"' "$XDG_CONFIG_HOME/luti/default/config"
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default/token")" = 600 ]
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default")" = 700 ]
}

@test "login with mfa sends the TOTP code" {
	stub_respond 200 '{"version":"1.0.0","jwt":"JWT123"}'
	run bash -c "printf 'pw\n123456\n' | '$LUTI' login --instance https://x.test --username me --mfa"
	[ "$status" -eq 0 ]
	[ "$(jq -r .totp_2fa_token "$STUB_DIR/body")" = 123456 ]
	grep -qx 'mfa="true"' "$XDG_CONFIG_HOME/luti/default/config"
}

@test "purge refuses without --yes when there is no terminal" {
	lt_write_profile default https://x.test v4 tok
	run "$LUTI" admin purge post 5 </dev/null
	[ "$status" -ne 0 ]
	[[ $output == *"refusing without --yes"* ]]
	[ ! -e "$STUB_DIR/calls" ]
	run "$LUTI" --yes admin purge post 5
	[ "$status" -eq 0 ]
	[ "$(cat "$STUB_DIR/calls")" = "POST https://x.test/api/v4/admin/purge/post" ]
}

@test "luti.sh --help and unknown options" {
	run "$REPO_ROOT/luti.sh" --help
	[ "$status" -eq 0 ]
	[[ $output == *"-i=INSTANCE"* ]]
	run "$REPO_ROOT/luti.sh" --nope
	[ "$status" -ne 0 ]
	[ -e "$REPO_ROOT/bash/luti" ]
	[ ! -e "$REPO_ROOT/functions" ]
}

@test "luti.sh maps old flags, warns about -p, logs in and starts watch" {
	stub_respond 200 '{"version":"1.0.0","jwt":"JWT9","items":[]}'
	run timeout 3 "$REPO_ROOT/luti.sh" -i=https://x.test -u=me -p=pw -r=1
	[[ $output == *"deprecated"* ]]
	[[ $output == *"minimum of 10"* ]]
	[[ $output == *"luti watch  https://x.test (me)"*"next in 10s"* ]]
	[[ $output == *"reports: 0 pending"*"(nothing pending)"* ]]
	[ "$(cat "$XDG_CONFIG_HOME/luti/default/token")" = JWT9 ]
	grep -q "GET https://x.test/api/v4/report/list" "$STUB_DIR/calls"
	refute grep -q pw "$XDG_CONFIG_HOME/luti/default/config"
}

@test "luti.sh reads an old-style config file without sourcing it" {
	cat >"$BATS_TEST_TMPDIR/oldconfig" <<CFG
# CHANGE THESE VALUES
my_instance="https://old.test"			# e.g. https://feddit.nl
my_username="olduser"
my_password="old#pw"   # comment
USE_MFA=false
evil=\$(touch $BATS_TEST_TMPDIR/pwned)
CFG
	stub_respond 200 '{"version":"1.0.0","jwt":"JWTOLD","items":[]}'
	run timeout 3 "$REPO_ROOT/luti.sh" -f="$BATS_TEST_TMPDIR/oldconfig" -r=30
	[[ $output == *"reports: 0 pending"* ]]
	grep -qx 'username="olduser"' "$XDG_CONFIG_HOME/luti/default/config"
	grep -qx 'instance="https://old.test"' "$XDG_CONFIG_HOME/luti/default/config"
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
	grep -q '"password":"old#pw"' "$STUB_DIR/bodies"
}

@test "watch: refresh minimum, unknown kind, needs a login" {
	lt_write_profile default https://x.test v4 tok
	run "$LUTI" watch --refresh 9
	[ "$status" -ne 0 ]
	[[ $output == *"10"* ]]
	run "$LUTI" watch bogus --once
	[ "$status" -ne 0 ]
	lt_write_profile nologin https://x.test v4
	run "$LUTI" --profile nologin watch --once
	[ "$status" -ne 0 ]
	[[ $output == *"not logged in"* ]]
}

@test "watch --once exit codes: 1 at baseline, 0 when new, 1 when not, 3 on a rejected token" {
	lt_write_profile default https://x.test v4 tok
	local r2
	stub_route "GET api/v4/report/list" '{"items":[]}'
	run "$LUTI" watch --once reports
	[ "$status" -eq 1 ]
	[[ $output == *"baseline"* ]]
	r2=$(jq -c '{items: [.post.items[0]]}' "$FIXTURES/v4/reports.json")
	stub_route "GET api/v4/report/list" "$r2"
	run "$LUTI" watch --once reports --exec "cat >'$BATS_TEST_TMPDIR/item.json'"
	[ "$status" -eq 0 ]
	[[ $output == *"1 new"* ]]
	[ "$(jq -r '.watch + " " + .type + " " + .reason' "$BATS_TEST_TMPDIR/item.json")" = "reports post manual test report" ]
	run "$LUTI" watch --once reports
	[ "$status" -eq 1 ]
	stub_respond 401 '{"error":"not_logged_in"}'
	rm -rf "$STUB_DIR/routes"
	run "$LUTI" watch --once reports
	[ "$status" -eq 3 ]
}

@test "open refuses bad ids and prints URLs without a request" {
	lt_write_profile default https://x.test v4
	run "$LUTI" open post 12 --print
	[ "$status" -eq 0 ]
	[ "$output" = https://x.test/post/12 ]
	run "$LUTI" open comment 3 --print
	[ "$output" = https://x.test/comment/3 ]
	[ ! -e "$STUB_DIR/calls" ]
	run "$LUTI" open post abc --print
	[ "$status" -ne 0 ]
	run "$LUTI" open comment 3 --link --print
	[ "$status" -ne 0 ]
}

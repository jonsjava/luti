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
	for c in login logout whoami feed post comment inbox notify pm community user search mod modlog admin watch; do
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
		post comment notify pm community user mod admin)
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
	stub_respond 200 '{"version":"1.0.0","jwt":"JWT9","report_count":2,"registration_application_count":0,"notification_count":1}'
	run timeout 3 "$REPO_ROOT/luti.sh" -i=https://x.test -u=me -p=pw -r=1
	[[ $output == *"deprecated"* ]]
	[[ $output == *"Open reports:  2"* ]]
	[ "$(cat "$XDG_CONFIG_HOME/luti/default/token")" = JWT9 ]
	grep -q "GET https://x.test/api/v4/account/unread_counts" "$STUB_DIR/calls"
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
	stub_respond 200 '{"version":"1.0.0","jwt":"JWTOLD","report_count":1}'
	run timeout 3 "$REPO_ROOT/luti.sh" -f="$BATS_TEST_TMPDIR/oldconfig" -r=1
	[[ $output == *"Open reports:  1"* ]]
	grep -qx 'username="olduser"' "$XDG_CONFIG_HOME/luti/default/config"
	grep -qx 'instance="https://old.test"' "$XDG_CONFIG_HOME/luti/default/config"
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
	grep -q '"password":"old#pw"' "$STUB_DIR/bodies"
}

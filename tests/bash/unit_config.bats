#!/usr/bin/env bats
# Opt-in profile config and token storage (bash/lib/config.sh).

setup() {
	load test_helper
	lt_test_config
	lt_load_lib
}

cfg() { mkdir -p "$XDG_CONFIG_HOME/luti/${2:-default}" && cat >"$XDG_CONFIG_HOME/luti/${2:-default}/config"; }

@test "parses plain and quoted values, comments, blanks and spaces" {
	cfg <<'CFG'
# a comment
instance="https://lemmy.example/"

  username = alice
mfa=true
api="v4"
unknown=ignored
CFG
	luti_config_load
	[ "$LUTI_INSTANCE" = "https://lemmy.example" ]
	[ "$LUTI_USERNAME" = alice ]
	[ "$LUTI_MFA" = true ]
	[ "$LUTI_CONFIG_API" = v4 ]
	[ "$LUTI_API" = v4 ]
	[ "$LUTI_PROFILE" = default ]
}

@test "never executes the config file" {
	printf 'instance=$(touch %s/pwned)\nusername=`touch %s/pwned2`\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" | cfg
	luti_config_load
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
	[ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
	[ "$LUTI_USERNAME" = '`touch '"$BATS_TEST_TMPDIR"'/pwned2`' ]
}

@test "handles CRLF line endings and a missing final newline" {
	printf 'instance="https://a.example"\r\nusername=bob' | cfg
	luti_config_load
	[ "$LUTI_INSTANCE" = "https://a.example" ]
	[ "$LUTI_USERNAME" = bob ]
}

@test "missing config gives empty values and clears earlier ones" {
	LUTI_INSTANCE=https://old.example LUTI_TOKEN=old
	luti_config_load
	[ -z "$LUTI_INSTANCE" ] && [ -z "$LUTI_TOKEN" ] && [ -z "$LUTI_API" ]
	[ "$LUTI_MFA" = false ]
}

@test "save writes key=\"value\" lines that parse back (api omitted when empty)" {
	LUTI_INSTANCE=https://x.example LUTI_USERNAME=carol LUTI_MFA=no LUTI_CONFIG_API=""
	(set -o pipefail; luti_config_save)
	run cat "$XDG_CONFIG_HOME/luti/default/config"
	[ "${#lines[@]}" -eq 3 ]
	[ "${lines[0]}" = 'instance="https://x.example"' ]
	[ "${lines[1]}" = 'username="carol"' ]
	[ "${lines[2]}" = 'mfa="false"' ]
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default/config")" = 600 ]
	LUTI_USERNAME=""
	luti_config_load
	[ "$LUTI_USERNAME" = carol ]
}

@test "save keeps keys it does not own (TUI settings) and comments" {
	cfg <<'CFG'
# written by luti-tui
instance=https://old.example
username=alice
images=off
thumbnails=false
stargaze_refresh=300
CFG
	LUTI_INSTANCE=https://new.example LUTI_USERNAME=bob LUTI_MFA=false LUTI_CONFIG_API=""
	(set -o pipefail; luti_config_save)
	run cat "$XDG_CONFIG_HOME/luti/default/config"
	[ "${lines[0]}" = 'instance="https://new.example"' ]
	[ "${lines[1]}" = 'username="bob"' ]
	[[ $output == *"# written by luti-tui"* ]]
	[[ $output == *"images=off"* ]]
	[[ $output == *"thumbnails=false"* ]]
	[[ $output == *"stargaze_refresh=300"* ]]
	[[ $output != *"old.example"* && $output != *"alice"* ]]
}

@test "save refuses quotes and newlines" {
	LUTI_INSTANCE='https://x"y'
	run luti_config_save
	[ "$status" -ne 0 ]
	[[ $output == *"quotes or newlines"* ]]
}

@test "profile directory is 0700, token is 0600, delete removes it" {
	LUTI_TOKEN=abc.def.ghi
	luti_token_save
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default")" = 700 ]
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default/token")" = 600 ]
	LUTI_TOKEN=""
	luti_config_load
	[ "$LUTI_TOKEN" = abc.def.ghi ]
	luti_token_delete
	[ ! -e "$XDG_CONFIG_HOME/luti/default/token" ]
}

@test "profiles are separate directories" {
	luti_config_load work
	luti_token_save tok-work
	[ -f "$XDG_CONFIG_HOME/luti/work/token" ]
	luti_config_load default
	[ -z "$LUTI_TOKEN" ]
	[ "$(luti_config_dir work)" = "$XDG_CONFIG_HOME/luti/work" ]
	[ "$(luti_state_dir work)" = "$XDG_STATE_HOME/luti/work" ]
}

@test "profile names are validated" {
	luti_valid_profile default
	luti_valid_profile my.alt-1
	local bad
	for bad in "../etc" "a/b" ".." "." ""; do
		run luti_valid_profile "$bad"
		[ "$status" -ne 0 ]
	done
	run luti_config_load ../x
	[ "$status" -ne 0 ]
	[[ $output == *"invalid profile"* ]]
}

@test "the api cache is used only for the same instance; config api wins" {
	printf 'instance="https://a.example"\n' | cfg
	luti_config_load
	LUTI_API=v4
	luti_config_cache_api
	[ "$(cat "$XDG_CONFIG_HOME/luti/default/api_cache")" = "v4 https://a.example" ]
	LUTI_API=""
	luti_config_load
	[ "$LUTI_API" = v4 ]
	printf 'instance="https://b.example"\n' | cfg
	luti_config_load
	[ -z "$LUTI_API" ]
	printf 'instance="https://a.example"\napi=v3\n' | cfg
	luti_config_load
	[ "$LUTI_API" = v3 ]
}

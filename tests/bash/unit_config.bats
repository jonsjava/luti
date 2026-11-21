#!/usr/bin/env bats
# Config parsing and token storage (bash/lib/config.sh).

setup() {
	load test_helper
	lt_test_config
	lt_load_lib
	LT_PROFILE=default
}

@test "parses plain and quoted values, comments, blanks and spaces" {
	mkdir -p "$XDG_CONFIG_HOME/luti/default"
	cat >"$XDG_CONFIG_HOME/luti/default/config" <<'CFG'
# a comment
instance="https://lemmy.example"

  username = alice
mfa=true
api="v4"
unknown=ignored
CFG
	lt_config_load
	[ "$(lt_cfg instance)" = "https://lemmy.example" ]
	[ "$(lt_cfg username)" = "alice" ]
	[ "$(lt_cfg mfa)" = "true" ]
	[ "$(lt_cfg api)" = "v4" ]
	[ -z "${LT_CFG[unknown]:-}" ]
}

@test "never executes the config file" {
	mkdir -p "$XDG_CONFIG_HOME/luti/default"
	printf 'instance=$(touch %s/pwned)\nusername=`touch %s/pwned2`\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" \
		>"$XDG_CONFIG_HOME/luti/default/config"
	lt_config_load
	[ ! -e "$BATS_TEST_TMPDIR/pwned" ]
	[ ! -e "$BATS_TEST_TMPDIR/pwned2" ]
	[ "$(lt_cfg instance)" = '$(touch '"$BATS_TEST_TMPDIR"'/pwned)' ]
}

@test "handles CRLF line endings and a missing final newline" {
	mkdir -p "$XDG_CONFIG_HOME/luti/default"
	printf 'instance="https://a.example"\r\nusername=bob' >"$XDG_CONFIG_HOME/luti/default/config"
	lt_config_load
	[ "$(lt_cfg instance)" = "https://a.example" ]
	[ "$(lt_cfg username)" = "bob" ]
}

@test "missing config gives empty values" {
	lt_config_load
	[ -z "$(lt_cfg instance)" ]
}

@test "save writes key=\"value\" lines that parse back" {
	LT_CFG=([instance]="https://x.example" [username]="carol" [mfa]="false")
	lt_config_save
	run cat "$XDG_CONFIG_HOME/luti/default/config"
	[ "${lines[0]}" = 'instance="https://x.example"' ]
	[ "${lines[1]}" = 'username="carol"' ]
	[ "${lines[2]}" = 'mfa="false"' ]
	LT_CFG=()
	lt_config_load
	[ "$(lt_cfg username)" = "carol" ]
}

@test "profile directory is 0700 and token is 0600" {
	lt_token_save "abc.def.ghi"
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default")" = 700 ]
	[ "$(stat -c %a "$XDG_CONFIG_HOME/luti/default/token")" = 600 ]
	[ "$(lt_token_read)" = "abc.def.ghi" ]
	lt_token_delete
	run lt_token_read
	[ "$status" -ne 0 ]
}

@test "profiles are separate directories" {
	LT_PROFILE=work
	lt_token_save "tok-work"
	[ -f "$XDG_CONFIG_HOME/luti/work/token" ]
	LT_PROFILE=default
	run lt_token_read
	[ "$status" -ne 0 ]
}

@test "profile names are validated" {
	lt_valid_profile default
	lt_valid_profile my.alt-1
	local bad
	for bad in "../etc" "a/b" ".." ""; do
		run lt_valid_profile "$bad"
		[ "$status" -ne 0 ]
	done
}

@test "api cache is tied to the instance" {
	mkdir -p "$XDG_CONFIG_HOME/luti/default"
	lt_api_cache_write v4 "https://a.example"
	[ "$(lt_api_cache_read https://a.example)" = v4 ]
	run lt_api_cache_read https://b.example
	[ "$status" -ne 0 ]
}

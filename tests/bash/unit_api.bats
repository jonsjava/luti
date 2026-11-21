#!/usr/bin/env bats
# The request layer (bash/lib/api.sh) against a stubbed curl.

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
	lt_load_lib
	LT_PROFILE=default
	LT_INSTANCE=https://lemmy.test
	LT_TOKEN=tok123
}

@test "spec is found relative to the script, LUTI_SPEC overrides" {
	unset LUTI_SPEC
	[ "$(lt_spec_file)" = "$REPO_ROOT/spec/endpoints.json" ]
	LUTI_SPEC=/elsewhere/spec.json
	[ "$(lt_spec_file)" = /elsewhere/spec.json ]
}

@test "GET params become a URL-encoded query string" {
	LT_VER=v4
	stub_respond 200 '{"items":[]}'
	lt_api post.list '{"limit":5,"community_name":"a b&c","saved_only":true,"page_cursor":null}' >/dev/null
	run cat "$STUB_DIR/calls"
	[ "$output" = "GET https://lemmy.test/api/v4/post/list?limit=5&community_name=a%20b%26c&saved_only=true" ]
	[ ! -s "$STUB_DIR/body" ]
}

@test "POST sends the JSON body on stdin and the bearer token as a header" {
	LT_VER=v4
	lt_api post.create '{"community_id":2,"name":"hi"}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "POST https://lemmy.test/api/v4/post" ]
	[ "$(jq -c . "$STUB_DIR/body")" = '{"community_id":2,"name":"hi"}' ]
	grep -qx 'Authorization: Bearer tok123' "$STUB_DIR/headers"
	grep -qx 'Content-Type: application/json' "$STUB_DIR/headers"
	# The token is never on the command line.
	refute grep -q tok123 "$STUB_DIR/args"
	refute grep -q 'auth=' "$STUB_DIR/calls"
}

@test "no Authorization header when logged out" {
	LT_VER=v3
	LT_TOKEN=""
	lt_api site.get >/dev/null
	refute grep -q Authorization "$STUB_DIR/headers"
}

@test "version-specific method and path (post.delete)" {
	LT_VER=v3
	lt_api post.delete '{"post_id":1,"deleted":true}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "POST https://lemmy.test/api/v3/post/delete" ]
	LT_VER=v4
	lt_api post.delete '{"post_id":1,"deleted":true}' >/dev/null
	[ "$(tail -1 "$STUB_DIR/calls")" = "DELETE https://lemmy.test/api/v4/post" ]
}

@test "rename_v3 renames fields on v3 only" {
	LT_VER=v3
	lt_api admin.ban '{"person_id":3,"ban":true,"remove_or_restore_data":true,"expires_at":99,"reason":"x"}' >/dev/null
	[ "$(jq -c 'keys' "$STUB_DIR/body")" = '["ban","expires","person_id","reason","remove_data"]' ]
	LT_VER=v4
	lt_api admin.ban '{"person_id":3,"ban":true,"remove_or_restore_data":true,"expires_at":99,"reason":"x"}' >/dev/null
	[ "$(jq -c 'keys' "$STUB_DIR/body")" = '["ban","expires_at","person_id","reason","remove_or_restore_data"]' ]
}

@test "rename_v3 applies to GET query strings (search_term -> q)" {
	LT_VER=v3
	lt_api search '{"search_term":"cats"}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v3/search?q=cats" ]
}

@test "fixed params are added (pm.list on v4)" {
	LT_VER=v4
	lt_api pm.list '{"limit":2}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v4/account/notification/list?limit=2&type_=private_message" ]
}

@test "report lists on v4 send the plural type_ the server expects" {
	LT_VER=v4
	lt_api report.list.post '{}' >/dev/null
	lt_api report.list.pm '{}' >/dev/null
	run cat "$STUB_DIR/calls"
	[ "${lines[0]}" = "GET https://lemmy.test/api/v4/report/list?type_=posts" ]
	[ "${lines[1]}" = "GET https://lemmy.test/api/v4/report/list?type_=private_messages" ]
}

@test "pick extracts a field (account.get on v3)" {
	LT_VER=v3
	stub_respond 200 '{"version":"0.19","my_user":{"local_user_view":{"person":{"name":"me"}}}}'
	run lt_api account.get
	[ "$status" -eq 0 ]
	[ "$(jq -r '.local_user_view.person.name' <<<"$output")" = me ]
}

@test "Lemmy error bodies become a message and non-zero exit" {
	LT_VER=v4
	stub_respond 400 '{"error":"couldnt_find_post","message":"nope"}'
	run lt_api post.get '{"id":1}'
	[ "$status" -ne 0 ]
	[[ $output == *"post.get failed: couldnt_find_post (nope) [HTTP 400]"* ]]
}

@test "HTTP errors without a JSON body fail too" {
	LT_VER=v4
	stub_respond 502 '<html>bad gateway</html>'
	run lt_api post.get '{"id":1}'
	[ "$status" -ne 0 ]
	[[ $output == *"HTTP 502"* ]]
}

@test "ops missing on a version are refused before any request" {
	LT_VER=v3
	run lt_api notifications.list
	[ "$status" -ne 0 ]
	[[ $output == *"not available on API v3"* ]]
	[ ! -e "$STUB_DIR/calls" ]
}

@test "version detection prefers v4 and is cached per profile" {
	LT_VER=""
	LT_INSTANCE=https://lemmy.test
	lt_write_profile default https://lemmy.test ""
	sed -i '/^api=/d' "$XDG_CONFIG_HOME/luti/default/config"
	lt_config_load
	stub_respond 200 '{"version":"1.0.0"}'
	lt_require_version
	[ "$LT_VER" = v4 ]
	[ "$(head -1 "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v4/site" ]
	[ "$(cat "$XDG_CONFIG_HOME/luti/default/api_cache")" = "v4 https://lemmy.test" ]
	# Second time: no request.
	rm "$STUB_DIR/calls"
	LT_VER=""
	lt_require_version
	[ "$LT_VER" = v4 ]
	[ ! -e "$STUB_DIR/calls" ]
}

@test "version detection falls back to v3 when /api/v4 is missing" {
	cat >"$BATS_TEST_TMPDIR/stub/code" <<<"404"
	# A stub that answers 404 for v4 and 200 for v3.
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat >"$BATS_TEST_TMPDIR/bin/curl" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do url=$a; done
if [[ $url == */api/v4/site ]]; then printf '404 page\n404'; else printf '{"version":"0.19.21"}\n200'; fi
SH
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	run lt_detect_version https://lemmy.test
	[ "$output" = v3 ]
}

@test "instance URLs are normalized" {
	[ "$(lt_normalize_instance lemmy.world)" = https://lemmy.world ]
	[ "$(lt_normalize_instance http://localhost:8536//)" = http://localhost:8536 ]
}

#!/usr/bin/env bats
# The request layer (bash/lib/api.sh) against a stubbed curl.

setup() {
	load test_helper
	lt_test_config
	lt_stub_curl
	lt_load_lib
	LUTI_INSTANCE=https://lemmy.test
	LUTI_TOKEN=tok123
}

@test "spec is found relative to the script, LUTI_SPEC overrides" {
	unset LUTI_SPEC
	[ "$(realpath "$(_luti_spec_file)")" = "$REPO_ROOT/spec/endpoints.json" ]
	LUTI_SPEC=/elsewhere/spec.json
	[ "$(_luti_spec_file)" = /elsewhere/spec.json ]
}

@test "GET params become a URL-encoded query string" {
	LUTI_API=v4
	stub_respond 200 '{"items":[]}'
	luti_api post.list '{"limit":5,"community_name":"a b&c","saved_only":true,"page_cursor":null}' >/dev/null
	run cat "$STUB_DIR/calls"
	[ "$output" = "GET https://lemmy.test/api/v4/post/list?limit=5&community_name=a%20b%26c&saved_only=true" ]
	[ ! -s "$STUB_DIR/body" ]
}

@test "POST sends the JSON body on stdin and the bearer token as a header" {
	LUTI_API=v4
	luti_api post.create '{"community_id":2,"name":"hi"}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "POST https://lemmy.test/api/v4/post" ]
	[ "$(jq -c . "$STUB_DIR/body")" = '{"community_id":2,"name":"hi"}' ]
	grep -qx 'Authorization: Bearer tok123' "$STUB_DIR/headers"
	grep -qx 'Content-Type: application/json' "$STUB_DIR/headers"
	# The token is never on the command line.
	refute grep -q tok123 "$STUB_DIR/args"
	refute grep -q 'auth=' "$STUB_DIR/calls"
}

@test "no Authorization header when logged out" {
	LUTI_API=v3
	LUTI_TOKEN=""
	luti_api site.get >/dev/null
	refute grep -q Authorization "$STUB_DIR/headers"
}

@test "version-specific method and path (post.delete)" {
	LUTI_API=v3
	luti_api post.delete '{"post_id":1,"deleted":true}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "POST https://lemmy.test/api/v3/post/delete" ]
	LUTI_API=v4
	luti_api post.delete '{"post_id":1,"deleted":true}' >/dev/null
	[ "$(tail -1 "$STUB_DIR/calls")" = "DELETE https://lemmy.test/api/v4/post" ]
}

@test "rename_v3 renames fields on v3 only" {
	LUTI_API=v3
	luti_api admin.ban '{"person_id":3,"ban":true,"remove_or_restore_data":true,"expires_at":99,"reason":"x"}' >/dev/null
	[ "$(jq -c 'keys' "$STUB_DIR/body")" = '["ban","expires","person_id","reason","remove_data"]' ]
	LUTI_API=v4
	luti_api admin.ban '{"person_id":3,"ban":true,"remove_or_restore_data":true,"expires_at":99,"reason":"x"}' >/dev/null
	[ "$(jq -c 'keys' "$STUB_DIR/body")" = '["ban","expires_at","person_id","reason","remove_or_restore_data"]' ]
}

@test "rename_v3 applies to GET query strings (search_term -> q)" {
	LUTI_API=v3
	luti_api search '{"search_term":"cats"}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v3/search?q=cats" ]
}

@test "fixed params are added (pm.list on v4)" {
	LUTI_API=v4
	luti_api pm.list '{"limit":2}' >/dev/null
	[ "$(cat "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v4/account/notification/list?limit=2&type_=private_message" ]
}

@test "report lists on v4 send the plural type_ the server expects" {
	LUTI_API=v4
	luti_api report.list.post '{}' >/dev/null
	luti_api report.list.pm '{}' >/dev/null
	run cat "$STUB_DIR/calls"
	[ "${lines[0]}" = "GET https://lemmy.test/api/v4/report/list?type_=posts" ]
	[ "${lines[1]}" = "GET https://lemmy.test/api/v4/report/list?type_=private_messages" ]
}

@test "pick extracts a field (account.get on v3)" {
	LUTI_API=v3
	stub_respond 200 '{"version":"0.19","my_user":{"local_user_view":{"person":{"name":"me"}}}}'
	run luti_api account.get
	[ "$status" -eq 0 ]
	[ "$(jq -r '.local_user_view.person.name' <<<"$output")" = me ]
}

@test "Lemmy error bodies become a message and non-zero exit" {
	LUTI_API=v4
	stub_respond 400 '{"error":"couldnt_find_post","message":"nope"}'
	run luti_api post.get '{"id":1}'
	[ "$status" -ne 0 ]
	[[ $output == *"post.get failed: couldnt_find_post (nope) [HTTP 400]"* ]]
}

@test "HTTP errors without a JSON body fail too" {
	LUTI_API=v4
	stub_respond 502 '<html>bad gateway</html>'
	run luti_api post.get '{"id":1}'
	[ "$status" -ne 0 ]
	[[ $output == *"HTTP 502"* ]]
}

@test "ops missing on a version are refused before any request" {
	LUTI_API=v3
	run luti_api notifications.list
	[ "$status" -ne 0 ]
	[[ $output == *"not available on API v3"* ]]
	[ ! -e "$STUB_DIR/calls" ]
}

@test "version detection prefers v4; the first request detects it once" {
	stub_respond 200 '{"version":"1.0.0"}'
	luti_connect https://lemmy.test/
	[ "$LUTI_API" = v4 ]
	[ "$LUTI_INSTANCE" = https://lemmy.test ]
	[ "$(head -1 "$STUB_DIR/calls")" = "GET https://lemmy.test/api/v4/site" ]
	rm "$STUB_DIR/calls"
	LUTI_API=""
	luti_api site.get >/dev/null
	luti_api site.get >/dev/null
	[ "$LUTI_API" = v4 ]
	[ "$(grep -c /api/v4/site "$STUB_DIR/calls")" -eq 3 ]
}

@test "luti_connect takes instance, token and API, and checks the API" {
	luti_connect https://a.test tokA v3
	[ "$LUTI_INSTANCE $LUTI_TOKEN $LUTI_API" = "https://a.test tokA v3" ]
	[ ! -e "$STUB_DIR/calls" ]
	LUTI_API=""
	run luti_connect https://a.test "" v2
	[ "$status" -ne 0 ]
	[[ $output == *"unknown API version 'v2'"* ]]
	LUTI_INSTANCE=""
	run luti_connect
	[ "$status" -ne 0 ]
}

@test "token rejected gives return code 4" {
	LUTI_API=v4
	stub_respond 401 '{"error":"not_logged_in"}'
	run luti_api account.get
	[ "$status" -eq 4 ]
	stub_respond 400 '{"error":"incorrect_login"}'
	run luti_api account.get
	[ "$status" -eq 4 ]
	stub_respond 404 '{"error":"not_found"}'
	run luti_api post.get '{"id":1}'
	[ "$status" -eq 1 ]
	run luti_api no.such.op
	[ "$status" -eq 2 ]
	[[ $output == *"unknown op no.such.op"* ]]
}

@test "luti_api_has checks the current version" {
	LUTI_API=v3
	refute luti_api_has notifications.list
	luti_api_has post.list
	LUTI_API=v4
	luti_api_has notifications.list
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
	run luti_detect_version https://lemmy.test
	[ "$output" = v3 ]
}

@test "instance URLs are normalized" {
	[ "$(luti_normalize_instance lemmy.world)" = https://lemmy.world ]
	[ "$(luti_normalize_instance http://localhost:8536//)" = http://localhost:8536 ]
}

@test "large responses (over the 128 KB argument limit) are handled: post with a big comment thread" {
	LUTI_API=v4
	stub_route "GET api/v4/post" "$(cat "$FIXTURES/v4/post_get.json")"
	# ~600 comments, well over the kernel's 128 KB limit for one argument.
	stub_route "GET api/v4/comment/list" "$(jq -c '.items as $i | .items = ([range(600)] | map($i[0] | .comment.content = ("x" * 400)))' "$FIXTURES/v4/comment_list.json")"
	run luti_post_get 1
	[ "$status" -eq 0 ]
	[ "$(jq '.comments | length' <<<"$output")" -eq 600 ]
	LUTI_RAW=1 run luti_post_get 1
	[ "$status" -eq 0 ]
	[ "$(jq '.comments.items | length' <<<"$output")" -eq 600 ]
}

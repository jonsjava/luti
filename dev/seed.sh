#!/usr/bin/env bash
# Seed the local dev Lemmy servers (see docker-compose.yml) with test data.
# Safe to re-run: existing users, communities and posts are reused.
#
# Creates on each server:
#   admin  luti_admin / luti-dev-admin-pw   (from the server config)
#   users  alice, bob (approved), carol (pending application)  password: luti-dev-user-pw
#   community "lutidev" (alice is a moderator)
#   two posts by alice, a comment by bob, a post report by bob
set -euo pipefail

ADMIN_PW="luti-dev-admin-pw"
USER_PW="luti-dev-user-pw"
SERVERS=("http://localhost:8536 v3" "http://localhost:8537 v4")

die() { echo "seed: $*" >&2; exit 1; }

# call METHOD URL [JSON]   (uses $TOKEN when set; prints the body; fails on HTTP >= 400)
call() {
	local method=$1 url=$2 body=${3:-} out code
	local args=(-sS -X "$method" -H 'Content-Type: application/json' -w '\n%{http_code}')
	[[ -n ${TOKEN:-} ]] && args+=(-H "Authorization: Bearer $TOKEN")
	[[ -n $body ]] && args+=(-d "$body")
	out=$(curl "${args[@]}" "$url")
	code=${out##*$'\n'}
	out=${out%$'\n'*}
	printf '%s' "$out"
	[[ $code -lt 400 ]] || { echo "seed: $method $url -> $code $out" >&2; return 1; }
}

login() { # login USER PASS -> jwt
	local p
	[[ $V == v3 ]] && p=user/login || p=account/auth/login
	TOKEN="" call POST "$API/$p" "$(jq -n --arg u "$1" --arg p "$2" '{username_or_email:$u,password:$p}')" | jq -r .jwt
}

register() { # register USER   (ignores "already exists")
	local p
	[[ $V == v3 ]] && p=user/register || p=account/auth/register
	TOKEN="" call POST "$API/$p" "$(jq -n --arg u "$1" --arg p "$USER_PW" \
		'{username:$u,password:$p,password_verify:$p,answer:"luti dev seed user"}')" >/dev/null 2>&1 || true
}

approve_pending() { # approve_pending USER...
	local apps id name
	apps=$(call GET "$API/admin/registration_application/list?unread_only=true&limit=50")
	for name in "$@"; do
		id=$(jq -r --arg n "$name" '(.registration_applications // .items)[]
			| select(.creator.name == $n) | .registration_application.id' <<<"$apps" | head -1)
		if [[ -n $id ]]; then
			call PUT "$API/admin/registration_application/approve" \
				"$(jq -n --argjson id "$id" '{id:$id,approve:true}')" >/dev/null
		fi
	done
}

raise_rate_limits() {
	local body
	if [[ $V == v3 ]]; then
		body='{"rate_limit_post":1000,"rate_limit_post_per_second":60,"rate_limit_comment":1000,"rate_limit_comment_per_second":60,"rate_limit_register":1000,"rate_limit_register_per_second":60,"rate_limit_search":1000,"rate_limit_search_per_second":60,"rate_limit_message":1000,"rate_limit_message_per_second":60}'
	else
		body='{"rate_limit_post_max_requests":1000,"rate_limit_post_interval_seconds":60,"rate_limit_comment_max_requests":1000,"rate_limit_comment_interval_seconds":60,"rate_limit_register_max_requests":1000,"rate_limit_register_interval_seconds":60,"rate_limit_search_max_requests":1000,"rate_limit_search_interval_seconds":60,"rate_limit_message_max_requests":1000,"rate_limit_message_interval_seconds":60}'
	fi
	call PUT "$API/site" "$body" >/dev/null
}

person_id() { call GET "$API/$([[ $V == v3 ]] && echo user || echo person)?username=$1" | jq -r '.person_view.person.id'; }

seed_server() {
	local base=$1
	V=$2 API="$base/api/$2"
	echo "Seeding $base ($V)"
	TOKEN=$(login luti_admin "$ADMIN_PW")
	[[ -n $TOKEN && $TOKEN != null ]] || die "admin login failed on $base"
	raise_rate_limits

	register alice; register bob; register carol
	approve_pending alice bob

	# Community, created by the admin; alice is added as a moderator.
	local cid
	cid=$(call GET "$API/community?name=lutidev" 2>/dev/null | jq -r '.community_view.community.id' || true)
	if [[ -z $cid || $cid == null ]]; then
		cid=$(call POST "$API/community" '{"name":"lutidev","title":"luti dev"}' | jq -r '.community_view.community.id')
	fi
	call POST "$API/community/mod" "$(jq -n --argjson c "$cid" --argjson p "$(person_id alice)" \
		'{community_id:$c,person_id:$p,added:true}')" >/dev/null 2>&1 || true # already a mod on re-runs

	# Content
	local alice bob pid
	alice=$(login alice "$USER_PW")
	bob=$(login bob "$USER_PW")
	TOKEN=$alice
	call POST "$API/community/follow" "$(jq -n --argjson c "$cid" '{community_id:$c,follow:true}')" >/dev/null
	pid=$(call GET "$API/post/list?community_id=$cid&limit=50" | jq -r '(.posts // .items)[]
		| select(.post.name == "Welcome to lutidev") | .post.id' | head -1)
	if [[ -z $pid ]]; then
		pid=$(call POST "$API/post" "$(jq -n --argjson c "$cid" \
			'{community_id:$c,name:"Welcome to lutidev",body:"First post, seeded by dev/seed.sh."}')" | jq -r '.post_view.post.id')
		call POST "$API/post" "$(jq -n --argjson c "$cid" \
			'{community_id:$c,name:"A link post",url:"https://join-lemmy.org/"}')" >/dev/null
		TOKEN=$bob
		call POST "$API/comment" "$(jq -n --argjson p "$pid" '{post_id:$p,content:"Hello from bob."}')" >/dev/null
		call POST "$API/post/report" "$(jq -n --argjson p "$pid" '{post_id:$p,reason:"seeded test report"}')" >/dev/null
	fi
	TOKEN=""
	echo "  community lutidev id=$cid, welcome post id=$pid"
}

for s in "${SERVERS[@]}"; do
	# shellcheck disable=SC2086
	seed_server $s
done
echo "Done."

#!/usr/bin/env bash
# Check every op in spec/endpoints.json exists on the dev servers.
# Each route is called (as the admin) with an empty request. Any status
# except 404/405 means the route exists; bad parameters give 400, which is fine.
# Destructive ops are only called with empty bodies, which the server rejects.
set -euo pipefail
cd "$(dirname "$0")/.."
SPEC=spec/endpoints.json
fail=0

for target in "http://localhost:8536 v3 user/login" "http://localhost:8537 v4 account/auth/login"; do
	read -r base v login <<<"$target"
	tok=$(curl -s -H 'Content-Type: application/json' \
		-d '{"username_or_email":"luti_admin","password":"luti-dev-admin-pw"}' "$base/api/$v/$login" | jq -r .jwt)
	while IFS=$'\t' read -r op method path; do
		[[ $op == auth.logout ]] && continue # would invalidate the token
		args=(-s -w '\n%{http_code}' -X "$method" -H "Authorization: Bearer $tok")
		[[ $method != GET ]] && args+=(-H 'Content-Type: application/json' -d '{}')
		out=$(curl "${args[@]}" "$base/api/$v/$path")
		code=${out##*$'\n'}
		# A 404 carrying a Lemmy JSON error (e.g. "not_found" for a missing id) is a real route.
		if [[ $code == 404 ]] && jq -e '.error' <<<"${out%$'\n'*}" >/dev/null 2>&1; then
			continue
		fi
		if [[ $code == 404 || $code == 405 ]]; then
			echo "MISSING $v $op $method $path -> $code"
			fail=1
		fi
	done < <(jq -r --arg v "$v" '.ops | to_entries[] | select(.value[$v] != null)
		| [.key, .value[$v].method, .value[$v].path] | @tsv' "$SPEC")
	echo "$v: checked $(jq --arg v "$v" '[.ops[] | select(.[$v] != null)] | length' "$SPEC") ops"
done
exit $fail

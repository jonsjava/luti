# shellcheck shell=bash
# HTTP layer: one request function driven by spec/endpoints.json.

LT_VER=${LT_VER:-}             # v3 | v4 (detected, cached, or from --api)
LT_INSTANCE=${LT_INSTANCE:-}   # base URL, e.g. https://lemmy.world
LT_TOKEN=${LT_TOKEN:-}
LT_TIMEOUT=${LUTI_TIMEOUT:-30}

# lt_spec_file: spec/endpoints.json, found relative to this script or via $LUTI_SPEC.
lt_spec_file() {
	if [[ -n ${LUTI_SPEC:-} ]]; then
		printf '%s' "$LUTI_SPEC"
	else
		printf '%s' "$LT_ROOT/spec/endpoints.json"
	fi
}

lt_spec_check() {
	local f
	f=$(lt_spec_file)
	[[ -r $f ]] || lt_die "cannot read endpoint spec at $f (set LUTI_SPEC)"
}

# lt_normalize_instance URL: add https:// when no scheme is given, drop trailing slashes.
lt_normalize_instance() {
	local u=$1
	[[ $u == *://* ]] || u="https://$u"
	while [[ $u == */ ]]; do u=${u%/}; done
	printf '%s' "$u"
}

lt_require_instance() {
	[[ -n $LT_INSTANCE ]] || LT_INSTANCE=$(lt_cfg instance)
	[[ -n $LT_INSTANCE ]] || lt_die "no instance configured for profile '$LT_PROFILE'; run 'luti login' or pass --instance"
	LT_INSTANCE=$(lt_normalize_instance "$LT_INSTANCE")
}

# lt_load_token: read the profile token if there is one (optional auth).
lt_load_token() {
	[[ -n $LT_TOKEN ]] && return 0
	LT_TOKEN=$(lt_token_read) || LT_TOKEN=""
}

lt_require_login() {
	lt_require_version
	lt_load_token
	[[ -n $LT_TOKEN ]] || lt_die "not logged in (profile '$LT_PROFILE'); run 'luti login'"
}

# lt_auth_header: header file content for curl -H @file (empty when logged out).
lt_auth_header() {
	[[ -n $LT_TOKEN ]] && printf 'Authorization: Bearer %s\n' "$LT_TOKEN"
	return 0
}

# lt_detect_version BASE: print v4 or v3, following the spec's detect.order.
lt_detect_version() {
	local base=$1 v out code
	for v in $(jq -r '.detect.order[]' "$(lt_spec_file)"); do
		out=$(curl -sS --max-time "$LT_TIMEOUT" -w '\n%{http_code}' -H 'Accept: application/json' \
			"$base/api/$v/site" 2>/dev/null) || continue
		code=${out##*$'\n'}
		out=${out%$'\n'*}
		if [[ $code == 200 ]] && jq -e '.version' <<<"$out" >/dev/null 2>&1; then
			printf '%s' "$v"
			return 0
		fi
	done
	return 1
}

# lt_require_version: set LT_VER from --api, config, cache, or detection.
lt_require_version() {
	lt_require_instance
	if [[ -z $LT_VER ]]; then
		LT_VER=$(lt_cfg api)
	fi
	if [[ -z $LT_VER ]]; then
		LT_VER=$(lt_api_cache_read "$LT_INSTANCE") || LT_VER=""
	fi
	if [[ -z $LT_VER ]]; then
		LT_VER=$(lt_detect_version "$LT_INSTANCE") ||
			lt_die "cannot reach a Lemmy 0.19+ API at $LT_INSTANCE (tried /api/v4/site and /api/v3/site)"
		lt_api_cache_write "$LT_VER" "$LT_INSTANCE"
	fi
	[[ $LT_VER == v3 || $LT_VER == v4 ]] || lt_die "unknown API version '$LT_VER' (use v3 or v4)"
}

# lt_api_has OP: true when OP exists on the current version.
lt_api_has() {
	jq -e --arg op "$1" --arg v "$LT_VER" '.ops[$op][$v] != null' "$(lt_spec_file)" >/dev/null
}

# Corrections for spec/endpoints.json entries that the live servers reject.
# They are merged over the spec entry, so they are harmless once the spec is fixed.
#   v4 report/list takes type_ = posts|comments|private_messages (plural).
LT_SPEC_FIXUPS='{
  "report.list.post":    {"v4": {"fixed": {"type_": "posts"}}},
  "report.list.comment": {"v4": {"fixed": {"type_": "comments"}}},
  "report.list.pm":      {"v4": {"fixed": {"type_": "private_messages"}}}
}'

# lt_api_prepare OP JSON: print method, path, pick, and payload (one per line).
# Applies 'fixed' params and, on v3, the 'rename_v3' map. For GET the payload
# is a query string; otherwise it is compact JSON.
lt_api_prepare() {
	jq -r --arg op "$1" --arg v "$LT_VER" --argjson req "$2" --argjson fix "$LT_SPEC_FIXUPS" '
		.ops[$op] as $o
		| if $o == null then error("unknown op \($op)")
		  elif $o[$v] == null then error("\($op) is not available on API \($v)")
		  else $o[$v] * ($fix[$op][$v] // {}) end
		| . as $d
		| ($req + ($d.fixed // {})) as $body
		| (if $v == "v3" and $d.rename_v3 then
			 $body | with_entries(.key = ($d.rename_v3[.key] // .key))
		   else $body end) as $body
		| $d.method, $d.path, ($d.pick // ""),
		  (if $d.method == "GET" then
			 $body | to_entries | map(select(.value != null)
			   | "\(.key | @uri)=\(.value | if type == "string" then . else tojson end | @uri)") | join("&")
		   else $body | tojson end)
	' "$(lt_spec_file)"
}

# lt_api OP [JSON]: call OP with request fields JSON (v4 names). Prints the
# response body on stdout. On HTTP or Lemmy errors prints a message on stderr
# and returns non-zero.
lt_api() {
	local op=$1 req=${2:-"{}"} prep method path pick payload url out code rc msg
	lt_require_version
	lt_load_token
	prep=$(lt_api_prepare "$op" "$req" 2>&1) || {
		lt_err "${prep#jq: error (at *): }"
		return 2
	}
	local lines=()
	mapfile -t lines <<<"$prep"
	method=${lines[0]}
	path=${lines[1]}
	pick=${lines[2]:-}
	payload=${lines[3]:-}
	url="$LT_INSTANCE/api/$LT_VER/$path"
	local args=(-sS -X "$method" --max-time "$LT_TIMEOUT" -w '\n%{http_code}' -H 'Accept: application/json')
	if [[ $method == GET ]]; then
		[[ -n $payload ]] && url+="?$payload"
		out=$(curl "${args[@]}" -H @<(lt_auth_header) "$url")
	else
		out=$(curl "${args[@]}" -H @<(lt_auth_header) -H 'Content-Type: application/json' \
			--data-binary @- "$url" <<<"$payload")
	fi
	rc=$?
	if [[ $rc -ne 0 ]]; then
		lt_err "$op: cannot reach $LT_INSTANCE (curl exit $rc)"
		return 1
	fi
	code=${out##*$'\n'}
	out=${out%$'\n'*}
	if jq -e 'type == "object" and has("error") and .error != null' <<<"$out" >/dev/null 2>&1; then
		msg=$(jq -r '.error + (if .message then " (" + .message + ")" else "" end)' <<<"$out")
		lt_err "$op failed: $msg [HTTP $code]"
		return 1
	fi
	if [[ ! $code =~ ^[0-9]+$ ]] || ((code >= 400)); then
		msg=$(printf '%s' "$out" | head -c 200)
		lt_err "$op failed: HTTP $code${msg:+: $msg}"
		return 1
	fi
	if [[ -n $pick ]]; then
		jq --arg k "$pick" '.[$k]' <<<"$out"
	else
		printf '%s\n' "$out"
	fi
}

# lt_api_list_key OP: the spec's "list" value for OP on this version, as JSON.
lt_api_list_key() {
	jq -c --arg op "$1" --arg v "$LT_VER" '.ops[$op][$v].list // null' "$(lt_spec_file)"
}

# lt_items OP RAW: extract the result list from a raw response.
lt_items() {
	lt_jq -c --argjson l "$(lt_api_list_key "$1")" 'include "luti"; spec_list($l)' <<<"$2"
}

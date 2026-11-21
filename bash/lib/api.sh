# shellcheck shell=bash
# HTTP layer: version detection and one request function driven by spec/endpoints.json.

# Corrections for spec entries the live servers reject. Merged over the spec
# entry, so they are harmless once the spec is fixed.
#   v4 report/list takes type_ = posts|comments|private_messages (plural).
LUTI_FIXUPS='{
  "report.list.post":    {"v4": {"fixed": {"type_": "posts"}}},
  "report.list.comment": {"v4": {"fixed": {"type_": "comments"}}},
  "report.list.pm":      {"v4": {"fixed": {"type_": "private_messages"}}}
}'

# _luti_spec_file: $LUTI_SPEC, else spec/endpoints.json next to the library
# (repo layout bash/lib -> spec, installed layout share/luti/lib -> share/luti/spec).
_luti_spec_file() {
	if [[ -n ${LUTI_SPEC:-} ]]; then
		printf '%s' "$LUTI_SPEC"
	elif [[ -r $LUTI_LIB_DIR/../spec/endpoints.json ]]; then
		printf '%s' "$LUTI_LIB_DIR/../spec/endpoints.json"
	else
		printf '%s' "$LUTI_LIB_DIR/../../spec/endpoints.json"
	fi
}

# luti_normalize_instance URL: add https:// when no scheme is given, drop trailing slashes.
luti_normalize_instance() {
	local u=${1:-}
	[[ $u == *://* ]] || u="https://$u"
	while [[ $u == */ ]]; do u=${u%/}; done
	printf '%s' "$u"
}

# luti_detect_version [INSTANCE]: print v4 or v3 (GET /api/v4/site, then /api/v3/site).
luti_detect_version() {
	local base v out code
	base=$(luti_normalize_instance "${1:-$LUTI_INSTANCE}")
	for v in v4 v3; do
		out=$(curl -sS --max-time "$LUTI_TIMEOUT" -w '\n%{http_code}' -H 'Accept: application/json' \
			"$base/api/$v/site" 2>/dev/null) || continue
		code=${out##*$'\n'}
		out=${out%$'\n'*}
		if [[ $code == 200 ]] && jq -e '.version' <<<"$out" >/dev/null 2>&1; then
			printf '%s' "$v"
			return 0
		fi
	done
	_luti_err "cannot reach a Lemmy 0.19+ API at $base (tried /api/v4/site and /api/v3/site)"
	return 1
}

# luti_connect [INSTANCE] [TOKEN] [API]: set LUTI_INSTANCE/LUTI_TOKEN/LUTI_API
# in the current shell and detect the API version if it is not given.
# Call it directly (not in $(...)) so the settings stick.
luti_connect() {
	[[ -n ${1:-} ]] && LUTI_INSTANCE=$1
	[[ $# -ge 2 ]] && LUTI_TOKEN=$2
	[[ -n ${3:-} ]] && LUTI_API=$3
	[[ -n $LUTI_INSTANCE ]] || {
		_luti_err "luti_connect: no instance given"
		return 1
	}
	LUTI_INSTANCE=$(luti_normalize_instance "$LUTI_INSTANCE")
	if [[ -z $LUTI_API ]]; then
		LUTI_API=$(luti_detect_version "$LUTI_INSTANCE") || return 1
	fi
	_luti_check_api
}

_luti_check_api() {
	[[ $LUTI_API == v3 || $LUTI_API == v4 ]] && return 0
	_luti_err "unknown API version '$LUTI_API' (use v3 or v4)"
	return 1
}

# _luti_ready: make sure an instance and API version are known.
_luti_ready() {
	[[ -n $LUTI_INSTANCE ]] || {
		_luti_err "no instance set (LUTI_INSTANCE, luti_connect or luti_config_load)"
		return 1
	}
	if [[ -z $LUTI_API ]]; then
		LUTI_INSTANCE=$(luti_normalize_instance "$LUTI_INSTANCE")
		LUTI_API=$(luti_detect_version "$LUTI_INSTANCE") || return 1
	fi
	_luti_check_api
}

_luti_need_token() {
	[[ -n $LUTI_TOKEN ]] && return 0
	_luti_err "not logged in (no LUTI_TOKEN)"
	return 1
}

# luti_api_has OP: true when OP exists on the current API version.
luti_api_has() {
	jq -e --arg op "$1" --arg v "$LUTI_API" '.ops[$op][$v] != null' "$(_luti_spec_file)" >/dev/null
}

# _luti_prepare OP JSON: print method, path, pick and payload, one per line.
# Applies 'fixed' params and, on v3, 'rename_v3'. GET payloads are query strings.
_luti_prepare() {
	jq -r --arg op "$1" --arg v "$LUTI_API" --argjson req "$2" --argjson fix "$LUTI_FIXUPS" '
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
	' "$(_luti_spec_file)"
}

_luti_auth_header() {
	[[ -n $LUTI_TOKEN ]] && printf 'Authorization: Bearer %s\n' "$LUTI_TOKEN"
	return 0
}

# _luti_http OP [JSON]: send the request; print the body, then a last line
# with the HTTP status. Returns 1 only when the server cannot be reached.
_luti_http() {
	local op=$1 req=${2:-} prep url out lines=()
	[[ -n $req ]] || req='{}'
	_luti_ready || return 2
	prep=$(_luti_prepare "$op" "$req" 2>/dev/null) || {
		prep=$(_luti_prepare "$op" "$req" 2>&1 >/dev/null)
		prep=${prep#jq: error (at *): }
		_luti_err "${prep#jq: error: }"
		return 2
	}
	mapfile -t lines <<<"$prep"
	url="$LUTI_INSTANCE/api/$LUTI_API/${lines[1]}"
	local args=(-sS -X "${lines[0]}" --max-time "$LUTI_TIMEOUT" -w '\n%{http_code}' -H 'Accept: application/json')
	if [[ ${lines[0]} == GET ]]; then
		[[ -n ${lines[3]:-} ]] && url+="?${lines[3]}"
		out=$(curl "${args[@]}" -H @<(_luti_auth_header) "$url") || {
			_luti_err "$op: cannot reach $LUTI_INSTANCE"
			return 1
		}
	else
		out=$(curl "${args[@]}" -H @<(_luti_auth_header) -H 'Content-Type: application/json' \
			--data-binary @- "$url" <<<"${lines[3]:-}") || {
			_luti_err "$op: cannot reach $LUTI_INSTANCE"
			return 1
		}
	fi
	printf '%s\n' "$out"
}

# luti_api OP [JSON]: call OP (a key of spec/endpoints.json) with request
# fields JSON (v4 field names). Prints the raw response body. On errors prints
# "luti: OP failed: ..." on stderr and returns 1 (2 for a bad op or request).
# Return code 4 means the token was rejected (HTTP 401 / incorrect_login).
luti_api() {
	local op=$1 out code msg pick rc
	_luti_ready || return 2 # here, not in the subshell below, so a detected LUTI_API is kept
	out=$(_luti_http "$op" "${2:-}") || return $?
	code=${out##*$'\n'}
	out=${out%$'\n'*}
	rc=1
	if jq -e 'type == "object" and has("error") and .error != null' <<<"$out" >/dev/null 2>&1; then
		msg=$(jq -r '.error + (if .message then " (" + .message + ")" else "" end)' <<<"$out")
		[[ $code == 401 || $msg == incorrect_login* || $msg == not_logged_in* ]] && rc=4
		_luti_err "$op failed: $msg [HTTP $code]"
		return $rc
	fi
	if [[ -z $code || $code == *[!0-9]* ]] || ((code >= 400)); then
		[[ $code == 401 ]] && rc=4
		msg=$(printf '%s' "$out" | head -c 200)
		_luti_err "$op failed: HTTP $code${msg:+: $msg}"
		return $rc
	fi
	pick=$(jq -r --arg op "$op" --arg v "$LUTI_API" '.ops[$op][$v].pick // empty' "$(_luti_spec_file)")
	if [[ -n $pick ]]; then
		jq --arg k "$pick" '.[$k]' <<<"$out"
	else
		printf '%s\n' "$out"
	fi
}

# _luti_list_key OP: the spec's "list" value for OP on this version, as JSON.
_luti_list_key() {
	jq -c --arg op "$1" --arg v "$LUTI_API" '.ops[$op][$v].list // null' "$(_luti_spec_file)"
}

# _luti_items OP RAW: the raw result list of a response.
_luti_items() {
	_luti_jq -c --argjson l "$(_luti_list_key "$1")" 'include "luti"; spec_list($l)' <<<"$2"
}

# _luti_sort_json SORT [TIME], _luti_vote_json DIR, _luti_enum VALUE:
# request transforms (also usable on their own; see luti.jq).
_luti_sort_json() { _luti_req 'sort_req($v; $spec)' "$(jq -nc --arg s "${1:-}" --arg t "${2:-}" '{sort: $s, time: $t}')"; }
_luti_vote_json() { _luti_req 'vote_req($v; $spec)' "$(jq -nc --arg d "${1:-}" '{vote: $d}')"; }
_luti_page_json() { _luti_req 'page_req($v)' "${1:-}"; }
_luti_enum() { jq -rn -L "$LUTI_LIB_DIR" --arg v "$LUTI_API" --arg x "$1" 'include "luti"; $x | enum($v)'; }

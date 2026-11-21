# shellcheck shell=bash
# Communities, people, search.

# luti_community_id NAME|ID: print the community id.
luti_community_id() {
	local c=${1:-} raw
	_luti_is_id "$c" && {
		printf '%s\n' "$c"
		return 0
	}
	[[ -n $c ]] || {
		_luti_err "a community name or id is required"
		return 1
	}
	raw=$(luti_api community.get "$(jq -nc --arg n "${c#!}" '{name: $n}')") || return
	jq -r '.community_view.community.id' <<<"$raw"
}

# luti_person_id NAME|ID: print the person id (NAME may be name@host).
luti_person_id() {
	local p=${1:-} raw
	_luti_is_id "$p" && {
		printf '%s\n' "$p"
		return 0
	}
	[[ -n $p ]] || {
		_luti_err "a user name or id is required"
		return 1
	}
	raw=$(luti_api person.get "$(jq -nc --arg n "${p#@}" '{username: $n}')") || return
	jq -r '.person_view.person.id' <<<"$raw"
}

# luti_community_list [OPTS]: {items, next}. OPTS: type, sort, limit (20), page/cursor/next.
luti_community_list() {
	local req raw
	_luti_ready || return 1
	req=$(_luti_req '{limit: (.limit // 20)} + page_req($v) + sort_req($v; $spec)
		+ (if .type then {type_: (.type | enum($v))} else {} end)' "${1:-}") || return
	raw=$(luti_api community.list "$req") || return
	_luti_emit_list community.list "$raw" 'community($v)' "$req"
}

# luti_community_get NAME|ID: {community, moderators: [{id,name}]}.
luti_community_get() {
	local c=${1:-} req raw
	_luti_ready || return 1
	if _luti_is_id "$c"; then req="{\"id\":$c}"; else req=$(jq -nc --arg n "${c#!}" '{name: $n}'); fi
	raw=$(luti_api community.get "$req") || return
	_luti_norm "$raw" '{community: (.community_view | community($v)), moderators: [.moderators[]?.moderator | who]}'
}

# _luti_community_action OP FIELD REF BOOL
_luti_community_action() {
	local cid raw
	_luti_need_token || return 1
	_luti_ready || return 1
	cid=$(luti_community_id "${3:-}") || return
	raw=$(_luti_toggle "$1" "$2" community_id "$cid" "${4:-}") || return
	_luti_norm "$raw" 'if .community_view then .community_view | community($v) else {id: $c} end' --argjson c "$cid"
}

# luti_community_follow NAME|ID [BOOL=true], luti_community_block NAME|ID [BOOL=true]: community.
luti_community_follow() { _luti_community_action community.follow follow "${1:-}" "${2:-}"; }
luti_community_block() { _luti_community_action community.block block "${1:-}" "${2:-}"; }

# luti_person_get NAME|ID [OPTS]: {person, posts, comments}. OPTS: limit (10), sort.
luti_person_get() {
	local p=${1:-} opts=${2:-} req raw content pid
	_luti_ready || return 1
	[[ -n $p ]] || {
		_luti_err "a user name or id is required"
		return 1
	}
	if _luti_is_id "$p"; then
		req=$(_luti_req '{person_id: $id, limit: (.limit // 10)} + (if .sort then {sort: (.sort | enum($v))} else {} end)' "$opts" --argjson id "$p")
	else
		req=$(_luti_req '{username: $n, limit: (.limit // 10)} + (if .sort then {sort: (.sort | enum($v))} else {} end)' "$opts" --arg n "${p#@}")
	fi || return 1
	raw=$(luti_api person.get "$req") || return
	if [[ $LUTI_API == v3 ]]; then
		content=$raw
	else
		pid=$(jq -r '.person_view.person.id' <<<"$raw")
		content=$(luti_api person.content "$(jq -c --argjson id "$pid" 'del(.username) + {person_id: $id}' <<<"$req")") || return
	fi
	if [[ $LUTI_RAW == 1 ]]; then
		jq -c --argjson c "$content" '. + {content: $c}' <<<"$raw"
		return 0
	fi
	_luti_norm "$raw" '($c | spec_list($l)) as $items | {
		person: (.person_view | person($v)),
		posts: [$items[] | select(has("comment") | not) | post($v)],
		comments: [$items[] | select(has("comment")) | comment($v)]}' \
		--argjson c "$content" --argjson l "$(_luti_list_key person.content)"
}

# luti_search QUERY [OPTS]: {posts, comments, communities, users, next}.
# OPTS: type (all|posts|comments|communities|users), community, sort, limit (10), page/cursor/next.
luti_search() {
	local q=${1:-} opts=${2:-} cid="" req raw
	[[ -n $q ]] || {
		_luti_err "search: a query is required"
		return 1
	}
	_luti_ready || return 1
	[[ -n $opts ]] || opts='{}'
	if [[ -n $(jq -r '.community // empty' <<<"$opts") ]]; then
		cid=$(luti_community_id "$(jq -r '.community' <<<"$opts")") || return
	fi
	req=$(_luti_req '{search_term: $q, limit: (.limit // 10)} + page_req($v)
		+ (if .type then {type_: (.type | enum($v))} else {} end)
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if .sort then {sort: (.sort | enum($v))} else {} end)' "$opts" --arg q "$q" --arg c "$cid") || return
	raw=$(luti_api search "$req") || return
	_luti_norm "$raw" 'search($v) as $s | $s + {next: next_page($v; $req; [$s[] | length] | add)}' --argjson req "$req"
}

# shellcheck shell=bash
# Posts and comments. Options are JSON objects; outputs are the common shapes
# documented in luti.jq. List functions print {items: [...], next: ...};
# pass "next" back as {"next": ...} to get the following page.

# luti_post_list [OPTS]: posts. OPTS: sort, time, type (all|local|subscribed|
# moderator_view), community (name or id), creator (name@host, v4 only),
# saved (bool), limit (20), page (v3) / cursor (v4) / next.
luti_post_list() {
	local req raw
	_luti_ready || return 1
	req=$(_luti_req '{limit: (.limit // 20)} + sort_req($v; $spec) + page_req($v)
		+ (if .type then {type_: (.type | enum($v))} else {} end) + community_ref
		+ opt("creator"; "creator_username") + (if .saved then {saved_only: true} else {} end)' "${1:-}") || return
	raw=$(luti_api post.list "$req") || return
	_luti_emit_list post.list "$raw" 'post($v)' "$req"
}

# luti_post_get ID [OPTS]: {post, comments}. OPTS: comments (count, 50; 0 = none), comment_sort.
luti_post_get() {
	local id=${1:-} opts=${2:-} raw craw='{}' creq
	_luti_need_id post "$id" || return 1
	_luti_ready || return 1
	[[ -n $opts ]] || opts='{}'
	raw=$(luti_api post.get "{\"id\":$id}") || return
	if [[ $(jq '.comments // 50' <<<"$opts") != 0 ]]; then
		creq=$(_luti_req '{post_id: $id, limit: (.comments // 50), max_depth: 8}
			+ (if .comment_sort then {sort: (.comment_sort | enum($v))} else {} end)' "$opts" --argjson id "$id") || return
		craw=$(luti_api comment.list "$creq") || return
	fi
	if [[ $LUTI_RAW == 1 ]]; then
		jq -c --slurpfile c <(printf '%s' "$craw") '. + {comments: $c[0]}' <<<"$raw"
		return 0
	fi
	_luti_norm "$raw" '{post: (.post_view | post($v)), comments: [($c[0] | spec_list($l))[]? | comment($v)]}' \
		--slurpfile c <(printf '%s' "$craw") --argjson l "$(_luti_list_key comment.list)"
}

_luti_print_post() { _luti_norm "$1" '.post_view | post($v)'; }
_luti_print_comment() { _luti_norm "$1" '.comment_view | comment($v)'; }

# luti_post_create OPTS: post. OPTS: community (name or id), title, body, url, nsfw.
luti_post_create() {
	local opts=${1:-} cid req raw
	[[ -n $opts ]] || opts='{}'
	_luti_need_token || return 1
	_luti_ready || return 1
	jq -e '(.community // "") != "" and (.title // "") != ""' <<<"$opts" >/dev/null || {
		_luti_err "post create: community and title are required"
		return 1
	}
	cid=$(luti_community_id "$(jq -r '.community' <<<"$opts")") || return
	req=$(_luti_req '{community_id: $c, name: .title} + opt("body"; "body") + opt("url"; "url")
		+ (if .nsfw then {nsfw: true} else {} end)' "$opts" --argjson c "$cid") || return
	raw=$(luti_api post.create "$req") || return
	_luti_print_post "$raw"
}

# luti_post_edit ID OPTS: post. OPTS: title, body, url (only given fields change).
luti_post_edit() {
	local id=${1:-} req raw
	_luti_need_id post "$id" || return 1
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{post_id: $id} + opt("title"; "name") + (if has("body") then {body: .body} else {} end)
		+ opt("url"; "url")' "${2:-}" --argjson id "$id") || return
	raw=$(luti_api post.edit "$req") || return
	_luti_print_post "$raw"
}

# _luti_toggle OP FIELD IDFIELD ID BOOL [EXTRA_JSON]: raw response of a boolean action.
_luti_toggle() {
	local op=$1 field=$2 idf=$3 id=$4 on extra=${6:-}
	[[ -n $extra ]] || extra='{}'
	on=$(_luti_bool "${5:-}" true)
	_luti_need_id "$op" "$id" || return 1
	_luti_need_token || return 1
	_luti_ready || return 1
	luti_api "$op" "$(jq -nc --arg i "$idf" --argjson id "$id" --arg f "$field" --argjson on "$on" \
		--argjson x "$extra" '{($i): $id, ($f): $on} + $x')"
}

# luti_post_delete ID [BOOL=true], luti_post_save ID [BOOL=true]: post.
luti_post_delete() {
	local raw
	raw=$(_luti_toggle post.delete deleted post_id "${1:-}" "${2:-}") || return
	_luti_print_post "$raw"
}
luti_post_save() {
	local raw
	raw=$(_luti_toggle post.save save post_id "${1:-}" "${2:-}") || return
	_luti_print_post "$raw"
}

# luti_post_vote ID up|down|clear: post.
luti_post_vote() {
	local id=${1:-} req raw
	_luti_need_id post "$id" || return 1
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{post_id: $id} + vote_req($v; $spec)' "$(jq -nc --arg d "${2:-}" '{vote: $d}')" --argjson id "$id") || return
	raw=$(luti_api post.vote "$req") || return
	_luti_print_post "$raw"
}

# luti_post_report ID REASON: report.
luti_post_report() {
	local id=${1:-} raw
	_luti_need_id post "$id" || return 1
	[[ -n ${2:-} ]] || {
		_luti_err "post report: a reason is required"
		return 1
	}
	_luti_need_token || return 1
	raw=$(luti_api post.report "$(jq -nc --argjson id "$id" --arg r "$2" '{post_id: $id, reason: $r}')") || return
	_luti_norm "$raw" '.post_report_view | report($v; "post")'
}

# luti_comment_list POST_ID [OPTS]: {items, next}. OPTS: sort, limit (50), max_depth, page/cursor/next.
luti_comment_list() {
	local id=${1:-} req raw
	_luti_need_id post "$id" || return 1
	_luti_ready || return 1
	req=$(_luti_req '{post_id: $id, limit: (.limit // 50)} + page_req($v) + opt("max_depth"; "max_depth")
		+ (if .sort then {sort: (.sort | enum($v))} else {} end)' "${2:-}" --argjson id "$id") || return
	raw=$(luti_api comment.list "$req") || return
	_luti_emit_list comment.list "$raw" 'comment($v)' "$req"
}

# luti_comment_get ID: comment.
luti_comment_get() {
	local raw
	_luti_need_id comment "${1:-}" || return 1
	_luti_ready || return 1
	raw=$(luti_api comment.get "{\"id\":$1}") || return
	_luti_print_comment "$raw"
}

# luti_comment_create OPTS: comment. OPTS: content, post_id and/or parent_id.
luti_comment_create() {
	local opts=${1:-} post parent req raw
	[[ -n $opts ]] || opts='{}'
	_luti_need_token || return 1
	_luti_ready || return 1
	post=$(jq -r '.post_id // empty' <<<"$opts")
	parent=$(jq -r '.parent_id // empty' <<<"$opts")
	if [[ -z $post && -n $parent ]]; then
		_luti_need_id "parent comment" "$parent" || return 1
		post=$(luti_api comment.get "{\"id\":$parent}" | jq -r '.comment_view.comment.post_id // empty') || return
	fi
	_luti_need_id "comment post_id" "$post" || return 1
	[[ -z $parent ]] || _luti_need_id "comment parent_id" "$parent" || return 1
	req=$(_luti_req 'if (.content // "") == "" then error("comment: content is required") else . end
		| {post_id: $p, content: .content} + (if .parent_id then {parent_id: (.parent_id | tonumber)} else {} end)' \
		"$opts" --argjson p "$post") || return
	raw=$(luti_api comment.create "$req") || return
	_luti_print_comment "$raw"
}

# luti_comment_edit ID CONTENT: comment.
luti_comment_edit() {
	local id=${1:-} raw
	_luti_need_id comment "$id" || return 1
	[[ -n ${2:-} ]] || {
		_luti_err "comment edit: content is required"
		return 1
	}
	_luti_need_token || return 1
	raw=$(luti_api comment.edit "$(jq -nc --argjson id "$id" --arg t "$2" '{comment_id: $id, content: $t}')") || return
	_luti_print_comment "$raw"
}

# luti_comment_delete ID [BOOL=true]: comment.
luti_comment_delete() {
	local raw
	raw=$(_luti_toggle comment.delete deleted comment_id "${1:-}" "${2:-}") || return
	_luti_print_comment "$raw"
}

# luti_comment_vote ID up|down|clear: comment.
luti_comment_vote() {
	local id=${1:-} req raw
	_luti_need_id comment "$id" || return 1
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{comment_id: $id} + vote_req($v; $spec)' "$(jq -nc --arg d "${2:-}" '{vote: $d}')" --argjson id "$id") || return
	raw=$(luti_api comment.vote "$req") || return
	_luti_print_comment "$raw"
}

# luti_comment_report ID REASON: report.
luti_comment_report() {
	local id=${1:-} raw
	_luti_need_id comment "$id" || return 1
	[[ -n ${2:-} ]] || {
		_luti_err "comment report: a reason is required"
		return 1
	}
	_luti_need_token || return 1
	raw=$(luti_api comment.report "$(jq -nc --argjson id "$id" --arg r "$2" '{comment_id: $id, reason: $r}')") || return
	_luti_norm "$raw" '.comment_report_view | report($v; "comment")'
}

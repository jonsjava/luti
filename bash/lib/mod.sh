# shellcheck shell=bash
# Moderation and administration.

# _luti_report_type WORD: post|comment|private_message
_luti_report_type() {
	case ${1:-} in
		post | posts) printf 'post' ;;
		comment | comments) printf 'comment' ;;
		pm | private_message | private_messages | message) printf 'private_message' ;;
		*)
			_luti_err "unknown report type '${1:-}' (use post, comment or pm)"
			return 1
			;;
	esac
}

_luti_report_op() {
	case $1 in
		post) printf 'report.list.post' ;;
		comment) printf 'report.list.comment' ;;
		private_message) printf 'report.list.pm' ;;
	esac
}

# luti_report_list [OPTS]: {items: [report]} newest first. OPTS: type
# (post|comment|pm|all, default all), all (bool: include resolved),
# community (name or id), limit (20), page (v3).
# With type all, private message reports are skipped when not allowed (moderators).
luti_report_list() {
	local opts=${1:-} type t types=() cid="" req raw out='[]' items
	[[ -n $opts ]] || opts='{}'
	_luti_need_token || return 1
	_luti_ready || return 1
	type=$(jq -r '.type // "all"' <<<"$opts")
	if [[ $type == all ]]; then
		types=(post comment private_message)
	else
		t=$(_luti_report_type "$type") || return
		types=("$t")
	fi
	if [[ -n $(jq -r '.community // empty' <<<"$opts") ]]; then
		cid=$(luti_community_id "$(jq -r '.community' <<<"$opts")") || return
	fi
	req=$(_luti_req '{unresolved_only: ((.all // false) | not), limit: (.limit // 20)}
		+ (if $v == "v3" then page_req($v) else {} end)
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)' "$opts" --arg c "$cid") || return
	local rawall='{}'
	for t in "${types[@]}"; do
		if [[ $type == all && $t == private_message ]]; then
			raw=$(luti_api "$(_luti_report_op "$t")" "$req" 2>/dev/null) || continue
		else
			raw=$(luti_api "$(_luti_report_op "$t")" "$req") || return
		fi
		rawall=$(jq -c --arg t "$t" --argjson r "$raw" '. + {($t): $r}' <<<"$rawall")
		items=$(_luti_items "$(_luti_report_op "$t")" "$raw")
		out=$(_luti_jq -c --arg v "$LUTI_API" --arg t "$t" --argjson o "$out" 'include "luti"; $o + map(report($v; $t))' <<<"$items")
	done
	_luti_emit "$rawall" "$(jq -c '{items: (sort_by(.published) | reverse)}' <<<"$out")"
}

# luti_report_resolve post|comment|pm REPORT_ID [BOOL=true]: report.
luti_report_resolve() {
	local t id=${2:-} op raw
	t=$(_luti_report_type "${1:-}") || return
	case $t in
		post) op=post.report.resolve ;;
		comment) op=comment.report.resolve ;;
		private_message) op=pm.report.resolve ;;
	esac
	raw=$(_luti_toggle "$op" resolved report_id "$id" "${3:-}") || return
	_luti_norm "$raw" '(.post_report_view // .comment_report_view // .private_message_report_view) | report($v; $t)' --arg t "$t"
}

# luti_post_remove ID [BOOL=true] [REASON], luti_comment_remove ...: post / comment.
# (BOOL false restores.)
luti_post_remove() {
	local on raw
	on=$(_luti_bool "${2:-}" true)
	raw=$(_luti_toggle post.remove removed post_id "${1:-}" "$on" \
		"$(jq -nc --arg r "${3:-$([[ $on == true ]] && echo removed || echo restored) with luti}" '{reason: $r}')") || return
	_luti_print_post "$raw"
}
luti_comment_remove() {
	local on raw
	on=$(_luti_bool "${2:-}" true)
	raw=$(_luti_toggle comment.remove removed comment_id "${1:-}" "$on" \
		"$(jq -nc --arg r "${3:-$([[ $on == true ]] && echo removed || echo restored) with luti}" '{reason: $r}')") || return
	_luti_print_comment "$raw"
}

# luti_post_lock ID [BOOL=true]: post.
luti_post_lock() {
	local raw
	raw=$(_luti_toggle post.lock locked post_id "${1:-}" "${2:-}" '{"reason":"locked with luti"}') || return 1
	_luti_print_post "$raw"
}

# luti_post_feature ID [BOOL=true] [community|local]: post.
luti_post_feature() {
	local raw scope=${3:-community}
	[[ $scope == community || $scope == local ]] || {
		_luti_err "feature scope must be community or local"
		return 1
	}
	_luti_ready || return 1
	raw=$(_luti_toggle post.feature featured post_id "${1:-}" "${2:-}" \
		"$(jq -nc --arg t "$(_luti_enum "$scope")" '{feature_type: $t}')") || return
	_luti_print_post "$raw"
}

# _luti_ban_req PERSON_ID BAN OPTS [COMMUNITY_ID]
_luti_ban_req() {
	local now
	now=$(date +%s)
	_luti_req '{person_id: $p, ban: $b, reason: (.reason // (if $b then "banned with luti" else "unbanned with luti" end))}
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if $b and .days then {expires_at: ($now + (.days | tonumber) * 86400)} else {} end)
		+ (if .remove_data then {remove_or_restore_data: true} else {} end)' \
		"${3:-}" --argjson p "$1" --argjson b "$2" --arg c "${4:-}" --argjson now "$now"
}

# luti_community_ban USER COMMUNITY [BOOL=true] [OPTS]: {person, community_id, banned}.
# OPTS: reason, days (temporary ban), remove_data (bool).
luti_community_ban() {
	local pid cid on req raw
	_luti_need_token || return 1
	_luti_ready || return 1
	on=$(_luti_bool "${3:-}" true)
	pid=$(luti_person_id "${1:-}") || return
	cid=$(luti_community_id "${2:-}") || return
	req=$(_luti_ban_req "$pid" "$on" "${4:-}" "$cid") || return
	raw=$(luti_api community.ban "$req") || return
	_luti_norm "$raw" '{person: (.person_view | person($v)), community_id: $c, banned: $b}' --argjson c "$cid" --argjson b "$on"
}

# luti_ban USER [BOOL=true] [OPTS]: site ban (admin). {person, banned}.
luti_ban() {
	local pid on req raw
	_luti_need_token || return 1
	_luti_ready || return 1
	on=$(_luti_bool "${2:-}" true)
	pid=$(luti_person_id "${1:-}") || return
	req=$(_luti_ban_req "$pid" "$on" "${3:-}") || return
	raw=$(luti_api admin.ban "$req") || return
	_luti_norm "$raw" '{person: (.person_view | person($v)), banned: $b}' --argjson b "$on"
}

# luti_modlog [OPTS]: {items: [modlog], next}. OPTS: community, user,
# type (snake_case action, e.g. mod_remove_post), limit (20), page/cursor/next.
luti_modlog() {
	local opts=${1:-} cid="" uid="" req raw
	[[ -n $opts ]] || opts='{}'
	_luti_ready || return 1
	if [[ -n $(jq -r '.community // empty' <<<"$opts") ]]; then
		cid=$(luti_community_id "$(jq -r '.community' <<<"$opts")") || return
	fi
	if [[ -n $(jq -r '.user // empty' <<<"$opts") ]]; then
		uid=$(luti_person_id "$(jq -r '.user' <<<"$opts")") || return
	fi
	req=$(_luti_req '{limit: (.limit // 20)} + page_req($v)
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if $u != "" then {other_person_id: ($u | tonumber)} else {} end)
		+ (if .type then {type_: (.type | enum($v))} else {} end)' "$opts" --arg c "$cid" --arg u "$uid") || return
	raw=$(luti_api modlog "$req") || return
	_luti_norm "$raw" '(modlog($v) | .[0:$req.limit]) as $i | {items: $i, next: next_page($v; $req; $i | length)}' --argjson req "$req"
}

# luti_registration_list [OPTS]: {items: [registration]}. OPTS: all (include decided), limit (20), page (v3).
luti_registration_list() {
	local req raw
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{unread_only: ((.all // false) | not), limit: (.limit // 20)}
		+ (if .page then page_req($v) else {} end)' "${1:-}") || return
	raw=$(luti_api admin.registrations "$req") || return
	_luti_emit_list admin.registrations "$raw" 'registration($v)' "$req"
}

# luti_registration_id ID|USERNAME: print the id of a pending application.
luti_registration_id() {
	local raw id
	_luti_is_id "${1:-}" && {
		printf '%s\n' "$1"
		return 0
	}
	raw=$(luti_api admin.registrations '{"unread_only": true, "limit": 50}') || return
	id=$(_luti_items admin.registrations "$raw" | _luti_jq -r --arg v "$LUTI_API" --arg n "${1#@}" 'include "luti";
		map(registration($v)) | map(select(.username == $n)) | first | .id // empty')
	[[ -n $id ]] || {
		_luti_err "no pending registration application from '${1:-}'"
		return 1
	}
	printf '%s\n' "$id"
}

# luti_registration_decide ID|USERNAME BOOL [DENY_REASON]: registration (true approves, false denies).
luti_registration_decide() {
	local id on raw
	_luti_need_token || return 1
	_luti_ready || return 1
	on=$(_luti_bool "${2:-}" true)
	id=$(luti_registration_id "${1:-}") || return
	raw=$(luti_api admin.approve "$(jq -nc --argjson id "$id" --argjson a "$on" --arg r "${3:-}" '
		{id: $id, approve: $a} + (if $r != "" then {deny_reason: $r} else {} end)')") || return
	_luti_norm "$raw" '.registration_application | registration($v)'
}

# luti_purge person|community|post|comment ID|NAME [REASON]: {kind, id, purged}. Cannot be undone.
luti_purge() {
	local kind=${1:-} id raw
	case $kind in
		person | user) kind=person ;;
		community | post | comment) ;;
		*)
			_luti_err "purge: kind must be person, community, post or comment"
			return 1
			;;
	esac
	_luti_need_token || return 1
	_luti_ready || return 1
	case $kind in
		person) id=$(luti_person_id "${2:-}") || return 1 ;;
		community) id=$(luti_community_id "${2:-}") || return 1 ;;
		*)
			_luti_need_id "purge $kind" "${2:-}" || return 1
			id=$2
			;;
	esac
	raw=$(luti_api "admin.purge.$kind" "$(jq -nc --arg k "${kind}_id" --argjson id "$id" --arg r "${3:-purged with luti}" \
		'{($k): $id, reason: $r}')") || return
	_luti_emit "$raw" "$(jq -nc --arg k "$kind" --argjson id "$id" '{kind: $k, id: $id, purged: true}')"
}

# luti_counts: {reports, post_reports, comment_reports, private_message_reports, registrations, notifications}.
luti_counts() {
	local raw norm u regs
	_luti_need_token || return 1
	_luti_ready || return 1
	raw=$(luti_api report.count) || return
	norm=$(_luti_jq -c --arg v "$LUTI_API" 'include "luti"; counts($v)' <<<"$raw")
	if [[ $LUTI_API == v3 ]]; then
		if u=$(luti_api unread.counts 2>/dev/null); then
			norm=$(jq -c --argjson u "$u" '.notifications = (($u.replies // 0) + ($u.mentions // 0) + ($u.private_messages // 0))' <<<"$norm")
		fi
		if regs=$(luti_api admin.registrations '{"unread_only": true, "limit": 50}' 2>/dev/null); then
			norm=$(jq -c --argjson n "$(_luti_items admin.registrations "$regs" | jq length)" '.registrations = $n' <<<"$norm")
		fi
	fi
	_luti_emit "$raw" "$norm"
}

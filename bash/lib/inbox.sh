# shellcheck shell=bash
# Inbox / notifications and private messages.

# luti_inbox [OPTS]: {items: [notification], next}. OPTS: unread (bool),
# limit (20), page/cursor/next. v3 merges replies, mentions and private
# messages (newest first); v4 lists notifications.
luti_inbox() {
	local req raw r m p
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{unread_only: (.unread // false), limit: (.limit // 20)} + page_req($v)' "${1:-}") || return
	if [[ $LUTI_API == v3 ]]; then
		r=$(luti_api inbox.replies "$(jq -c '. + {sort: "New"}' <<<"$req")") || return
		m=$(luti_api inbox.mentions "$(jq -c '. + {sort: "New"}' <<<"$req")") || return
		p=$(luti_api pm.list "$req") || return
		raw=$(jq -nc --slurpfile r <(_luti_items inbox.replies "$r") --slurpfile m <(_luti_items inbox.mentions "$m") \
			--slurpfile p <(_luti_items pm.list "$p") '{replies: $r[0], mentions: $m[0], private_messages: $p[0]}')
		_luti_norm "$raw" '{items: (inbox_v3 | .[0:$req.limit]), next: next_page($v; $req; [.[] | length] | max)}' --argjson req "$req"
	else
		raw=$(luti_api notifications.list "$req") || return
		_luti_norm "$raw" '[.items[]? | notif_v4] as $i | {items: $i, next: next_page($v; $req; $i | length)}' --argjson req "$req"
	fi
}

# luti_notification_read ID [BOOL=true]: mark one notification read (API v4 only).
luti_notification_read() {
	local id=${1:-} on raw
	_luti_need_id notification "$id" || return 1
	_luti_need_token || return 1
	_luti_ready || return 1
	luti_api_has notifications.read || {
		_luti_err "marking one notification needs an API v4 server; use luti_mark_all_read on v3"
		return 1
	}
	on=$(_luti_bool "${2:-}" true)
	raw=$(luti_api notifications.read "$(jq -nc --argjson id "$id" --argjson r "$on" '{notification_id: $id, read: $r}')") || return
	_luti_emit "$raw" "$(jq -nc --argjson id "$id" --argjson r "$on" '{id: $id, read: $r}')"
}

# luti_mark_all_read: mark the whole inbox read.
luti_mark_all_read() {
	local raw
	_luti_need_token || return 1
	raw=$(luti_api inbox.mark_all_read '{}') || return
	_luti_emit "$raw" '{"read":true}'
}

# luti_pm_send USER TEXT: pm.
luti_pm_send() {
	local pid raw
	[[ -n ${1:-} && -n ${2:-} ]] || {
		_luti_err "pm send: recipient and text are required"
		return 1
	}
	_luti_need_token || return 1
	_luti_ready || return 1
	pid=$(luti_person_id "$1") || return
	raw=$(luti_api pm.create "$(jq -nc --argjson r "$pid" --arg t "$2" '{recipient_id: $r, content: $t}')") || return
	_luti_norm "$raw" '.private_message_view | pm($v)'
}

# luti_pm_list [OPTS]: {items: [pm], next}. OPTS: unread, limit (20), page/cursor/next.
luti_pm_list() {
	local req raw
	_luti_need_token || return 1
	_luti_ready || return 1
	req=$(_luti_req '{unread_only: (.unread // false), limit: (.limit // 20)} + page_req($v)' "${1:-}") || return
	raw=$(luti_api pm.list "$req") || return
	_luti_emit_list pm.list "$raw" 'pm($v)' "$req"
}

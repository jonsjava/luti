# shellcheck shell=bash
# inbox, notify read

cmd_inbox() {
	local unread=false limit=20 page="" cursor=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti inbox [--unread] [--limit N] [--page N|--cursor X]

On API v3 servers shows replies, mentions and private messages together.
On API v4 servers shows notifications. New items are marked with '*'.
EOF
				return 0
				;;
			--unread | -u) unread=true ;;
			--limit | -n)
				lt_need_arg "$@"
				lt_need_int --limit "$2"
				limit=$2
				shift
				;;
			--page)
				lt_need_arg "$@"
				page=$2
				shift
				;;
			--cursor)
				lt_need_arg "$@"
				cursor=$2
				shift
				;;
			*) lt_die "inbox: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_login
	lt_require_version
	local pagej req raw norm count
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	req=$(jq -cn --argjson u "$unread" --argjson l "$limit" --argjson p "$pagej" '{unread_only: $u, limit: $l} + $p')
	if [[ $LT_VER == v3 ]]; then
		local r m p
		r=$(lt_api inbox.replies "$(jq -c '. + {sort: "New"}' <<<"$req")") || return 1
		m=$(lt_api inbox.mentions "$(jq -c '. + {sort: "New"}' <<<"$req")") || return 1
		p=$(lt_api pm.list "$req") || return 1
		raw=$(jq -cn --argjson r "$(lt_items inbox.replies "$r")" --argjson m "$(lt_items inbox.mentions "$m")" \
			--argjson p "$(lt_items pm.list "$p")" '{replies: $r, mentions: $m, private_messages: $p}')
		norm=$(lt_jq -c 'include "luti"; inbox_v3' <<<"$raw")
		count=$(jq '[.[] | length] | max' <<<"$raw")
	else
		raw=$(lt_api notifications.list "$req") || return 1
		norm=$(lt_jq -c 'include "luti"; [.items[]? | notif_v4]' <<<"$raw")
		count=$(jq length <<<"$norm")
	fi
	lt_output "$raw" "$norm" lt_show_notifications
	lt_print_next "$raw" "${page:-1}" "$count"
}

cmd_notify() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	case $sub in
		read) ;;
		"" | -h | --help)
			cat <<'EOF'
Usage: luti notify read [ID] [--unread]

With an ID (API v4), marks that notification as read (or unread with --unread).
Without an ID, marks everything in the inbox as read.
EOF
			[[ -n $sub ]]
			return
			;;
		*) lt_die "notify: unknown subcommand '$sub'" ;;
	esac
	local id="" read=true
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_notify --help
				return 0
				;;
			--unread) read=false ;;
			--all) id="" ;;
			-*) lt_die "notify read: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_require_login
	lt_require_version
	local raw
	if [[ -n $id ]]; then
		lt_need_id "notify read" "$id"
		if ! lt_api_has notifications.read; then
			lt_die "notify read ID needs an API v4 server; on v3 use 'luti notify read' to mark everything read"
		fi
		raw=$(lt_api notifications.read "$(jq -cn --argjson id "$id" --argjson r "$read" '{notification_id: $id, read: $r}')") || return 1
		if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "notification $id: read = $read"; fi
	else
		[[ $read == true ]] || lt_die "notify read --unread needs a notification id"
		raw=$(lt_api inbox.mark_all_read '{}') || return 1
		if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "marked all as read"; fi
	fi
}

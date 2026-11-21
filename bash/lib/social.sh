# shellcheck shell=bash
# pm send|list

cmd_pm() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	case $sub in
		send) lt_pm_send "$@" ;;
		list) lt_pm_list "$@" ;;
		"" | -h | --help)
			cat <<'EOF'
Usage: luti pm send USER (--text T | --text-file F)
       luti pm list [--unread] [--limit N] [--page N|--cursor X]
EOF
			[[ -n $sub ]]
			;;
		*) lt_die "pm: unknown subcommand '$sub'" ;;
	esac
}

lt_pm_send() {
	local to="" text="" textfile=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_pm --help
				return 0
				;;
			--text | -m)
				[[ $# -ge 2 ]] || lt_die "--text needs a value"
				text=$2
				shift
				;;
			--text-file)
				lt_need_arg "$@"
				textfile=$2
				shift
				;;
			-*) lt_die "pm send: unknown option '$1'" ;;
			*) to=$1 ;;
		esac
		shift
	done
	[[ -n $to ]] || lt_die "pm send: give a recipient"
	lt_require_login
	text=$(_lt_read_body "$text" "$textfile")
	[[ -n $text ]] || lt_die "pm send: --text is required"
	local pid raw
	pid=$(lt_person_id "$to") || return 1
	raw=$(lt_api pm.create "$(jq -cn --argjson r "$pid" --arg t "$text" '{recipient_id: $r, content: $t}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "sent message $(jq -r '.private_message_view.private_message.id' <<<"$raw") to $to"
	fi
}

lt_pm_list() {
	local unread=false limit=20 page="" cursor=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_pm --help
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
			*) lt_die "pm list: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_login
	lt_require_version
	local pagej raw items norm
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	raw=$(lt_api pm.list "$(jq -cn --argjson u "$unread" --argjson l "$limit" --argjson p "$pagej" \
		'{unread_only: $u, limit: $l} + $p')") || return 1
	items=$(lt_items pm.list "$raw")
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; map(pm($v))' <<<"$items")
	lt_output "$raw" "$norm" lt_show_pms
	lt_print_next "$raw" "${page:-1}" "$(jq length <<<"$items")"
}

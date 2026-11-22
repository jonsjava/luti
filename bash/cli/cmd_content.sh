# shellcheck shell=bash
# post, comment, inbox, notify, pm

cli_post_help() {
	cat <<'EOF'
Usage:
  luti post view ID [--comments N] [--sort hot|top|new|old|controversial] [-o|--open]
  luti post create --community C --title T [--body B | --body-file F] [--url U] [--nsfw]
  luti post edit ID [--title T] [--body B | --body-file F] [--url U]
  luti post delete ID [--undo]
  luti post save ID [--undo]
  luti post vote ID up|down|clear
  luti post report ID --reason R

'post view -o' also opens the post in the browser (see luti open --help).
EOF
}

cmd_post() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_post_help
		return 0
	fi
	case $sub in
		view) cli_post_view "$@" ;;
		create) cli_post_create "$@" ;;
		edit) cli_post_edit "$@" ;;
		delete | save)
			local id="" on=true out
			while [[ $# -gt 0 ]]; do
				case $1 in
					--undo) on=false ;;
					-*) cli_die "post $sub: unknown option '$1'" ;;
					*) id=$1 ;;
				esac
				shift
			done
			cli_login_required
			out=$("luti_post_$sub" "$id" "$on") || exit
			cli_ok "$out" "post $id: $([[ $sub == delete ]] && echo deleted || echo saved) = $on"
			;;
		vote)
			[[ $# -eq 2 ]] || cli_die "post vote: give an id and up, down or clear"
			cli_login_required
			local out
			out=$(luti_post_vote "$1" "$2") || exit
			cli_ok "$out" "$(cli_field "$out" '"post \(.id): score \(.score), your vote: \(.my_vote // "none")"')"
			;;
		report)
			local id="" reason="" out
			while [[ $# -gt 0 ]]; do
				case $1 in
					--reason | -r)
						cli_need_arg "$@"
						reason=$2
						shift
						;;
					-*) cli_die "post report: unknown option '$1'" ;;
					*) id=$1 ;;
				esac
				shift
			done
			[[ -n $reason ]] || cli_die "post report: --reason is required"
			cli_login_required
			out=$(luti_post_report "$id" "$reason") || exit
			cli_ok "$out" "reported post $id (report $(cli_field "$out" .id))"
			;;
		"" | -h | --help)
			cli_post_help
			[[ -n $sub ]]
			;;
		*) cli_die "post: unknown subcommand '$sub'" ;;
	esac
}

cli_post_view() {
	local id="" n=50 csort="" open=false out
	while [[ $# -gt 0 ]]; do
		case $1 in
			--comments)
				cli_need_arg "$@"
				cli_need_int --comments "$2"
				n=$2
				shift
				;;
			--sort)
				cli_need_arg "$@"
				csort=$2
				shift
				;;
			-o | --open) open=true ;;
			-*) cli_die "post view: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	[[ -n $id ]] || cli_die "post view: an id is required"
	cli_ready
	out=$(luti_post_get "$id" "$(jq -nc --argjson n "$n" --arg s "$csort" '{comments: $n} + (if $s != "" then {comment_sort: $s} else {} end)')") || exit
	cli_show "$out" '(.post | post_full), "", (.comments | comments_thread)'
	if [[ $open == true ]]; then
		luti_open_url "$(luti_url post "$id")" || exit
	fi
}

cli_post_create() {
	local community="" title="" body="" bodyfile="" url="" nsfw=false out
	while [[ $# -gt 0 ]]; do
		case $1 in
			--community | -c)
				cli_need_arg "$@"
				community=$2
				shift
				;;
			--title)
				cli_need_arg "$@"
				title=$2
				shift
				;;
			--body)
				[[ $# -ge 2 ]] || cli_die "--body needs a value"
				body=$2
				shift
				;;
			--body-file)
				cli_need_arg "$@"
				bodyfile=$2
				shift
				;;
			--url)
				cli_need_arg "$@"
				url=$2
				shift
				;;
			--nsfw) nsfw=true ;;
			*) cli_die "post create: unknown option '$1'" ;;
		esac
		shift
	done
	[[ -n $community ]] || cli_die "post create: --community is required"
	[[ -n $title ]] || cli_die "post create: --title is required"
	cli_login_required
	body=$(cli_body "$body" "$bodyfile")
	out=$(luti_post_create "$(jq -nc --arg c "$community" --arg t "$title" --arg b "$body" --arg u "$url" --argjson n "$nsfw" \
		'{community: $c, title: $t, nsfw: $n} + (if $b != "" then {body: $b} else {} end) + (if $u != "" then {url: $u} else {} end)')") || exit
	cli_show "$out" 'post_full'
}

cli_post_edit() {
	local id="" title="" body="" bodyfile="" url="" hb=false out
	while [[ $# -gt 0 ]]; do
		case $1 in
			--title)
				cli_need_arg "$@"
				title=$2
				shift
				;;
			--body)
				[[ $# -ge 2 ]] || cli_die "--body needs a value"
				body=$2
				hb=true
				shift
				;;
			--body-file)
				cli_need_arg "$@"
				bodyfile=$2
				hb=true
				shift
				;;
			--url)
				cli_need_arg "$@"
				url=$2
				shift
				;;
			-*) cli_die "post edit: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	[[ -n $title || $hb == true || -n $url ]] || cli_die "post edit: nothing to change (use --title, --body or --url)"
	cli_login_required
	[[ $hb == true ]] && body=$(cli_body "$body" "$bodyfile")
	out=$(luti_post_edit "$id" "$(jq -nc --arg t "$title" --arg b "$body" --argjson hb "$hb" --arg u "$url" \
		'(if $t != "" then {title: $t} else {} end) + (if $hb then {body: $b} else {} end) + (if $u != "" then {url: $u} else {} end)')") || exit
	cli_show "$out" 'post_full'
}

cli_comment_help() {
	cat <<'EOF'
Usage:
  luti comment reply --post ID [--parent COMMENT_ID] (--text T | --text-file F)
  luti comment reply COMMENT_ID (--text T | --text-file F)      reply to a comment
  luti comment edit ID (--text T | --text-file F)
  luti comment delete ID [--undo]
  luti comment vote ID up|down|clear
  luti comment report ID --reason R
EOF
}

# cli_text_args ARGS...: parse --text/--text-file/--post/--parent/--reason/--undo
# and one positional id into CLI_T_* variables.
cli_text_args() {
	CLI_T_TEXT="" CLI_T_FILE="" CLI_T_POST="" CLI_T_PARENT="" CLI_T_REASON="" CLI_T_ID="" CLI_T_UNDO=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--text | -m)
				[[ $# -ge 2 ]] || cli_die "--text needs a value"
				CLI_T_TEXT=$2
				shift
				;;
			--text-file)
				cli_need_arg "$@"
				CLI_T_FILE=$2
				shift
				;;
			--post | -p)
				cli_need_arg "$@"
				CLI_T_POST=$2
				shift
				;;
			--parent)
				cli_need_arg "$@"
				CLI_T_PARENT=$2
				shift
				;;
			--reason | -r)
				cli_need_arg "$@"
				CLI_T_REASON=$2
				shift
				;;
			--undo) CLI_T_UNDO=true ;;
			-*) cli_die "unknown option '$1'" ;;
			*) CLI_T_ID=$1 ;;
		esac
		shift
	done
}

cmd_comment() {
	local sub=${1:-} out text on
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_comment_help
		return 0
	fi
	case $sub in
		reply)
			cli_text_args "$@"
			[[ -n $CLI_T_ID && -z $CLI_T_PARENT ]] && CLI_T_PARENT=$CLI_T_ID
			[[ -n $CLI_T_POST || -n $CLI_T_PARENT ]] || cli_die "comment reply: give --post ID or a comment id to reply to"
			cli_login_required
			text=$(cli_body "$CLI_T_TEXT" "$CLI_T_FILE")
			[[ -n $text ]] || cli_die "comment reply: --text is required"
			out=$(luti_comment_create "$(jq -nc --arg p "$CLI_T_POST" --arg par "$CLI_T_PARENT" --arg t "$text" \
				'{content: $t} + (if $p != "" then {post_id: $p} else {} end) + (if $par != "" then {parent_id: $par} else {} end)')") || exit
			cli_show "$out" 'comment_full'
			;;
		edit)
			cli_text_args "$@"
			cli_login_required
			text=$(cli_body "$CLI_T_TEXT" "$CLI_T_FILE")
			[[ -n $text ]] || cli_die "comment edit: --text is required"
			out=$(luti_comment_edit "$CLI_T_ID" "$text") || exit
			cli_show "$out" 'comment_full'
			;;
		delete)
			cli_text_args "$@"
			cli_login_required
			on=$([[ $CLI_T_UNDO == true ]] && echo false || echo true)
			out=$(luti_comment_delete "$CLI_T_ID" "$on") || exit
			cli_ok "$out" "comment $CLI_T_ID: deleted = $on"
			;;
		vote)
			[[ $# -eq 2 ]] || cli_die "comment vote: give an id and up, down or clear"
			cli_login_required
			out=$(luti_comment_vote "$1" "$2") || exit
			cli_ok "$out" "$(cli_field "$out" '"comment \(.id): score \(.score), your vote: \(.my_vote // "none")"')"
			;;
		report)
			cli_text_args "$@"
			[[ -n $CLI_T_REASON ]] || cli_die "comment report: --reason is required"
			cli_login_required
			out=$(luti_comment_report "$CLI_T_ID" "$CLI_T_REASON") || exit
			cli_ok "$out" "reported comment $CLI_T_ID (report $(cli_field "$out" .id))"
			;;
		"" | -h | --help)
			cli_comment_help
			[[ -n $sub ]]
			;;
		*) cli_die "comment: unknown subcommand '$sub'" ;;
	esac
}

# cli_list_args ARGS...: --unread --limit --page --cursor into CLI_L_OPTS (JSON).
cli_list_args() {
	local unread=false limit=20 page="" cursor="" what=$1
	shift
	while [[ $# -gt 0 ]]; do
		case $1 in
			--unread | -u) unread=true ;;
			--limit | -n)
				cli_need_arg "$@"
				cli_need_int --limit "$2"
				limit=$2
				shift
				;;
			--page)
				cli_need_arg "$@"
				cli_need_int --page "$2"
				page=$2
				shift
				;;
			--cursor)
				cli_need_arg "$@"
				cursor=$2
				shift
				;;
			*) cli_die "$what: unknown option '$1'" ;;
		esac
		shift
	done
	CLI_L_OPTS=$(jq -nc --argjson u "$unread" --argjson l "$limit" --argjson p "$(cli_page_opts "$page" "$cursor")" \
		'{unread: $u, limit: $l} + $p')
}

cmd_inbox() {
	if cli_help_requested "$@"; then
		cat <<'EOF'
Usage: luti inbox [--unread] [--limit N] [--page N|--cursor X]

On API v3 servers shows replies, mentions and private messages together.
On API v4 servers shows notifications. New items are marked with '*'.
EOF
		return 0
	fi
	cli_list_args inbox "$@"
	cli_login_required
	local out
	out=$(luti_inbox "$CLI_L_OPTS") || exit
	cli_show_list "$out" 'notifications_table($w)'
}

cmd_notify() {
	local sub=${1:-} id="" read=true out
	[[ $# -gt 0 ]] && shift
	if [[ $sub != read ]] || cli_help_requested "$@"; then
		cat <<'EOF'
Usage: luti notify read [ID] [--unread]

With an ID (API v4), marks that notification as read (or unread with --unread).
Without an ID, marks everything in the inbox as read.
EOF
		[[ $sub == read || $sub == -h || $sub == --help ]]
		return
	fi
	while [[ $# -gt 0 ]]; do
		case $1 in
			--unread) read=false ;;
			--all) id="" ;;
			-*) cli_die "notify read: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	cli_login_required
	if [[ -n $id ]]; then
		out=$(luti_notification_read "$id" "$read") || exit
		cli_ok "$out" "notification $id: read = $read"
	else
		[[ $read == true ]] || cli_die "notify read --unread needs a notification id"
		out=$(luti_mark_all_read) || exit
		cli_ok "$out" "marked all as read"
	fi
}

cmd_pm() {
	local sub=${1:-} out text
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@" || [[ $sub != send && $sub != list ]]; then
		cat <<'EOF'
Usage: luti pm send USER (--text T | --text-file F)
       luti pm list [--unread] [--limit N] [--page N|--cursor X]
EOF
		[[ $sub == send || $sub == list || $sub == -h || $sub == --help ]]
		return
	fi
	if [[ $sub == send ]]; then
		cli_text_args "$@"
		[[ -n $CLI_T_ID ]] || cli_die "pm send: give a recipient"
		cli_login_required
		text=$(cli_body "$CLI_T_TEXT" "$CLI_T_FILE")
		[[ -n $text ]] || cli_die "pm send: --text is required"
		out=$(luti_pm_send "$CLI_T_ID" "$text") || exit
		cli_ok "$out" "sent message $(cli_field "$out" .id) to $CLI_T_ID"
	else
		cli_list_args "pm list" "$@"
		cli_login_required
		out=$(luti_pm_list "$CLI_L_OPTS") || exit
		cli_show_list "$out" 'pms_table($w)'
	fi
}

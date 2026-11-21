# shellcheck shell=bash
# comment reply|edit|delete|vote|report

lt_comment_help() {
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

cmd_comment() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if lt_help_requested "$@"; then
		lt_comment_help
		return 0
	fi
	case $sub in
		reply) lt_comment_reply "$@" ;;
		edit) lt_comment_edit "$@" ;;
		delete) lt_comment_delete "$@" ;;
		vote) lt_comment_vote "$@" ;;
		report) lt_comment_report "$@" ;;
		"" | -h | --help)
			lt_comment_help
			[[ -n $sub ]]
			;;
		*) lt_die "comment: unknown subcommand '$sub'" ;;
	esac
}

lt_comment_reply() {
	local post="" parent="" text="" textfile="" target=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--post | -p)
				lt_need_arg "$@"
				post=$2
				shift
				;;
			--parent)
				lt_need_arg "$@"
				parent=$2
				shift
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
			-*) lt_die "comment reply: unknown option '$1'" ;;
			*) target=$1 ;;
		esac
		shift
	done
	[[ -n $target && -z $parent ]] && parent=$target
	[[ -n $post || -n $parent ]] || lt_die "comment reply: give --post ID or a comment id to reply to"
	[[ -z $post ]] || lt_need_id "comment reply --post" "$post"
	[[ -z $parent ]] || lt_need_id "comment reply --parent" "$parent"
	lt_require_login
	text=$(_lt_read_body "$text" "$textfile")
	[[ -n $text ]] || lt_die "comment reply: --text is required"
	if [[ -z $post ]]; then
		post=$(lt_api comment.get "$(jq -cn --argjson id "$parent" '{id: $id}')" |
			jq -r '.comment_view.comment.post_id') || return 1
		[[ $post =~ ^[0-9]+$ ]] || return 1
	fi
	local req raw
	req=$(jq -cn --argjson p "$post" --arg par "$parent" --arg t "$text" '
		{post_id: $p, content: $t} + (if $par != "" then {parent_id: ($par | tonumber)} else {} end)')
	raw=$(lt_api comment.create "$req") || return 1
	lt_print_written "$raw" comment
}

lt_comment_edit() {
	local id="" text="" textfile=""
	while [[ $# -gt 0 ]]; do
		case $1 in
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
			-*) lt_die "comment edit: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "comment edit" "$id"
	lt_require_login
	text=$(_lt_read_body "$text" "$textfile")
	[[ -n $text ]] || lt_die "comment edit: --text is required"
	local raw
	raw=$(lt_api comment.edit "$(jq -cn --argjson id "$id" --arg t "$text" '{comment_id: $id, content: $t}')") || return 1
	lt_print_written "$raw" comment
}

lt_comment_delete() {
	local id="" undo=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--undo) undo=true ;;
			-*) lt_die "comment delete: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "comment delete" "$id"
	lt_require_login
	local raw on
	on=$([[ $undo == true ]] && echo false || echo true)
	raw=$(lt_api comment.delete "$(jq -cn --argjson id "$id" --argjson on "$on" '{comment_id: $id, deleted: $on}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "comment $id: deleted = $on"; fi
}

lt_comment_vote() {
	local id=${1:-} dir=${2:-} vj raw
	lt_need_id "comment vote" "$id"
	[[ -n $dir ]] || lt_die "comment vote: give up, down or clear"
	lt_require_login
	vj=$(lt_vote_json "$dir") || return 1
	raw=$(lt_api comment.vote "$(jq -cn --argjson id "$id" --argjson v "$vj" '{comment_id: $id} + $v')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_jq -r --arg v "$LT_VER" 'include "luti"; .comment_view | comment($v)
			| "comment \(.id): score \(.score), your vote: \(.my_vote // "none")"' <<<"$raw"
	fi
}

lt_comment_report() {
	local id="" reason=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reason | -r)
				lt_need_arg "$@"
				reason=$2
				shift
				;;
			-*) lt_die "comment report: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "comment report" "$id"
	[[ -n $reason ]] || lt_die "comment report: --reason is required"
	lt_require_login
	local raw
	raw=$(lt_api comment.report "$(jq -cn --argjson id "$id" --arg r "$reason" '{comment_id: $id, reason: $r}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "reported comment $id (report $(jq -r '.comment_report_view.comment_report.id // "?"' <<<"$raw"))"
	fi
}

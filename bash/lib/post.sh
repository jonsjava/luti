# shellcheck shell=bash
# post view|create|edit|delete|save|vote|report

lt_post_help() {
	cat <<'EOF'
Usage:
  luti post view ID [--comments N] [--sort hot|top|new|old|controversial]
  luti post create --community C --title T [--body B | --body-file F] [--url U] [--nsfw]
  luti post edit ID [--title T] [--body B | --body-file F] [--url U]
  luti post delete ID [--undo]
  luti post save ID [--undo]
  luti post vote ID up|down|clear
  luti post report ID --reason R
EOF
}

cmd_post() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if lt_help_requested "$@"; then
		lt_post_help
		return 0
	fi
	case $sub in
		view) lt_post_view "$@" ;;
		create) lt_post_create "$@" ;;
		edit) lt_post_edit "$@" ;;
		delete) lt_post_flag post.delete deleted "$@" ;;
		save) lt_post_flag post.save save "$@" ;;
		vote) lt_post_vote "$@" ;;
		report) lt_post_report "$@" ;;
		"" | -h | --help)
			lt_post_help
			[[ -n $sub ]]
			;;
		*) lt_die "post: unknown subcommand '$sub'" ;;
	esac
}

lt_need_id() {
	[[ -n ${2:-} ]] || lt_die "$1: an id is required"
	[[ $2 =~ ^[0-9]+$ ]] || lt_die "$1: id must be a number, got '$2'"
}

# lt_print_written RAW KIND: show the post/comment returned by a write.
lt_print_written() {
	local raw=$1 kind=$2 norm
	if [[ $LT_JSON == 1 ]]; then
		printf '%s\n' "$raw"
		return
	fi
	if [[ $kind == post ]]; then
		norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; .post_view | post($v)' <<<"$raw")
		if [[ $LT_NORM == 1 ]]; then printf '%s\n' "$norm"; else lt_show_post <<<"$norm"; fi
	else
		norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; .comment_view | comment($v)' <<<"$raw")
		if [[ $LT_NORM == 1 ]]; then printf '%s\n' "$norm"; else lt_show_comment <<<"$norm"; fi
	fi
}

lt_post_view() {
	local id="" ncomments=50 csort=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--comments)
				lt_need_arg "$@"
				lt_need_int --comments "$2"
				ncomments=$2
				shift
				;;
			--sort)
				lt_need_arg "$@"
				csort=$2
				shift
				;;
			-*) lt_die "post view: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "post view" "$id"
	lt_require_version
	lt_load_token
	local raw craw items norm
	raw=$(lt_api post.get "$(jq -cn --argjson id "$id" '{id: $id}')") || return 1
	craw='{}'
	if [[ $ncomments -gt 0 ]]; then
		craw=$(lt_api comment.list "$(jq -cn --argjson id "$id" --argjson l "$ncomments" \
			--arg s "${csort:+$(lt_enum "$csort")}" '{post_id: $id, limit: $l, max_depth: 8}
			+ (if $s != "" then {sort: $s} else {} end)')") || return 1
	fi
	items=$(lt_items comment.list "$craw")
	norm=$(lt_jq -c --arg v "$LT_VER" --argjson c "$items" 'include "luti";
		{post: (.post_view | post($v)), comments: [$c[]? | comment($v)]}' <<<"$raw")
	# shellcheck disable=SC2329  # called through lt_output
	_lt_show_post_view() {
		local j
		j=$(cat)
		jq -c '.post' <<<"$j" | lt_show_post
		printf '\n'
		jq -c '.comments' <<<"$j" | lt_show_comments
	}
	if [[ $LT_JSON == 1 ]]; then
		jq -c --argjson c "$craw" '. + {comments: $c}' <<<"$raw"
	else
		lt_output "$raw" "$norm" _lt_show_post_view
	fi
}

# _lt_read_body BODY FILE: print the body text from --body or --body-file (- = stdin).
_lt_read_body() {
	if [[ -n $2 ]]; then
		if [[ $2 == - ]]; then cat; else
			[[ -r $2 ]] || lt_die "cannot read $2"
			cat -- "$2"
		fi
	else
		printf '%s' "$1"
	fi
}

lt_post_create() {
	local community="" title="" body="" bodyfile="" url="" nsfw=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--community | -c)
				lt_need_arg "$@"
				community=$2
				shift
				;;
			--title)
				lt_need_arg "$@"
				title=$2
				shift
				;;
			--body)
				[[ $# -ge 2 ]] || lt_die "--body needs a value"
				body=$2
				shift
				;;
			--body-file)
				lt_need_arg "$@"
				bodyfile=$2
				shift
				;;
			--url)
				lt_need_arg "$@"
				url=$2
				shift
				;;
			--nsfw) nsfw=true ;;
			*) lt_die "post create: unknown option '$1'" ;;
		esac
		shift
	done
	[[ -n $community ]] || lt_die "post create: --community is required"
	[[ -n $title ]] || lt_die "post create: --title is required"
	lt_require_login
	local cid req raw
	cid=$(lt_community_id "$community") || return 1
	body=$(_lt_read_body "$body" "$bodyfile")
	req=$(jq -cn --argjson c "$cid" --arg t "$title" --arg b "$body" --arg u "$url" --argjson n "$nsfw" '
		{community_id: $c, name: $t}
		+ (if $b != "" then {body: $b} else {} end)
		+ (if $u != "" then {url: $u} else {} end)
		+ (if $n then {nsfw: true} else {} end)')
	raw=$(lt_api post.create "$req") || return 1
	lt_print_written "$raw" post
}

lt_post_edit() {
	local id="" title="" body="" bodyfile="" url="" have_body=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--title)
				lt_need_arg "$@"
				title=$2
				shift
				;;
			--body)
				[[ $# -ge 2 ]] || lt_die "--body needs a value"
				body=$2
				have_body=true
				shift
				;;
			--body-file)
				lt_need_arg "$@"
				bodyfile=$2
				have_body=true
				shift
				;;
			--url)
				lt_need_arg "$@"
				url=$2
				shift
				;;
			-*) lt_die "post edit: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "post edit" "$id"
	[[ -n $title || $have_body == true || -n $url ]] || lt_die "post edit: nothing to change (use --title, --body or --url)"
	lt_require_login
	[[ $have_body == true ]] && body=$(_lt_read_body "$body" "$bodyfile")
	local req raw
	req=$(jq -cn --argjson id "$id" --arg t "$title" --arg b "$body" --argjson hb "$have_body" --arg u "$url" '
		{post_id: $id}
		+ (if $t != "" then {name: $t} else {} end)
		+ (if $hb then {body: $b} else {} end)
		+ (if $u != "" then {url: $u} else {} end)')
	raw=$(lt_api post.edit "$req") || return 1
	lt_print_written "$raw" post
}

# lt_post_flag OP FIELD ID [--undo]: delete / save style toggles.
lt_post_flag() {
	local op=$1 field=$2 id="" undo=false
	shift 2
	while [[ $# -gt 0 ]]; do
		case $1 in
			--undo) undo=true ;;
			-*) lt_die "${op/./ }: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "${op/./ }" "$id"
	lt_require_login
	local req raw
	req=$(jq -cn --argjson id "$id" --arg f "$field" --argjson on "$([[ $undo == true ]] && echo false || echo true)" \
		'{post_id: $id} + {($f): $on}')
	raw=$(lt_api "$op" "$req") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "post $id: ${field} = $([[ $undo == true ]] && echo false || echo true)"
	fi
}

lt_post_vote() {
	local id=${1:-} dir=${2:-} vj req raw
	lt_need_id "post vote" "$id"
	[[ -n $dir ]] || lt_die "post vote: give up, down or clear"
	lt_require_login
	vj=$(lt_vote_json "$dir") || return 1
	req=$(jq -cn --argjson id "$id" --argjson v "$vj" '{post_id: $id} + $v')
	raw=$(lt_api post.vote "$req") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_jq -r --arg v "$LT_VER" 'include "luti"; .post_view | post($v)
			| "post \(.id): score \(.score), your vote: \(.my_vote // "none")"' <<<"$raw"
	fi
}

lt_post_report() {
	local id="" reason=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reason | -r)
				lt_need_arg "$@"
				reason=$2
				shift
				;;
			-*) lt_die "post report: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "post report" "$id"
	[[ -n $reason ]] || lt_die "post report: --reason is required"
	lt_require_login
	local raw
	raw=$(lt_api post.report "$(jq -cn --argjson id "$id" --arg r "$reason" '{post_id: $id, reason: $r}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "reported post $id (report $(jq -r '.post_report_view.post_report.id // "?"' <<<"$raw"))"
	fi
}

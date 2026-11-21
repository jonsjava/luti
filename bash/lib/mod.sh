# shellcheck shell=bash
# mod reports|resolve|remove|restore|lock|feature|ban|unban, modlog

lt_mod_help() {
	cat <<'EOF'
Usage:
  luti mod reports [--type post|comment|pm|all] [--all] [--community C] [--limit N]
  luti mod resolve post|comment|pm REPORT_ID [--undo]
  luti mod remove post|comment ID [--reason R]
  luti mod restore post|comment ID [--reason R]
  luti mod lock POST_ID [--undo]
  luti mod feature POST_ID [--local] [--undo]
  luti mod ban USER --community C [--reason R] [--days N] [--remove-data]
  luti mod unban USER --community C [--reason R]

'mod reports' shows open reports; --all includes resolved ones.
EOF
}

cmd_mod() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if lt_help_requested "$@"; then
		lt_mod_help
		return 0
	fi
	case $sub in
		reports) lt_mod_reports "$@" ;;
		resolve) lt_mod_resolve "$@" ;;
		remove) lt_mod_remove true "$@" ;;
		restore) lt_mod_remove false "$@" ;;
		lock) lt_mod_lock "$@" ;;
		feature) lt_mod_feature "$@" ;;
		ban) lt_mod_ban true "$@" ;;
		unban) lt_mod_ban false "$@" ;;
		"" | -h | --help)
			lt_mod_help
			[[ -n $sub ]]
			;;
		*) lt_die "mod: unknown subcommand '$sub'" ;;
	esac
}

# lt_report_type WORD: post|comment|private_message
lt_report_type() {
	case $1 in
		post | posts) echo post ;;
		comment | comments) echo comment ;;
		pm | private_message | message) echo private_message ;;
		*) lt_die "unknown report type '$1' (use post, comment or pm)" ;;
	esac
}

lt_report_list_op() {
	case $1 in
		post) echo report.list.post ;;
		comment) echo report.list.comment ;;
		private_message) echo report.list.pm ;;
	esac
}

lt_mod_reports() {
	local type=all all=false community="" limit=20 page=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--type)
				lt_need_arg "$@"
				type=$2
				shift
				;;
			--all | -a) all=true ;;
			--community | -c)
				lt_need_arg "$@"
				community=$2
				shift
				;;
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
			*) lt_die "mod reports: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_login
	lt_require_version
	local types=() t cid="" req raws="{}" norm="[]" raw items
	if [[ $type == all ]]; then
		types=(post comment private_message)
	else
		types=("$(lt_report_type "$type")")
	fi
	[[ -n $community ]] && { cid=$(lt_community_id "$community") || return 1; }
	local pagej='{}'
	[[ $LT_VER == v3 ]] && { pagej=$(lt_page_json "$page" "") || return 1; }
	req=$(jq -cn --argjson u "$([[ $all == true ]] && echo false || echo true)" --argjson l "$limit" \
		--arg c "$cid" --argjson p "$pagej" '{unresolved_only: $u, limit: $l} + $p
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)')
	for t in "${types[@]}"; do
		if [[ $type == all && $t == private_message ]]; then
			# Private message reports are admin-only; skip them quietly for moderators.
			raw=$(lt_api "$(lt_report_list_op "$t")" "$req" 2>/dev/null) || continue
		else
			raw=$(lt_api "$(lt_report_list_op "$t")" "$req") || return 1
		fi
		items=$(lt_items "$(lt_report_list_op "$t")" "$raw")
		raws=$(jq -c --arg t "$t" --argjson r "$raw" '. + {($t): $r}' <<<"$raws")
		norm=$(lt_jq -c --arg v "$LT_VER" --arg t "$t" --argjson n "$norm" 'include "luti";
			$n + map(report($v; $t))' <<<"$items")
	done
	norm=$(jq -c 'sort_by(.published) | reverse' <<<"$norm")
	lt_output "$raws" "$norm" lt_show_reports
}

lt_mod_resolve() {
	local type="" id="" undo=false op
	while [[ $# -gt 0 ]]; do
		case $1 in
			--undo) undo=true ;;
			-*) lt_die "mod resolve: unknown option '$1'" ;;
			*) if [[ -z $type && ! $1 =~ ^[0-9]+$ ]]; then type=$1; else id=$1; fi ;;
		esac
		shift
	done
	type=$(lt_report_type "${type:-post}")
	lt_need_id "mod resolve" "$id"
	case $type in
		post) op=post.report.resolve ;;
		comment) op=comment.report.resolve ;;
		private_message) op=pm.report.resolve ;;
	esac
	lt_require_login
	local raw resolved
	resolved=$([[ $undo == true ]] && echo false || echo true)
	raw=$(lt_api "$op" "$(jq -cn --argjson id "$id" --argjson r "$resolved" '{report_id: $id, resolved: $r}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "$type report $id: resolved = $resolved"
	fi
}

lt_mod_remove() {
	local removed=$1 kind="" id="" reason=""
	shift
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reason | -r)
				lt_need_arg "$@"
				reason=$2
				shift
				;;
			-*) lt_die "mod remove: unknown option '$1'" ;;
			*) if [[ -z $kind && ! $1 =~ ^[0-9]+$ ]]; then kind=$1; else id=$1; fi ;;
		esac
		shift
	done
	[[ $kind == post || $kind == comment ]] || lt_die "mod remove/restore: give 'post ID' or 'comment ID'"
	lt_need_id "mod $([[ $removed == true ]] && echo remove || echo restore)" "$id"
	[[ -n $reason ]] || reason=$([[ $removed == true ]] && echo "removed with luti" || echo "restored with luti")
	lt_require_login
	local raw
	raw=$(lt_api "$kind.remove" "$(jq -cn --arg k "${kind}_id" --argjson id "$id" --argjson r "$removed" --arg why "$reason" \
		'{($k): $id, removed: $r, reason: $why}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "$kind $id: removed = $removed"; fi
}

lt_mod_lock() {
	local id="" undo=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--undo) undo=true ;;
			-*) lt_die "mod lock: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "mod lock" "$id"
	lt_require_login
	local raw on
	on=$([[ $undo == true ]] && echo false || echo true)
	raw=$(lt_api post.lock "$(jq -cn --argjson id "$id" --argjson on "$on" '{post_id: $id, locked: $on, reason: "locked with luti"}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "post $id: locked = $on"; fi
}

lt_mod_feature() {
	local id="" undo=false scope=community
	while [[ $# -gt 0 ]]; do
		case $1 in
			--undo) undo=true ;;
			--local) scope=local ;;
			-*) lt_die "mod feature: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	lt_need_id "mod feature" "$id"
	lt_require_login
	lt_require_version
	local raw on
	on=$([[ $undo == true ]] && echo false || echo true)
	raw=$(lt_api post.feature "$(jq -cn --argjson id "$id" --argjson on "$on" --arg t "$(lt_enum "$scope")" \
		'{post_id: $id, featured: $on, feature_type: $t}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "post $id: featured ($scope) = $on"; fi
}

# _lt_ban_request PERSON_ID BAN REASON DAYS REMOVE_DATA [COMMUNITY_ID]
_lt_ban_request() {
	local exp=""
	[[ -n $4 ]] && exp=$(($(date +%s) + $4 * 86400))
	jq -cn --argjson p "$1" --argjson b "$2" --arg r "$3" --arg e "$exp" --argjson rd "$5" --arg c "${6:-}" '
		{person_id: $p, ban: $b, reason: $r}
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if $e != "" and $b then {expires_at: ($e | tonumber)} else {} end)
		+ (if $rd then {remove_or_restore_data: true} else {} end)'
}

# _lt_ban_args ARGS...: parse USER [--community C] [--reason R] [--days N] [--remove-data]
# into _B_USER _B_COMMUNITY _B_REASON _B_DAYS _B_RD.
_lt_ban_args() {
	_B_USER="" _B_COMMUNITY="" _B_REASON="" _B_DAYS="" _B_RD=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--community | -c)
				lt_need_arg "$@"
				_B_COMMUNITY=$2
				shift
				;;
			--reason | -r)
				lt_need_arg "$@"
				_B_REASON=$2
				shift
				;;
			--days)
				lt_need_arg "$@"
				lt_need_int --days "$2"
				_B_DAYS=$2
				shift
				;;
			--remove-data) _B_RD=true ;;
			-*) lt_die "ban: unknown option '$1'" ;;
			*) _B_USER=$1 ;;
		esac
		shift
	done
	[[ -n $_B_USER ]] || lt_die "ban: give a user name or id"
}

lt_mod_ban() {
	local ban=$1
	shift
	_lt_ban_args "$@"
	[[ -n $_B_COMMUNITY ]] || lt_die "mod $([[ $ban == true ]] && echo ban || echo unban): --community is required (site bans: luti admin ban)"
	[[ -n $_B_REASON ]] || _B_REASON=$([[ $ban == true ]] && echo "banned with luti" || echo "unbanned with luti")
	lt_require_login
	local pid cid raw
	pid=$(lt_person_id "$_B_USER") || return 1
	cid=$(lt_community_id "$_B_COMMUNITY") || return 1
	raw=$(lt_api community.ban "$(_lt_ban_request "$pid" "$ban" "$_B_REASON" "$_B_DAYS" "$_B_RD" "$cid")") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "$_B_USER in community $cid: banned = $ban"
	fi
}

cmd_modlog() {
	local community="" user="" type="" limit=20 page="" cursor=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti modlog [--community C] [--user U] [--type T] [--limit N] [--page N|--cursor X]

--type takes a snake_case action such as mod_remove_post, mod_ban_from_community
or admin_ban (names follow the server's ModlogActionType / ModlogKind).
EOF
				return 0
				;;
			--community | -c)
				lt_need_arg "$@"
				community=$2
				shift
				;;
			--user | -u)
				lt_need_arg "$@"
				user=$2
				shift
				;;
			--type)
				lt_need_arg "$@"
				type=$2
				shift
				;;
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
			*) lt_die "modlog: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_version
	lt_load_token
	local cid="" uid="" pagej req raw norm
	[[ -n $community ]] && { cid=$(lt_community_id "$community") || return 1; }
	[[ -n $user ]] && { uid=$(lt_person_id "$user") || return 1; }
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	req=$(jq -cn --argjson l "$limit" --argjson p "$pagej" --arg c "$cid" --arg u "$uid" --arg t "${type:+$(lt_enum "$type")}" '
		{limit: $l} + $p
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if $u != "" then {other_person_id: ($u | tonumber)} else {} end)
		+ (if $t != "" then {type_: $t} else {} end)')
	raw=$(lt_api modlog "$req") || return 1
	norm=$(lt_jq -c --arg v "$LT_VER" --argjson l "$limit" 'include "luti"; modlog($v) | .[0:$l]' <<<"$raw")
	lt_output "$raw" "$norm" lt_show_modlog
	lt_print_next "$raw" "${page:-1}" "$(jq length <<<"$norm")"
}

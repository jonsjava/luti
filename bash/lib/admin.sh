# shellcheck shell=bash
# admin registrations|approve|deny|ban|unban|purge

lt_admin_help() {
	cat <<'EOF'
Usage:
  luti admin registrations [--all] [--limit N]
  luti admin approve APPLICATION_ID|USERNAME
  luti admin deny APPLICATION_ID|USERNAME [--reason R]
  luti admin ban USER [--reason R] [--days N] [--remove-data]
  luti admin unban USER [--reason R]
  luti admin purge person|community|post|comment ID|NAME [--reason R] [--yes]

'registrations' shows pending applications; --all includes decided ones.
Purging cannot be undone and asks for confirmation unless --yes is given.
EOF
}

cmd_admin() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if lt_help_requested "$@"; then
		lt_admin_help
		return 0
	fi
	case $sub in
		registrations | regs) lt_admin_registrations "$@" ;;
		approve) lt_admin_decide true "$@" ;;
		deny) lt_admin_decide false "$@" ;;
		ban) lt_admin_ban true "$@" ;;
		unban) lt_admin_ban false "$@" ;;
		purge) lt_admin_purge "$@" ;;
		"" | -h | --help)
			lt_admin_help
			[[ -n $sub ]]
			;;
		*) lt_die "admin: unknown subcommand '$sub'" ;;
	esac
}

lt_admin_registrations() {
	local all=false limit=20 page=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--all | -a) all=true ;;
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
			*) lt_die "admin registrations: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_login
	lt_require_version
	local pagej='{}' raw items norm
	[[ -n $page ]] && { pagej=$(lt_page_json "$page" "") || return 1; }
	raw=$(lt_api admin.registrations "$(jq -cn --argjson u "$([[ $all == true ]] && echo false || echo true)" \
		--argjson l "$limit" --argjson p "$pagej" '{unread_only: $u, limit: $l} + $p')") || return 1
	items=$(lt_items admin.registrations "$raw")
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; map(registration($v))' <<<"$items")
	lt_output "$raw" "$norm" lt_show_registrations
}

# lt_application_id ID_OR_USERNAME: print a registration application id.
lt_application_id() {
	if [[ $1 =~ ^[0-9]+$ ]]; then
		printf '%s' "$1"
		return 0
	fi
	local raw id
	raw=$(lt_api admin.registrations '{"unread_only": true, "limit": 50}') || return 1
	id=$(lt_items admin.registrations "$raw" | lt_jq -r --arg v "$LT_VER" --arg n "${1#@}" 'include "luti";
		map(registration($v)) | map(select(.username == $n)) | first | .id // empty')
	[[ -n $id ]] || {
		lt_err "no pending registration application from '$1'"
		return 1
	}
	printf '%s' "$id"
}

lt_admin_decide() {
	local approve=$1 target="" reason=""
	shift
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reason | -r)
				lt_need_arg "$@"
				reason=$2
				shift
				;;
			-*) lt_die "admin approve/deny: unknown option '$1'" ;;
			*) target=$1 ;;
		esac
		shift
	done
	[[ -n $target ]] || lt_die "admin $([[ $approve == true ]] && echo approve || echo deny): give an application id or username"
	lt_require_login
	lt_require_version
	local id raw
	id=$(lt_application_id "$target") || return 1
	raw=$(lt_api admin.approve "$(jq -cn --argjson id "$id" --argjson a "$approve" --arg r "$reason" '
		{id: $id, approve: $a} + (if $r != "" then {deny_reason: $r} else {} end)')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_jq -r --arg v "$LT_VER" 'include "luti"; .registration_application | registration($v)
			| "application \(.id) from \(.username): \(.status)"' <<<"$raw"
	fi
}

lt_admin_ban() {
	local ban=$1
	shift
	_lt_ban_args "$@"
	[[ -z $_B_COMMUNITY ]] || lt_die "admin ban is a site ban; for a community ban use: luti mod ban USER --community C"
	[[ -n $_B_REASON ]] || _B_REASON=$([[ $ban == true ]] && echo "banned with luti" || echo "unbanned with luti")
	lt_require_login
	local pid raw
	pid=$(lt_person_id "$_B_USER") || return 1
	raw=$(lt_api admin.ban "$(_lt_ban_request "$pid" "$ban" "$_B_REASON" "$_B_DAYS" "$_B_RD")") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "$_B_USER: site ban = $ban"
	fi
}

lt_admin_purge() {
	local kind="" target="" reason=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			--reason | -r)
				lt_need_arg "$@"
				reason=$2
				shift
				;;
			-*) lt_die "admin purge: unknown option '$1'" ;;
			*) if [[ -z $kind ]]; then kind=$1; else target=$1; fi ;;
		esac
		shift
	done
	case $kind in
		person | user) kind=person ;;
		community | post | comment) ;;
		*) lt_die "admin purge: give person, community, post or comment, then an id" ;;
	esac
	[[ -n $target ]] || lt_die "admin purge $kind: an id is required"
	lt_require_login
	local id raw
	case $kind in
		person) id=$(lt_person_id "$target") || return 1 ;;
		community) id=$(lt_community_id "$target") || return 1 ;;
		*)
			lt_need_id "admin purge $kind" "$target"
			id=$target
			;;
	esac
	lt_confirm "Permanently purge $kind $target (id $id) and all its content? This cannot be undone." ||
		lt_die "purge cancelled"
	raw=$(lt_api "admin.purge.$kind" "$(jq -cn --arg k "${kind}_id" --argjson id "$id" --arg r "${reason:-purged with luti}" \
		'{($k): $id, reason: $r}')") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else lt_show_ok "purged $kind $id"; fi
}

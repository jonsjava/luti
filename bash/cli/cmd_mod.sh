# shellcheck shell=bash
# mod, modlog, admin

cli_mod_help() {
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
To be alerted when new reports arrive, use 'luti watch reports'.
EOF
}

# cli_ban_args ARGS...: USER [--community C] [--reason R] [--days N] [--remove-data]
cli_ban_args() {
	CLI_B_USER="" CLI_B_COMMUNITY="" CLI_B_OPTS='{}'
	local reason="" days="" rd=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			--community | -c)
				cli_need_arg "$@"
				CLI_B_COMMUNITY=$2
				shift
				;;
			--reason | -r)
				cli_need_arg "$@"
				reason=$2
				shift
				;;
			--days)
				cli_need_arg "$@"
				cli_need_int --days "$2"
				days=$2
				shift
				;;
			--remove-data) rd=true ;;
			-*) cli_die "ban: unknown option '$1'" ;;
			*) CLI_B_USER=$1 ;;
		esac
		shift
	done
	[[ -n $CLI_B_USER ]] || cli_die "ban: give a user name or id"
	CLI_B_OPTS=$(jq -nc --arg r "$reason" --arg d "$days" --argjson rd "$rd" \
		'(if $r != "" then {reason: $r} else {} end) + (if $d != "" then {days: ($d | tonumber)} else {} end) + (if $rd then {remove_data: true} else {} end)')
}

cmd_mod() {
	local sub=${1:-} out
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_mod_help
		return 0
	fi
	case $sub in
		reports)
			local type=all all=false community="" limit=20 page=""
			while [[ $# -gt 0 ]]; do
				case $1 in
					--type)
						cli_need_arg "$@"
						type=$2
						shift
						;;
					--all | -a) all=true ;;
					--community | -c)
						cli_need_arg "$@"
						community=$2
						shift
						;;
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
					*) cli_die "mod reports: unknown option '$1'" ;;
				esac
				shift
			done
			cli_login_required
			out=$(luti_report_list "$(jq -nc --arg t "$type" --argjson a "$all" --arg c "$community" --argjson l "$limit" --arg p "$page" \
				'{type: $t, all: $a, limit: $l} + (if $c != "" then {community: $c} else {} end) + (if $p != "" then {page: ($p | tonumber)} else {} end)')") || exit
			cli_show "$out" '.items | reports_table($w)'
			;;
		resolve)
			local type="" id="" on=true
			while [[ $# -gt 0 ]]; do
				case $1 in
					--undo) on=false ;;
					-*) cli_die "mod resolve: unknown option '$1'" ;;
					*) if [[ -z $type && $1 == *[!0-9]* ]]; then type=$1; else id=$1; fi ;;
				esac
				shift
			done
			cli_login_required
			out=$(luti_report_resolve "${type:-post}" "$id" "$on") || exit
			cli_ok "$out" "${type:-post} report $id: resolved = $on"
			;;
		remove | restore)
			local kind="" id="" reason="" on
			on=$([[ $sub == remove ]] && echo true || echo false)
			while [[ $# -gt 0 ]]; do
				case $1 in
					--reason | -r)
						cli_need_arg "$@"
						reason=$2
						shift
						;;
					-*) cli_die "mod $sub: unknown option '$1'" ;;
					*) if [[ -z $kind && $1 == *[!0-9]* ]]; then kind=$1; else id=$1; fi ;;
				esac
				shift
			done
			[[ $kind == post || $kind == comment ]] || cli_die "mod $sub: give 'post ID' or 'comment ID'"
			cli_login_required
			out=$("luti_${kind}_remove" "$id" "$on" "$reason") || exit
			cli_ok "$out" "$kind $id: removed = $on"
			;;
		lock | feature)
			local id="" on=true scope=community
			while [[ $# -gt 0 ]]; do
				case $1 in
					--undo) on=false ;;
					--local) scope=local ;;
					-*) cli_die "mod $sub: unknown option '$1'" ;;
					*) id=$1 ;;
				esac
				shift
			done
			cli_login_required
			if [[ $sub == lock ]]; then
				out=$(luti_post_lock "$id" "$on") || exit
				cli_ok "$out" "post $id: locked = $on"
			else
				out=$(luti_post_feature "$id" "$on" "$scope") || exit
				cli_ok "$out" "post $id: featured ($scope) = $on"
			fi
			;;
		ban | unban)
			cli_ban_args "$@"
			[[ -n $CLI_B_COMMUNITY ]] || cli_die "mod $sub: --community is required (site bans: luti admin ban)"
			cli_login_required
			out=$(luti_community_ban "$CLI_B_USER" "$CLI_B_COMMUNITY" "$([[ $sub == ban ]] && echo true || echo false)" "$CLI_B_OPTS") || exit
			cli_ok "$out" "$CLI_B_USER in community $CLI_B_COMMUNITY: banned = $([[ $sub == ban ]] && echo true || echo false)"
			;;
		"" | -h | --help)
			cli_mod_help
			[[ -n $sub ]]
			;;
		*) cli_die "mod: unknown subcommand '$sub'" ;;
	esac
}

cmd_modlog() {
	local community="" user="" type="" limit=20 page="" cursor="" out
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti modlog [--community C] [--user U] [--type T] [--limit N] [--page N|--cursor X]

--type takes a snake_case action such as mod_remove_post, mod_ban_from_community
or mod_lock_post.
EOF
				return 0
				;;
			--community | -c)
				cli_need_arg "$@"
				community=$2
				shift
				;;
			--user | -u)
				cli_need_arg "$@"
				user=$2
				shift
				;;
			--type)
				cli_need_arg "$@"
				type=$2
				shift
				;;
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
			*) cli_die "modlog: unknown option '$1'" ;;
		esac
		shift
	done
	cli_ready
	out=$(luti_modlog "$(jq -nc --arg c "$community" --arg u "$user" --arg t "$type" --argjson l "$limit" \
		--argjson p "$(cli_page_opts "$page" "$cursor")" '{limit: $l} + $p + (if $c != "" then {community: $c} else {} end)
		+ (if $u != "" then {user: $u} else {} end) + (if $t != "" then {type: $t} else {} end)')") || exit
	cli_show_list "$out" 'modlog_table'
}

cli_admin_help() {
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
	local sub=${1:-} out
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_admin_help
		return 0
	fi
	case $sub in
		registrations | regs)
			local all=false limit=20
			while [[ $# -gt 0 ]]; do
				case $1 in
					--all | -a) all=true ;;
					--limit | -n)
						cli_need_arg "$@"
						cli_need_int --limit "$2"
						limit=$2
						shift
						;;
					*) cli_die "admin registrations: unknown option '$1'" ;;
				esac
				shift
			done
			cli_login_required
			out=$(luti_registration_list "{\"all\":$all,\"limit\":$limit}") || exit
			cli_show "$out" '.items | registrations_table($w)'
			;;
		approve | deny)
			local target="" reason=""
			while [[ $# -gt 0 ]]; do
				case $1 in
					--reason | -r)
						cli_need_arg "$@"
						reason=$2
						shift
						;;
					-*) cli_die "admin $sub: unknown option '$1'" ;;
					*) target=$1 ;;
				esac
				shift
			done
			[[ -n $target ]] || cli_die "admin $sub: give an application id or username"
			cli_login_required
			out=$(luti_registration_decide "$target" "$([[ $sub == approve ]] && echo true || echo false)" "$reason") || exit
			cli_ok "$out" "$(cli_field "$out" '"application \(.id) from \(.username): \(.status)"')"
			;;
		ban | unban)
			cli_ban_args "$@"
			[[ -z $CLI_B_COMMUNITY ]] || cli_die "admin ban is a site ban; for a community ban use: luti mod ban USER --community C"
			cli_login_required
			out=$(luti_ban "$CLI_B_USER" "$([[ $sub == ban ]] && echo true || echo false)" "$CLI_B_OPTS") || exit
			cli_ok "$out" "$CLI_B_USER: site ban = $([[ $sub == ban ]] && echo true || echo false)"
			;;
		purge)
			local kind="" target="" reason=""
			while [[ $# -gt 0 ]]; do
				case $1 in
					--reason | -r)
						cli_need_arg "$@"
						reason=$2
						shift
						;;
					-*) cli_die "admin purge: unknown option '$1'" ;;
					*) if [[ -z $kind ]]; then kind=$1; else target=$1; fi ;;
				esac
				shift
			done
			case $kind in
				person | user | community | post | comment) ;;
				*) cli_die "admin purge: give person, community, post or comment, then an id" ;;
			esac
			[[ -n $target ]] || cli_die "admin purge $kind: an id is required"
			cli_login_required
			cli_confirm "Permanently purge $kind $target and all its content? This cannot be undone." || cli_die "purge cancelled"
			out=$(luti_purge "$kind" "$target" "$reason") || exit
			cli_ok "$out" "purged $kind $target"
			;;
		"" | -h | --help)
			cli_admin_help
			[[ -n $sub ]]
			;;
		*) cli_die "admin: unknown subcommand '$sub'" ;;
	esac
}

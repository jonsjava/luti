# shellcheck shell=bash
# watch: the original luti report-count loop.

# lt_counts: print normalized counts JSON for the logged-in user.
lt_counts() {
	local raw norm regs
	raw=$(lt_api report.count) || return 1
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; counts($v)' <<<"$raw")
	if [[ $LT_VER == v3 ]]; then
		# v3 has no combined count; add unread inbox items, and pending
		# applications when the account is an admin (errors are ignored).
		local u
		if u=$(lt_api unread.counts 2>/dev/null); then
			norm=$(jq -c --argjson u "$u" '.notifications = (($u.replies // 0) + ($u.mentions // 0) + ($u.private_messages // 0))' <<<"$norm")
		fi
		if regs=$(lt_api admin.registrations '{"unread_only": true, "limit": 50}' 2>/dev/null); then
			norm=$(jq -c --argjson n "$(lt_items admin.registrations "$regs" | jq length)" '.registrations = $n' <<<"$norm")
		fi
	fi
	printf '%s\n' "$norm"
}

cmd_watch() {
	local refresh=60 once=false
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti watch [--refresh SECONDS] [--once]

Clears the screen and shows open report counts (and pending registration
applications and unread inbox items), refreshing every SECONDS (default 60).
--once prints the counts a single time and exits.
EOF
				return 0
				;;
			--refresh | -r)
				lt_need_arg "$@"
				lt_need_int --refresh "$2"
				refresh=$2
				shift
				;;
			--refresh=*)
				refresh=${1#*=}
				lt_need_int --refresh "$refresh"
				;;
			--once | -1) once=true ;;
			*) lt_die "watch: unknown option '$1'" ;;
		esac
		shift
	done
	((refresh > 0)) || lt_die "--refresh must be at least 1"
	lt_require_login
	lt_require_version
	local norm
	if [[ $once == true ]]; then
		norm=$(lt_counts) || return 1
		if [[ $LT_JSON == 1 || $LT_NORM == 1 ]]; then printf '%s\n' "$norm"; else lt_show_counts <<<"$norm"; fi
		return 0
	fi
	while true; do
		norm=$(lt_counts 2>&1) || norm=""
		[[ -t 1 ]] && clear
		printf '%s  %s (%s)\n\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LT_INSTANCE" "$(lt_cfg username)"
		if [[ -n $norm && $norm == \{* ]]; then
			lt_show_counts <<<"$norm"
		else
			lt_err "could not fetch counts; retrying in ${refresh}s"
		fi
		sleep "$refresh"
	done
}

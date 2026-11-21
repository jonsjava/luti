# shellcheck shell=bash
# watch (alerting monitor), star, stargaze

cli_watch_help() {
	cat <<'EOF'
Usage: luti watch [reports|registrations|inbox|stars|all] [OPTIONS]

Keeps polling and alerts when something new arrives:
  reports        open post, comment and message reports (default; moderators)
  registrations  pending registration applications (admins)
  inbox          unread replies, mentions, messages / notifications
  stars          new posts from your starred users (see luti stargaze --help)
  all            all of the above (registrations only for admins)

New items are tracked by id, so a report that arrives while another is
resolved still alerts. The first poll only records what is already pending.

Options:
  --refresh N     seconds between polls (default 60, minimum 10)
  --community C   only reports from community C
  --quiet         no terminal bell
  --sound FILE    play FILE (pw-play, paplay, aplay or afplay) instead of the bell
  --notify        desktop notification (notify-send or osascript)
  --exec CMD      run CMD (with bash -c) once per new item, the item's JSON on stdin
  --once          poll once against the saved state and exit: 0 = something new,
                  1 = nothing new, 2 = error, 3 = login expired. For cron and scripts.
                  State: ${XDG_STATE_HOME:-~/.local/state}/luti/<profile>/watch-<kind>

Network errors back off (doubling up to 10 minutes) and keep going. An
expired login stops the watch (run luti login). Ctrl-C quits.

Examples:
  luti watch                         # reports, bell on new ones
  luti watch all --notify --refresh 30
  luti watch reports --community lutidev --exec 'curl -s -d @- https://ntfy.sh/my-mod-queue'
  */5 * * * * luti watch reports --once --notify   # crontab
EOF
}

# cli_alert NEW_ITEMS_JSON: bell / sound / notification once, --exec per item.
cli_alert() {
	local items=$1 n p item first
	n=$(jq length <<<"$items")
	[[ $n -gt 0 ]] || return 0
	if [[ $CLI_W_QUIET != true && $CLI_W_ONCE != true ]]; then
		local played=false
		if [[ -n $CLI_W_SOUND && -r $CLI_W_SOUND ]]; then
			for p in pw-play paplay aplay afplay; do
				if command -v "$p" >/dev/null 2>&1; then
					("$p" "$CLI_W_SOUND" </dev/null >/dev/null 2>&1 &)
					played=true
					break
				fi
			done
		fi
		[[ $played == true ]] || printf '\a' >/dev/tty 2>/dev/null || printf '\a'
	fi
	if [[ $CLI_W_NOTIFY == true ]]; then
		first=$(cli_jq -r --argjson w 120 'include "display"; .[0] | watch_line($w)' <<<"$items")
		if command -v notify-send >/dev/null 2>&1; then
			notify-send "luti: $n new" "$first" >/dev/null 2>&1 || true
		elif command -v osascript >/dev/null 2>&1; then
			# Only luti's own text (a count) goes into the AppleScript string.
			osascript -e "display notification \"$n new item(s)\" with title \"luti\"" >/dev/null 2>&1 || true
		fi
	fi
	if [[ -n $CLI_W_EXEC ]]; then
		while IFS= read -r item; do
			printf '%s\n' "$item" | bash -c "$CLI_W_EXEC" >&2 || cli_err "--exec hook failed for $(jq -r .key <<<"$item")"
		done < <(jq -c '.[]' <<<"$items")
	fi
	return 0
}

cmd_watch() {
	local kinds=() k refresh=60 community=""
	CLI_W_QUIET=false CLI_W_ONCE=false CLI_W_SOUND="" CLI_W_NOTIFY=false CLI_W_EXEC=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cli_watch_help
				return 0
				;;
			reports | registrations | inbox | stars | all) kinds+=("$1") ;;
			--refresh | -r)
				cli_need_arg "$@"
				cli_need_int --refresh "$2"
				refresh=$2
				shift
				;;
			--refresh=*)
				refresh=${1#*=}
				cli_need_int --refresh "$refresh"
				;;
			--community | -c)
				cli_need_arg "$@"
				community=$2
				shift
				;;
			--quiet | -q) CLI_W_QUIET=true ;;
			--sound)
				cli_need_arg "$@"
				CLI_W_SOUND=$2
				shift
				;;
			--notify) CLI_W_NOTIFY=true ;;
			--exec)
				cli_need_arg "$@"
				CLI_W_EXEC=$2
				shift
				;;
			--once | -1) CLI_W_ONCE=true ;;
			*) cli_die "watch: unknown argument '$1' (see luti watch --help)" ;;
		esac
		shift
	done
	((refresh >= 10)) || cli_die "--refresh must be at least 10 seconds"
	[[ ${#kinds[@]} -gt 0 ]] || kinds=(reports)
	cli_login_required
	if [[ " ${kinds[*]} " == *" all "* ]]; then
		kinds=(reports inbox stars)
		if [[ $(LUTI_RAW=0 luti_whoami 2>/dev/null | jq -r '.admin') == true ]]; then
			kinds=(reports registrations inbox stars)
		fi
	fi
	local opts
	opts=$(jq -nc --arg c "$community" 'if $c != "" then {community: $c} else {} end')
	if [[ $CLI_W_ONCE == true ]]; then
		cli_watch_once "$opts" "${kinds[@]}"
	else
		cli_watch_loop "$refresh" "$opts" "${kinds[@]}"
	fi
}

# cli_watch_once OPTS KIND...: one poll against the saved state.
cli_watch_once() {
	local opts=$1 k res rc dir all='[]' summary='{}'
	shift
	dir=$(luti_state_dir)
	mkdir -p "$dir" || exit 2
	for k in "$@"; do
		res=$(LUTI_RAW=0 luti_watch_poll "$k" "$dir/watch-$k" "$opts")
		rc=$?
		[[ $rc -eq 4 ]] && {
			cli_err "login expired or rejected; run 'luti login'"
			exit 3
		}
		[[ $rc -eq 0 ]] || exit 2
		all=$(jq -c --argjson a "$all" '$a + .new' <<<"$res")
		summary=$(jq -c --argjson s "$summary" '$s + {(.kind): {pending, baseline, new: (.new | length)}}' <<<"$res")
	done
	if [[ $CLI_JSON == 1 || $CLI_NORM == 1 ]]; then
		jq -nc --argjson n "$all" --argjson s "$summary" '{new: $n, summary: $s}'
	else
		cli_jq -r --argjson w "$CLI_WIDTH" 'include "display"; .[] | watch_line($w)' <<<"$all"
		jq -r 'to_entries[] | "\(.key): \(.value.pending) pending" + (if .value.baseline then " (first run: baseline saved)" else ", \(.value.new) new" end)' <<<"$summary" >&2
	fi
	cli_alert "$all"
	[[ $(jq length <<<"$all") -gt 0 ]]
}

# cli_watch_loop REFRESH OPTS KIND...
cli_watch_loop() {
	local refresh=$1 opts=$2 delay k res rc tmp now status recent='[]' pending='{}' newall tty=false
	shift 2
	delay=$refresh
	tmp=$(mktemp -d) || exit 2
	[[ -t 1 ]] && tty=true
	# shellcheck disable=SC2064  # expand $tmp now
	trap "[[ $tty == true ]] && printf '\e[?25h'; rm -rf '$tmp'" EXIT
	trap 'exit 0' INT TERM
	[[ $tty == true ]] && printf '\e[?25l'
	while true; do
		status="" newall='[]'
		now=$(date '+%H:%M:%S')
		for k in "$@"; do
			res=$(LUTI_RAW=0 luti_watch_poll "$k" "$tmp/$k" "$opts" 2>"$tmp/err")
			rc=$?
			if [[ $rc -eq 4 ]]; then
				[[ $tty == true ]] && printf '\e[?25h'
				cli_err "login expired or rejected; run 'luti login' and start watch again"
				exit 3
			elif [[ $rc -ne 0 ]]; then
				status="error ($k): $(tail -1 "$tmp/err" | sed 's/^luti: //')"
				continue
			fi
			pending=$(jq -c --argjson p "$pending" '$p + {(.kind): .pending}' <<<"$res")
			if [[ $(jq -r .baseline <<<"$res") == true ]]; then
				recent=$(jq -c --argjson r "$recent" --arg t "$now" '$r + (.items | map(. + {at: $t, old: true}))' <<<"$res")
			else
				newall=$(jq -c --argjson a "$newall" '$a + .new' <<<"$res")
			fi
		done
		recent=$(jq -c --argjson n "$newall" --arg t "$now" '(. + ($n | map(. + {at: $t}))) | .[-15:]' <<<"$recent")
		if [[ -n $status ]]; then
			delay=$((delay * 2))
			((delay > 600)) && delay=600
		else
			delay=$refresh
		fi
		[[ $tty == true ]] && printf '\e[H\e[2J'
		printf 'luti watch  %s (%s)  last check %s  next in %ss\n' "$LUTI_INSTANCE" "$LUTI_USERNAME" "$now" "$delay"
		jq -r 'to_entries | map("\(.key): \(.value) pending") | join("   ")' <<<"$pending"
		[[ -n $status ]] && printf '%s (retrying)\n' "$status"
		printf '\n'
		if [[ $(jq length <<<"$recent") -gt 0 ]]; then
			cli_jq -r --argjson w "$CLI_WIDTH" 'include "display"; .[] | "\(.at)  \(if .old then "  " else "* " end)\(watch_line($w - 12))"' <<<"$recent"
		else
			printf '(nothing pending)\n'
		fi
		cli_alert "$newall"
		sleep "$delay"
	done
}

cli_star_help() {
	cat <<'EOF'
Usage: luti star add [--backfill N] USER...
       luti star remove USER...
       luti star list

Stars ("favorites") are users whose new posts luti queues for you; read the
queue with 'luti stargaze'. USER may be name or name@instance. A new star only
queues posts made after you star them; --backfill N also queues their N latest.
EOF
}

cmd_star() {
	local sub=${1:-} out backfill=()
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_star_help
		return 0
	fi
	case $sub in
		add)
			if [[ ${1:-} == --backfill ]]; then
				cli_need_arg "$@"
				cli_need_int --backfill "$2"
				backfill=(--backfill "$2")
				shift 2
			fi
			[[ $# -gt 0 ]] || cli_die "star add: give at least one user"
			cli_ready
			out=$(luti_stars_add "${backfill[@]+"${backfill[@]}"}" "$@")
			local rc=$?
			[[ $out == '[]' ]] || cli_ok "$out" "$(jq -r '.[] | "starred \(.user)"' <<<"${out:-[]}")"
			return $rc
			;;
		remove | rm)
			[[ $# -gt 0 ]] || cli_die "star remove: give at least one user"
			out=$(luti_stars_remove "$@")
			local rc=$?
			cli_ok "$out" "$(jq -r '.[] | "unstarred \(.)"' <<<"${out:-[]}")"
			return $rc
			;;
		list | ls)
			local stars queue
			stars=$(luti_stars_list) || exit
			if [[ $(jq length <<<"$stars") -gt 0 ]]; then
				cli_ready
				queue=$(LUTI_RAW=0 luti_stargaze_poll --peek) || exit
				stars=$(jq -c --argjson q "$queue" 'map(.user as $u | . + {unread: ([$q.items[] | select(.star == $u)] | length)})' <<<"$stars")
			fi
			cli_show "$stars" 'if length == 0 then "(no stars yet: luti star add USER)" else
				map([.user, (.unread | tostring), (.last_seen | tostring)]) | table(["USER", "UNREAD", "LAST_SEEN_POST"]) end'
			;;
		"" | -h | --help)
			cli_star_help
			[[ -n $sub ]]
			;;
		*) cli_die "star: unknown subcommand '$sub'" ;;
	esac
}

cli_stargaze_help() {
	cat <<'EOF'
Usage: luti stargaze [--peek] [--user USER] [--limit N] [--all]
       luti stargaze next [--user USER]
       luti stargaze clear

Stargaze is a reading queue of new posts from your starred users (see
'luti star --help'). Lemmy cannot follow people, so luti remembers who you
starred and which of their posts you have seen.

  luti stargaze          unread posts, oldest first, then marks them seen
    --peek               show without marking anything seen
    --user USER          only this starred user
    --limit N            at most N posts (only those are marked seen)
    --all                recent posts including seen ones, newest first
  luti stargaze next     show the oldest unread post in full and mark it seen;
                         exits 1 when the queue is empty
  luti stargaze clear    mark everything seen

Get alerted when a starred user posts: luti watch stars
EOF
}

cmd_stargaze() {
	local sub="" args=() out id star
	if [[ ${1:-} == next || ${1:-} == clear ]]; then
		sub=$1
		shift
	fi
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cli_stargaze_help
				return 0
				;;
			--peek | --all) args+=("$1") ;;
			--user | -u)
				cli_need_arg "$@"
				args+=(--user "$2")
				shift
				;;
			--limit | -n)
				cli_need_arg "$@"
				cli_need_int --limit "$2"
				args+=(--limit "$2")
				shift
				;;
			*) cli_die "stargaze: unknown argument '$1' (see luti stargaze --help)" ;;
		esac
		shift
	done
	cli_ready
	case $sub in
		clear)
			luti_stargaze_clear || exit
			cli_info "stargaze queue cleared"
			;;
		next)
			out=$(LUTI_RAW=0 luti_stargaze_poll --peek --limit 1 "${args[@]+"${args[@]}"}") || exit
			id=$(jq -r '.items[0].id // empty' <<<"$out")
			[[ -n $id ]] || {
				cli_info "(stargaze queue is empty)"
				return 1
			}
			star=$(jq -r '.items[0].star' <<<"$out")
			[[ $CLI_JSON == 1 || $CLI_NORM == 1 ]] || printf '★ %s\n' "$star"
			cli_post_view "$id" || exit
			luti_stargaze_mark "$star" "$id" || exit
			;;
		*)
			out=$(LUTI_RAW=0 luti_stargaze_poll "${args[@]+"${args[@]}"}") || exit
			cli_show "$out" 'if (.items | length) == 0 then "(nothing new from your stars)" else .items | posts_table($w) end'
			;;
	esac
}

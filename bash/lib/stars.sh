# shellcheck shell=bash
# Stargaze: a client-side queue of new posts from favorite ("starred") users.
# Lemmy has no way to follow a person, so luti keeps the list itself.
#
# Files (shared with the Python TUI):
#   ${XDG_CONFIG_HOME:-~/.config}/luti/<profile>/stars
#       one user per line as name@instance.host; blank lines and # comments allowed
#   ${XDG_STATE_HOME:-~/.local/state}/luti/<profile>/stargaze
#       name@instance.host<TAB>last_seen_post_id
# Post ids are local to the home instance and only grow, so a post is unread
# when its id is greater than last_seen. Both files are written atomically.

_luti_stars_file() { printf '%s/stars' "$(luti_config_dir)"; }
_luti_stargaze_file() { printf '%s/stargaze' "$(luti_state_dir)"; }

# _luti_stars_names: print starred users, one per line.
_luti_stars_names() {
	local f line
	f=$(_luti_stars_file)
	[[ -f $f ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		line=${line%%#*}
		line=${line//[[:space:]]/}
		[[ -n $line ]] && printf '%s\n' "$line"
	done <"$f"
	return 0
}

# _luti_stars_write: names on stdin -> stars file (comments kept on top, names sorted and unique).
_luti_stars_write() {
	local f names
	f=$(_luti_stars_file)
	names=$({ grep -v '^[[:space:]]*$' || true; } | LC_ALL=C sort -u)
	{
		[[ -f $f ]] && { grep '^[[:space:]]*#' "$f" || true; }
		[[ -n $names ]] && printf '%s\n' "$names"
		true
	} | _luti_atomic_write "$f"
}

# _luti_seen USER: print last_seen for USER (empty when unknown).
_luti_seen() {
	local f name id
	f=$(_luti_stargaze_file)
	[[ -f $f ]] || return 0
	while IFS=$'\t' read -r name id; do
		[[ $name == "$1" ]] && {
			printf '%s' "$id"
			return 0
		}
	done <"$f"
	return 0
}

# _luti_seen_set USER ID (ID empty = remove USER)
_luti_seen_set() {
	local f name id
	f=$(_luti_stargaze_file)
	{
		if [[ -f $f ]]; then
			while IFS=$'\t' read -r name id; do
				[[ -n $name && $name != "$1" ]] && printf '%s\t%s\n' "$name" "$id"
			done <"$f"
		fi
		[[ -n ${2:-} ]] && printf '%s\t%s\n' "$1" "$2"
		true
	} | LC_ALL=C sort | _luti_atomic_write "$f"
}

# luti_stars_qualify USER: print USER as name@host (checks that the user exists).
luti_stars_qualify() {
	local u=${1#@} raw actor host
	[[ -n $u ]] || {
		_luti_err "a user name is required"
		return 1
	}
	_luti_ready || return 1
	raw=$(luti_api person.get "$(jq -nc --arg n "$u" '{username: $n, limit: 1}')" 2>/dev/null) || {
		local rc=$?
		if [[ $rc == 4 ]]; then _luti_err "token rejected"; else _luti_err "unknown user '$u'"; fi
		return $rc
	}
	actor=$(jq -r '.person_view.person | (.actor_id // .ap_id) // empty' <<<"$raw")
	host=${actor#*://}
	host=${host%%/*}
	[[ -n $host ]] || {
		_luti_err "cannot work out the instance of '$u'"
		return 1
	}
	printf '%s@%s\n' "$(jq -r '.person_view.person.name' <<<"$raw")" "$host"
}

# _luti_user_posts USER [LAST_SEEN] [PAGES=5]: normalized posts by USER, newest
# first, newer than LAST_SEEN (all of the first page when LAST_SEEN is empty).
_luti_user_posts() {
	local user=$1 seen=${2:-} pages=${3:-5} all='[]' raw items next="" i
	for ((i = 0; i < pages; i++)); do
		if [[ $LUTI_API == v4 ]]; then
			raw=$(LUTI_RAW=0 luti_post_list "$(jq -nc --arg u "$user" --arg n "$next" \
				'{creator: $u, sort: "new", type: "all", limit: 20} + (if $n != "" then {next: $n} else {} end)')") || return
			items=$(jq -c '.items' <<<"$raw")
			next=$(jq -r '.next // empty' <<<"$raw")
		else
			raw=$(luti_api person.get "$(jq -nc --arg u "$user" --argjson p "$((i + 1))" \
				'{username: $u, sort: "New", limit: 20, page: $p}')") || return
			items=$(_luti_jq -c 'include "luti"; [.posts[]? | post_v3]' <<<"$raw")
			next=""
			[[ $(jq length <<<"$items") -gt 0 ]] && next=$((i + 2))
		fi
		all=$(jq -c --slurpfile a <(printf '%s' "$all") --argjson s "${seen:-0}" '$a[0] + map(select(.id > $s))' <<<"$items")
		[[ -z $seen || -z $next ]] && break
		# Stop once this page reached last_seen.
		jq -e --argjson s "$seen" 'length == 0 or (map(.id) | min) <= $s' <<<"$items" >/dev/null && break
	done
	jq -c 'unique_by(.id) | sort_by(.id) | reverse' <<<"$all"
}

# luti_stars_list: [{user, last_seen}] for the profile's starred users.
luti_stars_list() {
	local u
	{
		while IFS= read -r u; do
			jq -nc --arg u "$u" --arg s "$(_luti_seen "$u")" '{user: $u, last_seen: (if $s == "" then null else ($s | tonumber) end)}'
		done < <(_luti_stars_names | LC_ALL=C sort -u)
		true
	} | jq -sc .
}

# luti_stars_add [--backfill N] USER...: star users; print [{user, last_seen}].
# A new star starts at the user's newest post, so only later posts are
# unread; --backfill N leaves their N newest posts unread.
luti_stars_add() {
	local backfill="" u q posts seen out='[]' rc=0
	if [[ ${1:-} == --backfill ]]; then
		_luti_need_id "--backfill" "${2:-}" || return 1
		backfill=$2
		shift 2
	fi
	[[ $# -gt 0 ]] || {
		_luti_err "stars add: give at least one user"
		return 1
	}
	_luti_ready || return 1
	for u in "$@"; do
		q=$(luti_stars_qualify "$u") || {
			rc=1
			continue
		}
		seen=$(_luti_seen "$q")
		if [[ -z $seen || -n $backfill ]]; then
			posts=$(_luti_user_posts "$q" "" 1) || {
				rc=1
				continue
			}
			seen=$(jq -r --argjson n "${backfill:-0}" '.[$n].id // 0' <<<"$posts")
			_luti_seen_set "$q" "$seen" || return 1
		fi
		{ _luti_stars_names; printf '%s\n' "$q"; } | _luti_stars_write || return 1
		out=$(jq -c --arg u "$q" --argjson s "$seen" '. + [{user: $u, last_seen: $s}]' <<<"$out")
	done
	printf '%s\n' "$out"
	return $rc
}

# _luti_star_match USER: print the starred name matching USER (name@host, or a unique bare name).
_luti_star_match() {
	local u=${1#@} m
	if [[ $u == *@* ]]; then
		_luti_stars_names | { grep -Fxi -- "$u" || true; } | head -1
	else
		m=$(_luti_stars_names | { grep -i -- "^${u//./\\.}@" || true; })
		[[ $(grep -c . <<<"$m") -le 1 ]] && printf '%s\n' "$m"
	fi
	return 0
}

# luti_stars_remove USER...: unstar users; print the removed names as a JSON array.
luti_stars_remove() {
	local u m removed=() rc=0
	for u in "$@"; do
		m=$(_luti_star_match "$u")
		if [[ -z $m ]]; then
			_luti_err "'$u' is not starred (or matches more than one star)"
			rc=1
			continue
		fi
		_luti_stars_names | { grep -vFx -- "$m" || true; } | _luti_stars_write || return 1
		_luti_seen_set "$m" "" || return 1
		removed+=("$m")
	done
	printf '%s\n' "${removed[@]+"${removed[@]}"}" | jq -Rsc 'split("\n") | map(select(. != ""))'
	return $rc
}

# luti_stargaze_mark USER POST_ID: mark USER's posts up to POST_ID as seen.
luti_stargaze_mark() {
	local m cur
	m=$(_luti_star_match "${1:-}")
	[[ -n $m ]] || m=${1:-}
	_luti_need_id "post" "${2:-}" || return 1
	cur=$(_luti_seen "$m")
	if [[ -z $cur || $2 -gt $cur ]]; then
		_luti_seen_set "$m" "$2"
	fi
}

# luti_stargaze_poll [--peek] [--all] [--user USER] [--limit N]: print
# {items: [post + {star: "name@host"}]}. Unread posts come oldest first and are
# marked seen unless --peek. --all lists recent posts including seen ones,
# newest first, and marks nothing. Unknown users only give a warning.
# shellcheck disable=SC2120  # options are optional
luti_stargaze_poll() {
	local peek=false all=false only="" limit="" u users=() seen posts out='[]'
	while [[ $# -gt 0 ]]; do
		case $1 in
			--peek) peek=true ;;
			--all) all=true ;;
			--user)
				only=${2:-}
				shift
				;;
			--limit)
				_luti_need_id "--limit" "${2:-}" || return 1
				limit=$2
				shift
				;;
			*)
				_luti_err "luti_stargaze_poll: unknown option '$1'"
				return 2
				;;
		esac
		shift
	done
	_luti_ready || return 1
	if [[ -n $only ]]; then
		u=$(_luti_star_match "$only")
		[[ -n $u ]] || {
			_luti_err "'$only' is not starred"
			return 1
		}
		users=("$u")
	else
		mapfile -t users < <(_luti_stars_names)
	fi
	for u in "${users[@]+"${users[@]}"}"; do
		seen=$(_luti_seen "$u")
		if [[ $all != true && -z $seen ]]; then
			# Starred but no saved state (e.g. starred by hand or by luti-tui):
			# treat as a new star, as the Python library does. Their newest post
			# becomes the baseline and nothing is unread yet.
			posts=$(_luti_user_posts "$u" "" 1 2>/dev/null) || {
				_luti_err "warning: cannot fetch posts of $u (unknown or deleted user?)"
				continue
			}
			if [[ $peek == false ]]; then
				luti_stargaze_mark "$u" "$(jq -r '(map(.id) | max) // 0' <<<"$posts")" || return 1
			fi
			continue
		fi
		if [[ $all == true ]]; then
			posts=$(_luti_user_posts "$u" "" 1 2>/dev/null)
		else
			posts=$(_luti_user_posts "$u" "${seen:-0}" 2>/dev/null)
		fi || {
			_luti_err "warning: cannot fetch posts of $u (unknown or deleted user?)"
			continue
		}
		out=$(jq -c --slurpfile a <(printf '%s' "$out") --arg u "$u" '$a[0] + map(. + {star: $u})' <<<"$posts")
	done
	if [[ $all == true ]]; then
		out=$(jq -c --arg l "$limit" 'sort_by(.id) | reverse | if $l != "" then .[0:($l | tonumber)] else . end' <<<"$out")
	else
		out=$(jq -c --arg l "$limit" 'sort_by(.id) | if $l != "" then .[0:($l | tonumber)] else . end' <<<"$out")
		if [[ $peek == false ]]; then
			while IFS=$'\t' read -r u seen; do
				[[ -n $u ]] && { luti_stargaze_mark "$u" "$seen" || return 1; }
			done < <(jq -r 'group_by(.star)[] | [.[0].star, (map(.id) | max)] | @tsv' <<<"$out")
		fi
	fi
	jq -c '{items: .}' <<<"$out"
}

# luti_stargaze_clear: mark everything in the queue as seen.
luti_stargaze_clear() { # [--user USER]
	luti_stargaze_poll "$@" >/dev/null
}

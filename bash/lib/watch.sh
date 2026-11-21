# shellcheck shell=bash
# New-item detection for `watch`: no display, no sound.
#
# A watch item is a normalized object (report, registration, notification or
# post) plus "watch": KIND and "key": a stable id such as "post:12" or
# "reply:3". The state file holds the keys that were pending at the last poll,
# one per line. Items are new when their key is not in the state file, so a
# report that arrives while another is resolved is still detected.

# _luti_watch_items KIND [OPTS]: print the current pending watch items as a JSON array.
# KIND: reports | registrations | inbox | stars. OPTS: community (reports only).
_luti_watch_items() {
	local kind=$1 opts=${2:-} out
	[[ -n $opts ]] || opts='{}'
	case $kind in
		reports)
			out=$(LUTI_RAW=0 luti_report_list "$(jq -c '{type: "all", limit: 50} + {community: .community}' <<<"$opts")") || return
			jq -c '[.items[] | . + {watch: "reports", key: "\(.type):\(.id)"}]' <<<"$out"
			;;
		registrations)
			out=$(LUTI_RAW=0 luti_registration_list '{"limit": 50}') || return
			jq -c '[.items[] | . + {watch: "registrations", key: "registration:\(.id)"}]' <<<"$out"
			;;
		inbox)
			out=$(LUTI_RAW=0 luti_inbox '{"unread": true, "limit": 50}') || return
			jq -c '[.items[] | . + {watch: "inbox", key: "\(.kind):\(.id)"}]' <<<"$out"
			;;
		stars)
			out=$(LUTI_RAW=0 luti_stargaze_poll --peek) || return
			jq -c '[.items[] | . + {watch: "stars", key: "post:\(.id)"}]' <<<"$out"
			;;
		*)
			_luti_err "unknown watch kind '$kind' (reports, registrations, inbox, stars)"
			return 2
			;;
	esac
}

# luti_watch_diff STATEFILE: read current items (JSON array) on stdin, print
# {baseline, new, pending, items} and rewrite STATEFILE with the current keys.
# baseline is true when there was no state file yet (nothing counts as new).
luti_watch_diff() {
	local state=$1 cur old='[]' baseline=false
	cur=$(jq -c 'reduce .[] as $i ([]; if any(.[]; .key == $i.key) then . else . + [$i] end)') || return 1
	if [[ -f $state ]]; then
		old=$(jq -Rsc 'split("\n") | map(select(. != ""))' <"$state")
	else
		baseline=true
	fi
	jq -r '.[].key' <<<"$cur" | _luti_atomic_write "$state" || return 1
	jq -c --argjson old "$old" --argjson b "$baseline" '
		{baseline: $b, new: (if $b then [] else map(select(.key as $k | $old | index($k) | not)) end),
		 pending: length, items: .}' <<<"$cur"
}

# luti_watch_poll KIND STATEFILE [OPTS]: poll once and print
# {kind, baseline, new: [items], pending, items}. Updates STATEFILE.
# Returns the luti_api code on failure (4 = token rejected).
luti_watch_poll() {
	local kind=${1:-} state=${2:-} items
	[[ -n $state ]] || {
		_luti_err "luti_watch_poll: a state file is required"
		return 2
	}
	_luti_need_token || return 4
	_luti_ready || return 1
	items=$(_luti_watch_items "$kind" "${3:-}") || return
	luti_watch_diff "$state" <<<"$items" | jq -c --arg k "$kind" '{kind: $k} + .'
}

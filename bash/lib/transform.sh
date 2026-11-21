# shellcheck shell=bash
# Value transforms between luti's canonical CLI values and each API version.
# See the "transforms" section of spec/endpoints.json.

# lt_snake WORD: PascalCase or snake_case -> snake_case.
lt_snake() {
	local s=$1 out="" c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		if [[ $c == [A-Z] ]]; then
			[[ $i -gt 0 && ${s:i-1:1} != _ ]] && out+="_"
			out+=${c,}
		else
			out+=$c
		fi
	done
	printf '%s' "$out"
}

# lt_pascal WORD: snake_case -> PascalCase (most_comments -> MostComments).
lt_pascal() {
	local s part out=""
	s=$(lt_snake "$1")
	local IFS=_
	for part in $s; do
		out+=${part^}
	done
	printf '%s' "$out"
}

# lt_enum VALUE: an enum value in the current version's case.
lt_enum() {
	local s
	s=$(lt_snake "$1")
	if [[ $LT_VER == v3 ]]; then
		lt_pascal "$s"
	else
		printf '%s' "$s"
	fi
}

# lt_sort_json SORT [TIME]: JSON fields for a post sort, e.g.
#   top day -> v3 {"sort":"TopDay"}   v4 {"sort":"top","time_range_seconds":86400}
# Also accepts legacy names such as top_day / TopDay.
lt_sort_json() {
	local sort time
	sort=$(lt_snake "${1:-}")
	time=$(lt_snake "${2:-}")
	if [[ $sort == top_* ]]; then
		[[ -z $time ]] && time=${sort#top_}
		sort=top
	fi
	[[ -z $sort && -z $time ]] && {
		printf '{}'
		return 0
	}
	if [[ -n $time ]] && ! jq -e --arg t "$time" '.transforms.top_time.ranges | has($t)' "$(lt_spec_file)" >/dev/null; then
		lt_err "unknown --time '$2' (use: $(jq -r '.transforms.top_time.ranges | keys_unsorted | join(", ")' "$(lt_spec_file)"))"
		return 1
	fi
	jq -c -n --arg v "$LT_VER" --arg s "$sort" --arg t "$time" --arg ps "$(lt_pascal "$sort")" \
		--slurpfile spec "$(lt_spec_file)" '
		$spec[0].transforms.top_time.ranges as $r
		| if $v == "v3" then
			if $s == "top" then {sort: $r[if $t == "" then "all" else $t end].v3}
			elif $s == "" then {sort: $r[$t].v3}
			else {sort: $ps} end
		  else
			(if $s == "" then {} else {sort: $s} end)
			+ (if $t != "" and $r[$t].seconds != null then {time_range_seconds: $r[$t].seconds} else {} end)
		  end'
}

# lt_vote_json DIRECTION: {"score":1} on v3, {"is_upvote":true} on v4, etc.
lt_vote_json() {
	case $1 in
		up | down | clear) ;;
		*)
			lt_err "vote must be up, down or clear (got '$1')"
			return 1
			;;
	esac
	jq -c --arg v "$LT_VER" --arg d "$1" '.transforms.vote[$v] | {(.field): .[$d]}' "$(lt_spec_file)"
}

# lt_page_json PAGE CURSOR: pagination fields for this version.
lt_page_json() {
	local page=$1 cursor=$2
	if [[ $LT_VER == v3 ]]; then
		[[ -n $cursor ]] && {
			lt_err "--cursor is for API v4 servers; use --page N on v3"
			return 1
		}
		if [[ -n $page ]]; then
			lt_need_int --page "$page"
			jq -cn --argjson p "$page" '{page: $p}'
		else
			printf '{}'
		fi
	else
		[[ -n $page ]] && {
			lt_err "--page is for API v3 servers; use --cursor X on v4"
			return 1
		}
		if [[ -n $cursor ]]; then
			jq -cn --arg c "$cursor" '{page_cursor: $c}'
		else
			printf '{}'
		fi
	fi
}

# lt_next_page RAW PAGE COUNT: print the flag that fetches the next page, or nothing.
lt_next_page() {
	local raw=$1 page=${2:-1} count=$3 next
	if [[ $LT_VER == v3 ]]; then
		[[ $count -gt 0 ]] && printf -- '--page %d' "$((page + 1))"
	else
		next=$(jq -r '.next_page // empty' <<<"$raw")
		# v4 search returns a composite cursor that is all "none" on the last page.
		[[ $next =~ ^(none,)*none$ ]] && next=""
		[[ -n $next ]] && printf -- '--cursor %s' "$next"
	fi
	return 0
}

# lt_print_next RAW PAGE COUNT: show the next-page hint on stderr (table mode only).
lt_print_next() {
	local n
	n=$(lt_next_page "$@")
	[[ -n $n && $LT_JSON != 1 && $LT_NORM != 1 ]] && lt_info "next: $n"
	return 0
}

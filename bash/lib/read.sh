# shellcheck shell=bash
# Reading: feed, search, community, user. Also shared id lookups.

# lt_community_id NAME_OR_ID: print a community id.
lt_community_id() {
	local c=$1 raw
	if [[ $c =~ ^[0-9]+$ ]]; then
		printf '%s' "$c"
		return 0
	fi
	c=${c#!}
	raw=$(lt_api community.get "$(jq -n --arg n "$c" '{name: $n}')") || return 1
	jq -r '.community_view.community.id' <<<"$raw"
}

# lt_person_id NAME_OR_ID: print a person id.
lt_person_id() {
	local p=$1 raw
	if [[ $p =~ ^[0-9]+$ ]]; then
		printf '%s' "$p"
		return 0
	fi
	p=${p#@}
	raw=$(lt_api person.get "$(jq -n --arg n "$p" '{username: $n}')") || return 1
	jq -r '.person_view.person.id' <<<"$raw"
}

lt_feed_help() {
	cat <<'EOF'
Usage: luti feed [OPTIONS]

  --sort S          hot, active, new, old, top, most_comments, new_comments,
                    controversial, scaled
  --time T          with --sort top: hour, six_hour, twelve_hour, day, week, month,
                    three_months, six_months, nine_months, year, all
  --type T          all, local, subscribed, moderator_view
  --community C     community name or id
  --limit N         posts per page (default 20)
  --page N          page number (API v3 servers)
  --cursor X        page cursor (API v4 servers)
  --saved           only saved posts
EOF
}

cmd_feed() {
	local sort="" time="" type="" community="" limit=20 page="" cursor="" saved=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				lt_feed_help
				return 0
				;;
			--sort | -s)
				lt_need_arg "$@"
				sort=$2
				shift
				;;
			--time | -t)
				lt_need_arg "$@"
				time=$2
				shift
				;;
			--type)
				lt_need_arg "$@"
				type=$2
				shift
				;;
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
			--cursor)
				lt_need_arg "$@"
				cursor=$2
				shift
				;;
			--saved) saved=true ;;
			*) lt_die "feed: unknown option '$1' (see luti feed --help)" ;;
		esac
		shift
	done
	lt_require_version
	lt_load_token
	local req sortj pagej
	sortj=$(lt_sort_json "$sort" "$time") || return 1
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	req=$(jq -cn --argjson s "$sortj" --argjson p "$pagej" --argjson l "$limit" \
		--arg t "${type:+$(lt_enum "$type")}" --arg c "$community" --arg saved "$saved" '
		{limit: $l} + $s + $p
		+ (if $t != "" then {type_: $t} else {} end)
		+ (if $c == "" then {} elif ($c | test("^[0-9]+$")) then {community_id: ($c | tonumber)}
		   else {community_name: ($c | ltrimstr("!"))} end)
		+ (if $saved != "" then {saved_only: true} else {} end)')
	local raw items norm
	raw=$(lt_api post.list "$req") || return 1
	items=$(lt_items post.list "$raw")
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; map(post($v))' <<<"$items")
	lt_output "$raw" "$norm" lt_show_posts
	lt_print_next "$raw" "${page:-1}" "$(jq length <<<"$items")"
}

cmd_search() {
	local q="" type="" community="" limit=10 page="" cursor="" sort=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti search QUERY [--type all|posts|comments|communities|users]
                         [--community C] [--sort S] [--limit N] [--page N|--cursor X]
EOF
				return 0
				;;
			--type)
				lt_need_arg "$@"
				type=$2
				shift
				;;
			--community | -c)
				lt_need_arg "$@"
				community=$2
				shift
				;;
			--sort)
				lt_need_arg "$@"
				sort=$2
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
			-*) lt_die "search: unknown option '$1'" ;;
			*) q+="${q:+ }$1" ;;
		esac
		shift
	done
	[[ -n $q ]] || lt_die "search: a query is required"
	lt_require_version
	lt_load_token
	local req pagej cid="" raw norm
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	[[ -n $community ]] && { cid=$(lt_community_id "$community") || return 1; }
	req=$(jq -cn --arg q "$q" --argjson l "$limit" --argjson p "$pagej" --arg t "${type:+$(lt_enum "$type")}" \
		--arg c "$cid" --arg s "${sort:+$(lt_enum "$sort")}" '
		{search_term: $q, limit: $l} + $p
		+ (if $t != "" then {type_: $t} else {} end)
		+ (if $c != "" then {community_id: ($c | tonumber)} else {} end)
		+ (if $s != "" then {sort: $s} else {} end)')
	raw=$(lt_api search "$req") || return 1
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; search($v)' <<<"$raw")
	lt_output "$raw" "$norm" lt_show_search
	lt_print_next "$raw" "${page:-1}" "$(jq '[.[] | length] | add' <<<"$norm")"
}

cmd_community() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	case $sub in
		list) lt_community_list "$@" ;;
		show) lt_community_show "$@" ;;
		follow) lt_community_follow "$@" ;;
		block) lt_community_block "$@" ;;
		"" | -h | --help)
			cat <<'EOF'
Usage: luti community list [--type all|local|subscribed] [--sort S] [--limit N] [--page N|--cursor X]
       luti community show NAME|ID
       luti community follow NAME|ID [--undo]
       luti community block NAME|ID [--undo]
EOF
			[[ -n $sub ]]
			;;
		*) lt_die "community: unknown subcommand '$sub'" ;;
	esac
}

lt_community_list() {
	local type="" sort="" limit=20 page="" cursor=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_community --help
				return 0
				;;
			--type)
				lt_need_arg "$@"
				type=$2
				shift
				;;
			--sort)
				lt_need_arg "$@"
				sort=$2
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
			*) lt_die "community list: unknown option '$1'" ;;
		esac
		shift
	done
	lt_require_version
	lt_load_token
	local pagej sortj req raw items norm
	pagej=$(lt_page_json "$page" "$cursor") || return 1
	sortj=$(lt_sort_json "$sort" "") || return 1
	req=$(jq -cn --argjson l "$limit" --argjson p "$pagej" --argjson s "$sortj" --arg t "${type:+$(lt_enum "$type")}" '
		{limit: $l} + $p + $s + (if $t != "" then {type_: $t} else {} end)')
	raw=$(lt_api community.list "$req") || return 1
	items=$(lt_items community.list "$raw")
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; map(community($v))' <<<"$items")
	lt_output "$raw" "$norm" lt_show_communities
	lt_print_next "$raw" "${page:-1}" "$(jq length <<<"$items")"
}

lt_community_show() {
	lt_help_requested "$@" && {
		cmd_community --help
		return 0
	}
	[[ $# -eq 1 ]] || lt_die "community show: give one community name or id"
	lt_require_version
	lt_load_token
	local req raw norm
	if [[ $1 =~ ^[0-9]+$ ]]; then
		req=$(jq -cn --argjson id "$1" '{id: $id}')
	else
		req=$(jq -cn --arg n "${1#!}" '{name: $n}')
	fi
	raw=$(lt_api community.get "$req") || return 1
	norm=$(lt_jq -c --arg v "$LT_VER" 'include "luti"; .community_view | community($v)
		' <<<"$raw")
	lt_output "$raw" "$norm" lt_show_community
	if [[ $LT_JSON != 1 && $LT_NORM != 1 ]]; then
		jq -r '"moderators: " + ([.moderators[]?.moderator.name] | join(", "))' <<<"$raw"
	fi
}

# _lt_community_toggle OP FIELD VERB ARGS...
_lt_community_toggle() {
	local op=$1 field=$2 verb=$3 target="" undo=false
	shift 3
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_community --help
				return 0
				;;
			--undo) undo=true ;;
			-*) lt_die "community $verb: unknown option '$1'" ;;
			*) target=$1 ;;
		esac
		shift
	done
	[[ -n $target ]] || lt_die "community $verb: give a community name or id"
	lt_require_login
	local cid raw req
	cid=$(lt_community_id "$target") || return 1
	req=$(jq -cn --argjson c "$cid" --arg f "$field" --argjson on "$([[ $undo == true ]] && echo false || echo true)" \
		'{community_id: $c} + {($f): $on}')
	raw=$(lt_api "$op" "$req") || return 1
	if [[ $LT_JSON == 1 ]]; then printf '%s\n' "$raw"; else
		lt_show_ok "community $cid: $verb $([[ $undo == true ]] && echo "undone" || echo "done")"
	fi
}

lt_community_follow() { _lt_community_toggle community.follow follow follow "$@"; }
lt_community_block() { _lt_community_toggle community.block block block "$@"; }

cmd_user() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	case $sub in
		show) ;;
		"" | -h | --help)
			echo "Usage: luti user show NAME|ID [--limit N]"
			echo "Shows a user's profile and recent posts and comments."
			[[ -n $sub ]]
			return
			;;
		*) lt_die "user: unknown subcommand '$sub'" ;;
	esac
	local target="" limit=10
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cmd_user --help
				return 0
				;;
			--limit | -n)
				lt_need_arg "$@"
				lt_need_int --limit "$2"
				limit=$2
				shift
				;;
			-*) lt_die "user show: unknown option '$1'" ;;
			*) target=${1#@} ;;
		esac
		shift
	done
	[[ -n $target ]] || lt_die "user show: give a user name or id"
	lt_require_version
	lt_load_token
	local req raw content items norm
	if [[ $target =~ ^[0-9]+$ ]]; then
		req=$(jq -cn --argjson id "$target" --argjson l "$limit" '{person_id: $id, limit: $l}')
	else
		req=$(jq -cn --arg n "$target" --argjson l "$limit" '{username: $n, limit: $l}')
	fi
	raw=$(lt_api person.get "$req") || return 1
	if [[ $LT_VER == v3 ]]; then
		content=$raw
	else
		local pid
		pid=$(jq -r '.person_view.person.id' <<<"$raw")
		content=$(lt_api person.content "$(jq -cn --argjson id "$pid" --argjson l "$limit" '{person_id: $id, limit: $l}')") || return 1
	fi
	items=$(lt_items person.content "$content")
	norm=$(lt_jq -c --arg v "$LT_VER" --argjson items "$items" 'include "luti";
		{person: (.person_view | person($v)),
		 posts: [$items[] | select(has("comment") | not) | post($v)],
		 comments: [$items[] | select(has("comment")) | comment($v)]}' <<<"$raw")
	# shellcheck disable=SC2329  # called through lt_output
	_lt_show_user() {
		local j
		j=$(cat)
		jq -c '.person' <<<"$j" | lt_show_person
		printf '\nRecent posts:\n'
		jq -c '.posts' <<<"$j" | lt_show_posts | sed 's/^/  /'
		printf '\nRecent comments:\n'
		jq -c '.comments' <<<"$j" | lt_show_comment_list | sed 's/^/  /'
	}
	if [[ $LT_JSON == 1 ]]; then
		jq -c --argjson c "$content" '. + {content: $c}' <<<"$raw"
	else
		lt_output "$raw" "$norm" _lt_show_user
	fi
}

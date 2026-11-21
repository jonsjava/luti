# shellcheck shell=bash
# shellcheck disable=SC2034  # LUTI_* settings are read by bash/lib
# login, logout, whoami, feed, search, community, user, open

cmd_login() {
	local instance="" username="" mfa="" pw totp jwt rc
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti [--profile NAME] login [--instance URL] [--username NAME] [--mfa|--no-mfa]

Logs in and saves the token in the profile. Asks for anything not given,
reading the password without echo (and a TOTP code when MFA is on or the
server asks for one). The password is never stored. Password and TOTP code
may also be piped on stdin, one per line.
EOF
				return 0
				;;
			-i | --instance)
				cli_need_arg "$@"
				instance=$2
				shift
				;;
			-u | --username)
				cli_need_arg "$@"
				username=$2
				shift
				;;
			-m | --mfa) mfa=true ;;
			--no-mfa) mfa=false ;;
			*) cli_die "login: unknown option '$1'" ;;
		esac
		shift
	done
	local old_instance=$LUTI_INSTANCE
	[[ -n $instance ]] || instance=$LUTI_INSTANCE
	[[ -n $username ]] || username=$LUTI_USERNAME
	[[ -n $mfa ]] || mfa=$LUTI_MFA
	[[ -n $instance ]] || cli_prompt instance "Instance (e.g. https://lemmy.world): "
	[[ -n $instance ]] || cli_die "login: an instance is required"
	[[ -n $username ]] || cli_prompt username "Username or email: "
	[[ -n $username ]] || cli_die "login: a username is required"
	instance=$(luti_normalize_instance "$instance")
	if [[ $instance != "$old_instance" && -z $CLI_FORCED_API ]]; then
		LUTI_API=""
		LUTI_CONFIG_API=""
	fi
	LUTI_INSTANCE=$instance
	cli_ready

	cli_prompt_secret pw "Password for $username: "
	[[ -n $pw ]] || cli_die "login: empty password"
	totp=""
	[[ $mfa == true ]] && cli_prompt totp "TOTP code: "
	jwt=$(luti_login "$username" "$pw" "$totp")
	rc=$?
	if [[ $rc -eq 3 && -z $totp ]]; then
		cli_prompt totp "TOTP code: "
		jwt=$(luti_login "$username" "$pw" "$totp") || exit 1
		mfa=true
	elif [[ $rc -ne 0 ]]; then
		exit 1
	fi
	pw=""
	LUTI_TOKEN=$jwt
	LUTI_USERNAME=$username
	LUTI_MFA=$mfa
	[[ -n $CLI_FORCED_API ]] && LUTI_CONFIG_API=$CLI_FORCED_API
	luti_config_save || exit 1
	luti_token_save "$jwt" || exit 1
	luti_config_cache_api
	cli_info "Logged in to $instance as $username (API $LUTI_API, profile $LUTI_PROFILE)."
}

cmd_logout() {
	if cli_help_requested "$@"; then
		echo "Usage: luti [--profile NAME] logout"
		echo "Invalidates the token on the server (if reachable) and deletes it locally."
		return 0
	fi
	if [[ -n $LUTI_TOKEN && -n $LUTI_INSTANCE ]]; then
		cli_ready
		luti_logout 2>/dev/null || cli_err "warning: server logout failed; deleting the local token anyway"
	fi
	luti_token_delete
	cli_info "Logged out (profile $LUTI_PROFILE)."
}

cmd_whoami() {
	if cli_help_requested "$@"; then
		echo "Usage: luti whoami [--json|--norm]"
		echo "Shows the account the profile is logged in as."
		return 0
	fi
	cli_login_required
	local out
	out=$(luti_whoami) || exit
	[[ $CLI_JSON == 1 ]] || out=$(jq -c --arg i "$LUTI_INSTANCE" --arg v "$LUTI_API" --arg p "$LUTI_PROFILE" \
		'. + {instance: $i, api: $v, profile: $p}' <<<"$out")
	cli_show "$out" '"\(.name) (id \(.id))" + (if .admin then " [admin]" else "" end),
		"instance: \(.instance)  api: \(.api)  profile: \(.profile)",
		(if (.moderates | length) > 0 then "moderates: " + (.moderates | join(", ")) else empty end)'
}

cmd_feed() {
	local sort="" time="" type="" community="" limit=20 page="" cursor="" saved=""
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
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

Posts with an image or video are tagged [image] / [video]; open them with
'luti open post ID --media'. The next page is printed as "next: --page N" or
"next: --cursor X".
EOF
				return 0
				;;
			--sort | -s)
				cli_need_arg "$@"
				sort=$2
				shift
				;;
			--time | -t)
				cli_need_arg "$@"
				time=$2
				shift
				;;
			--type)
				cli_need_arg "$@"
				type=$2
				shift
				;;
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
			--cursor)
				cli_need_arg "$@"
				cursor=$2
				shift
				;;
			--saved) saved=true ;;
			*) cli_die "feed: unknown option '$1' (see luti feed --help)" ;;
		esac
		shift
	done
	cli_ready
	local opts out
	opts=$(jq -nc --arg s "$sort" --arg t "$time" --arg ty "$type" --arg c "$community" --argjson l "$limit" \
		--arg sv "$saved" --argjson p "$(cli_page_opts "$page" "$cursor")" '
		{limit: $l} + $p + (if $s != "" then {sort: $s} else {} end) + (if $t != "" then {time: $t} else {} end)
		+ (if $ty != "" then {type: $ty} else {} end) + (if $c != "" then {community: $c} else {} end)
		+ (if $sv != "" then {saved: true} else {} end)')
	out=$(luti_post_list "$opts") || exit
	cli_show_list "$out" 'posts_table($w)'
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
				cli_need_arg "$@"
				type=$2
				shift
				;;
			--community | -c)
				cli_need_arg "$@"
				community=$2
				shift
				;;
			--sort)
				cli_need_arg "$@"
				sort=$2
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
			-*) cli_die "search: unknown option '$1'" ;;
			*) q+="${q:+ }$1" ;;
		esac
		shift
	done
	[[ -n $q ]] || cli_die "search: a query is required"
	cli_ready
	local opts out
	opts=$(jq -nc --arg t "$type" --arg c "$community" --arg s "$sort" --argjson l "$limit" \
		--argjson p "$(cli_page_opts "$page" "$cursor")" '{limit: $l} + $p
		+ (if $t != "" then {type: $t} else {} end) + (if $c != "" then {community: $c} else {} end)
		+ (if $s != "" then {sort: $s} else {} end)')
	out=$(luti_search "$q" "$opts") || exit
	cli_show "$out" '"Posts:", (.posts | posts_table($w) | indent), "", "Comments:", (.comments | comments_table($w) | indent),
		"", "Communities:", (.communities | communities_table | indent), "", "Users:", (.users | users_table | indent)'
	[[ $CLI_JSON == 1 || $CLI_NORM == 1 ]] || {
		local next
		next=$(jq -r 'if .next == null then empty elif (.next | type) == "number" then "--page \(.next)" else "--cursor \(.next)" end' <<<"$out")
		[[ -z $next ]] || cli_info "next: $next"
	}
}

cli_community_help() {
	cat <<'EOF'
Usage: luti community list [--type all|local|subscribed] [--sort S] [--limit N] [--page N|--cursor X]
       luti community show NAME|ID
       luti community follow NAME|ID [--undo]
       luti community block NAME|ID [--undo]
EOF
}

cmd_community() {
	local sub=${1:-}
	[[ $# -gt 0 ]] && shift
	if cli_help_requested "$@"; then
		cli_community_help
		return 0
	fi
	case $sub in
		list)
			local type="" sort="" limit=20 page="" cursor="" opts out
			while [[ $# -gt 0 ]]; do
				case $1 in
					--type)
						cli_need_arg "$@"
						type=$2
						shift
						;;
					--sort)
						cli_need_arg "$@"
						sort=$2
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
					*) cli_die "community list: unknown option '$1'" ;;
				esac
				shift
			done
			cli_ready
			opts=$(jq -nc --arg t "$type" --arg s "$sort" --argjson l "$limit" --argjson p "$(cli_page_opts "$page" "$cursor")" \
				'{limit: $l} + $p + (if $t != "" then {type: $t} else {} end) + (if $s != "" then {sort: $s} else {} end)')
			out=$(luti_community_list "$opts") || exit
			cli_show_list "$out" 'communities_table'
			;;
		show)
			[[ $# -eq 1 ]] || cli_die "community show: give one community name or id"
			cli_ready
			local out
			out=$(luti_community_get "$1") || exit
			cli_show "$out" 'community_full'
			;;
		follow | block)
			local target="" on=true out
			while [[ $# -gt 0 ]]; do
				case $1 in
					--undo) on=false ;;
					-*) cli_die "community $sub: unknown option '$1'" ;;
					*) target=$1 ;;
				esac
				shift
			done
			[[ -n $target ]] || cli_die "community $sub: give a community name or id"
			cli_login_required
			out=$("luti_community_$sub" "$target" "$on") || exit
			cli_ok "$out" "community $target: $sub $([[ $on == true ]] && echo "done" || echo "undone")"
			;;
		"" | -h | --help)
			cli_community_help
			[[ -n $sub ]]
			;;
		*) cli_die "community: unknown subcommand '$sub'" ;;
	esac
}

cmd_user() {
	local sub=${1:-} target="" limit=10 out
	[[ $# -gt 0 ]] && shift
	if [[ $sub != show ]] || cli_help_requested "$@"; then
		echo "Usage: luti user show NAME|ID [--limit N]"
		echo "Shows a user's profile and recent posts and comments. NAME may be name@instance."
		[[ $sub == show || $sub == -h || $sub == --help ]]
		return
	fi
	while [[ $# -gt 0 ]]; do
		case $1 in
			--limit | -n)
				cli_need_arg "$@"
				cli_need_int --limit "$2"
				limit=$2
				shift
				;;
			-*) cli_die "user show: unknown option '$1'" ;;
			*) target=$1 ;;
		esac
		shift
	done
	[[ -n $target ]] || cli_die "user show: give a user name or id"
	cli_ready
	out=$(luti_person_get "$target" "{\"limit\":$limit}") || exit
	cli_show "$out" '(.person | person_full), "", "Recent posts:", (.posts | posts_table($w) | indent),
		"", "Recent comments:", (.comments | comments_table($w) | indent)'
}

cli_open_help() {
	cat <<'EOF'
Usage: luti open post ID [--link | --media | --origin] [--print]
       luti open comment ID [--origin] [--print]

Opens a page in the default browser:
  (default)   the post or comment on your own instance (<instance>/post/ID),
              where you can vote and reply
  --link      the article the post links to
  --media     the post's image or video (else its embedded video or thumbnail)
  --origin    the original copy on the instance it was posted to
  --print     print the URL instead of opening it

The browser is $BROWSER, else xdg-open, open (macOS), wslview or cmd.exe.
Only http:// and https:// URLs are opened.
EOF
}

cmd_open() {
	local kind=${1:-} id="" what=page print=false url
	[[ $# -gt 0 ]] && shift
	if [[ $kind != post && $kind != comment ]] || cli_help_requested "$@"; then
		cli_open_help
		[[ $kind == post || $kind == comment || $kind == -h || $kind == --help ]]
		return
	fi
	while [[ $# -gt 0 ]]; do
		case $1 in
			--link) what="link" ;;
			--media) what=media ;;
			--origin) what=origin ;;
			--print | -p) print=true ;;
			-*) cli_die "open: unknown option '$1'" ;;
			*) id=$1 ;;
		esac
		shift
	done
	[[ -n $id ]] || cli_die "open $kind: an id is required"
	cli_ready
	url=$(luti_url "$kind" "$id" "$what") || exit
	if [[ $print == true ]]; then
		printf '%s\n' "$url"
	else
		luti_open_url "$url" || exit
		cli_info "opened $url"
	fi
}

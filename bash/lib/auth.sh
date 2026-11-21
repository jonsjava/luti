# shellcheck shell=bash
# login, logout, whoami

cmd_login() {
	local instance="" username="" mfa="" pw totp req out jwt
	while [[ $# -gt 0 ]]; do
		case $1 in
			-h | --help)
				cat <<'EOF'
Usage: luti [--profile NAME] login [--instance URL] [--username NAME] [--mfa|--no-mfa]

Logs in and saves the token in the profile. Asks for anything not given,
reading the password without echo (and a TOTP code when MFA is on).
The password is never stored. Password and TOTP code may also be piped
on stdin, one per line.
EOF
				return 0
				;;
			-i | --instance)
				lt_need_arg "$@"
				instance=$2
				shift
				;;
			-u | --username)
				lt_need_arg "$@"
				username=$2
				shift
				;;
			-m | --mfa) mfa=true ;;
			--no-mfa) mfa=false ;;
			*) lt_die "login: unknown option '$1'" ;;
		esac
		shift
	done
	[[ -z $instance ]] && instance=${LT_INSTANCE:-$(lt_cfg instance)}
	[[ -z $username ]] && username=$(lt_cfg username)
	[[ -z $mfa ]] && mfa=$(lt_cfg mfa)
	[[ $mfa == true ]] || mfa=false
	[[ -z $instance ]] && lt_prompt instance "Instance (e.g. https://lemmy.world): "
	[[ -z $instance ]] && lt_die "login: an instance is required"
	[[ -z $username ]] && lt_prompt username "Username or email: "
	[[ -z $username ]] && lt_die "login: a username is required"

	instance=$(lt_normalize_instance "$instance")
	# A new instance means the cached version (and any old token) no longer apply.
	if [[ $instance != "$(lt_cfg instance)" ]]; then
		LT_CFG["api"]=""
	fi
	LT_INSTANCE=$instance
	local forced_ver=$LT_VER
	if [[ -z $LT_VER ]]; then
		LT_VER=$(lt_detect_version "$instance") ||
			lt_die "cannot reach a Lemmy 0.19+ API at $instance (tried /api/v4/site and /api/v3/site)"
	fi

	lt_prompt_secret pw "Password for $username: "
	[[ -n $pw ]] || lt_die "login: empty password"
	totp=""
	if [[ $mfa == true ]]; then
		lt_prompt totp "TOTP code: "
	fi

	LT_TOKEN=""
	req=$(jq -n --arg u "$username" --arg p "$pw" --arg t "$totp" \
		'{username_or_email: $u, password: $p} + (if $t != "" then {totp_2fa_token: $t} else {} end)')
	if ! out=$(lt_api auth.login "$req" 2>&1); then
		if [[ $out == *missing_totp_token* && -z $totp ]]; then
			lt_prompt totp "TOTP code: "
			req=$(jq -n --arg u "$username" --arg p "$pw" --arg t "$totp" \
				'{username_or_email: $u, password: $p, totp_2fa_token: $t}')
			out=$(lt_api auth.login "$req") || return 1
			mfa=true
		else
			printf '%s\n' "$out" >&2
			return 1
		fi
	fi
	pw=""
	jwt=$(jq -r '.jwt // empty' <<<"$out")
	[[ -n $jwt ]] || lt_die "login: no token in the response (account pending approval or email unverified?)"

	LT_CFG["instance"]=$instance
	LT_CFG["username"]=$username
	LT_CFG["mfa"]=$mfa
	# shellcheck disable=SC2034  # LT_CFG is written out by lt_config_save
	if [[ -n $forced_ver ]]; then LT_CFG["api"]=$forced_ver; fi
	lt_config_save
	lt_token_save "$jwt"
	lt_api_cache_write "$LT_VER" "$instance"
	lt_info "Logged in to $instance as $username (API $LT_VER, profile $LT_PROFILE)."
}

cmd_logout() {
	if lt_help_requested "$@"; then
		echo "Usage: luti [--profile NAME] logout"
		echo "Invalidates the token on the server (if reachable) and deletes it locally."
		return 0
	fi
	lt_load_token
	if [[ -n $LT_TOKEN ]] && [[ -n ${LT_INSTANCE:-$(lt_cfg instance)} ]]; then
		lt_api auth.logout '{}' >/dev/null 2>&1 || lt_warn "server logout failed; deleting the local token anyway"
	fi
	lt_token_delete
	lt_info "Logged out (profile $LT_PROFILE)."
}

cmd_whoami() {
	if lt_help_requested "$@"; then
		echo "Usage: luti whoami [--json|--norm]"
		echo "Shows the account the profile is logged in as."
		return 0
	fi
	lt_require_login
	local raw norm
	raw=$(lt_api account.get) || return 1
	norm=$(jq -c --arg v "$LT_VER" --arg i "$LT_INSTANCE" --arg p "$LT_PROFILE" '
		.local_user_view as $u | {
			id: $u.person.id, name: $u.person.name, display_name: $u.person.display_name,
			admin: ($u.local_user.admin // false), instance: $i, api: $v, profile: $p,
			moderates: [.moderates[]?.community.name]
		}' <<<"$raw")
	# shellcheck disable=SC2329  # called through lt_output
	_lt_show_whoami() {
		jq -r '"\(.name) (id \(.id))" + (if .admin then " [admin]" else "" end),
			"instance: \(.instance)  api: \(.api)  profile: \(.profile)",
			(if (.moderates | length) > 0 then "moderates: " + (.moderates | join(", ")) else empty end)'
	}
	lt_output "$raw" "$norm" _lt_show_whoami
}

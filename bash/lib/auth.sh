# shellcheck shell=bash
# Login, logout, current account.

# luti_login USER PASSWORD [TOTP]: print the JWT. The password is only sent
# to the server. Returns 3 when the account needs a TOTP code and none (or a
# wrong one) was given, 1 on other failures.
#   LUTI_TOKEN=$(luti_login alice "$pw") || ...
luti_login() {
	local user=${1:-} pw=${2:-} totp=${3:-} req out code msg
	[[ -n $user && -n $pw ]] || {
		_luti_err "luti_login: user and password are required"
		return 1
	}
	req=$(jq -nc --arg u "$user" --arg p "$pw" --arg t "$totp" \
		'{username_or_email: $u, password: $p} + (if $t != "" then {totp_2fa_token: $t} else {} end)')
	for _ in 1 2 3; do
		out=$(LUTI_TOKEN="" _luti_http auth.login "$req") || return
		code=${out##*$'\n'}
		out=${out%$'\n'*}
		msg=$(jq -r '.error // empty' <<<"$out" 2>/dev/null)
		# Lemmy 1.0 issues the same JWT for two logins of one user within a
		# second, and the second insert fails with couldnt_create: retry.
		[[ $msg == couldnt_create || $out == *login_token_pkey* ]] || break
		sleep 1
	done
	if [[ $msg == missing_totp_token || $msg == incorrect_totp_token ]]; then
		_luti_err "login: $msg (a TOTP code is required)"
		return 3
	fi
	if [[ -n $msg || $code != 2* ]]; then
		_luti_err "auth.login failed: ${msg:-HTTP $code} [HTTP $code]"
		return 1
	fi
	out=$(jq -r '.jwt // empty' <<<"$out")
	[[ -n $out ]] || {
		_luti_err "login: no token in the response (application pending or email not verified?)"
		return 1
	}
	printf '%s\n' "$out"
}

# luti_logout: invalidate LUTI_TOKEN on the server.
luti_logout() {
	_luti_need_token || return 1
	luti_api auth.logout '{}' >/dev/null
}

# luti_whoami: print the account {id,name,display_name,admin,moderates}.
luti_whoami() {
	local raw
	_luti_need_token || return 1
	raw=$(luti_api account.get) || return
	_luti_norm "$raw" 'account($v)'
}

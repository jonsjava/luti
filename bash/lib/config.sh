# shellcheck shell=bash
# Opt-in profile config, shared with the Python TUI.
#   ${XDG_CONFIG_HOME:-$HOME/.config}/luti/<profile>/config     key="value" lines
#   ${XDG_CONFIG_HOME:-$HOME/.config}/luti/<profile>/token      raw JWT (0600)
#   ${XDG_CONFIG_HOME:-$HOME/.config}/luti/<profile>/api_cache  "<v3|v4> <instance>"
# Keys: instance, username, mfa (true/false), api (v3/v4, optional override).
# The config file is parsed line by line and never sourced.

# luti_valid_profile NAME
luti_valid_profile() {
	[[ -n ${1:-} && $1 != *[!A-Za-z0-9._-]* && $1 != . && $1 != .. ]]
}

# luti_config_dir [PROFILE]: print the profile directory.
luti_config_dir() {
	printf '%s/luti/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "${1:-$LUTI_PROFILE}"
}

# luti_state_dir [PROFILE]: print the profile state directory (watch/stargaze state).
luti_state_dir() {
	printf '%s/luti/%s' "${XDG_STATE_HOME:-$HOME/.local/state}" "${1:-$LUTI_PROFILE}"
}

# _luti_config_parse FILE: print "key<TAB>value" for known keys.
_luti_config_parse() {
	local line key val
	[[ -f $1 ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		[[ -z $line || $line == \#* || $line != *=* ]] && continue
		key=${line%%=*}
		val=${line#*=}
		key=${key%"${key##*[![:space:]]}"}
		val=${val#"${val%%[![:space:]]*}"}
		if [[ ${#val} -ge 2 && $val == \"*\" ]]; then
			val=${val:1:${#val}-2}
		fi
		case $key in
			instance | username | mfa | api) printf '%s\t%s\n' "$key" "$val" ;;
		esac
	done <"$1"
	return 0
}

# luti_config_load [PROFILE]: set LUTI_PROFILE, LUTI_INSTANCE, LUTI_USERNAME,
# LUTI_MFA, LUTI_CONFIG_API, LUTI_API (config override or cached detection)
# and LUTI_TOKEN from the profile. Missing files leave values empty.
luti_config_load() {
	local profile=${1:-$LUTI_PROFILE} dir key val cache_v cache_i
	luti_valid_profile "$profile" || {
		_luti_err "invalid profile name '$profile'"
		return 1
	}
	dir=$(luti_config_dir "$profile")
	LUTI_PROFILE=$profile
	LUTI_INSTANCE="" LUTI_USERNAME="" LUTI_MFA=false LUTI_CONFIG_API="" LUTI_API="" LUTI_TOKEN=""
	while IFS=$'\t' read -r key val; do
		case $key in
			instance) LUTI_INSTANCE=$val ;;
			username) LUTI_USERNAME=$val ;;
			mfa) LUTI_MFA=$(_luti_bool "$val" false) ;;
			api) LUTI_CONFIG_API=$val ;;
		esac
	done < <(_luti_config_parse "$dir/config")
	[[ -n $LUTI_INSTANCE ]] && LUTI_INSTANCE=$(luti_normalize_instance "$LUTI_INSTANCE")
	LUTI_API=$LUTI_CONFIG_API
	if [[ -z $LUTI_API && -f $dir/api_cache ]]; then
		read -r cache_v cache_i <"$dir/api_cache" || true
		if [[ ${cache_i:-} == "$LUTI_INSTANCE" && (${cache_v:-} == v3 || ${cache_v:-} == v4) ]]; then
			LUTI_API=$cache_v
		fi
	fi
	if [[ -f $dir/token ]]; then
		IFS= read -r LUTI_TOKEN <"$dir/token" || true
	fi
	return 0
}

_luti_mkdir_private() {
	(umask 077 && mkdir -p "$1") && chmod 700 "$1"
}

# _luti_atomic_write FILE: write stdin to FILE via a temp file and mv (mode 0600).
_luti_atomic_write() {
	local dir tmp
	dir=$(dirname "$1")
	mkdir -p "$dir" || return 1
	tmp=$(mktemp "$1.XXXXXX") || return 1
	if ! { cat >"$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$1"; }; then
		rm -f "$tmp"
		return 1
	fi
}

# luti_config_save: write LUTI_INSTANCE, LUTI_USERNAME, LUTI_MFA and
# LUTI_CONFIG_API to the profile's config file.
luti_config_save() {
	local dir key val
	dir=$(luti_config_dir)
	_luti_mkdir_private "$dir" || return 1
	for val in "$LUTI_INSTANCE" "$LUTI_USERNAME" "$LUTI_CONFIG_API"; do
		if [[ $val == *[$'"\n']* ]]; then
			_luti_err "config values may not contain quotes or newlines"
			return 1
		fi
	done
	{
		for key in instance username mfa api; do
			case $key in
				instance) val=$LUTI_INSTANCE ;;
				username) val=$LUTI_USERNAME ;;
				mfa) val=$(_luti_bool "$LUTI_MFA" false) ;;
				api) val=$LUTI_CONFIG_API ;;
			esac
			[[ -n $val ]] && printf '%s="%s"\n' "$key" "$val"
		done
		true
	} | _luti_atomic_write "$dir/config"
}

# luti_token_save [TOKEN]: store TOKEN (default LUTI_TOKEN) in the profile, mode 0600.
luti_token_save() {
	local dir
	dir=$(luti_config_dir)
	_luti_mkdir_private "$dir" || return 1
	printf '%s\n' "${1:-$LUTI_TOKEN}" | _luti_atomic_write "$dir/token"
}

luti_token_delete() { rm -f "$(luti_config_dir)/token"; }

# luti_config_cache_api: remember LUTI_API for LUTI_INSTANCE in the profile.
luti_config_cache_api() {
	local dir
	dir=$(luti_config_dir)
	[[ -d $dir && -n $LUTI_API && -n $LUTI_INSTANCE ]] || return 0
	printf '%s %s\n' "$LUTI_API" "$LUTI_INSTANCE" >"$dir/api_cache"
}

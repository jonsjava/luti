# shellcheck shell=bash
# Profile config, shared with the Python TUI.
#   ${XDG_CONFIG_HOME:-$HOME/.config}/luti/<profile>/config   key=value lines
#   ${XDG_CONFIG_HOME:-$HOME/.config}/luti/<profile>/token    raw JWT (mode 0600)
# Keys: instance, username, mfa (true/false), api (v3/v4, optional override).
# The file is parsed line by line; it is never sourced.

LT_PROFILE=${LT_PROFILE:-default}
declare -gA LT_CFG=()

lt_config_dir() {
	printf '%s/luti/%s' "${XDG_CONFIG_HOME:-$HOME/.config}" "$LT_PROFILE"
}

lt_valid_profile() {
	[[ $1 =~ ^[A-Za-z0-9._-]+$ && $1 != . && $1 != .. ]]
}

# lt_config_parse FILE: fill LT_CFG from FILE. Unknown keys are ignored.
lt_config_parse() {
	local file=$1 line key val
	LT_CFG=()
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		line=${line%$'\r'}
		# trim leading/trailing whitespace
		line=${line#"${line%%[![:space:]]*}"}
		line=${line%"${line##*[![:space:]]}"}
		[[ -z $line || $line == \#* ]] && continue
		[[ $line == *=* ]] || continue
		key=${line%%=*}
		val=${line#*=}
		key=${key%"${key##*[![:space:]]}"}
		val=${val#"${val%%[![:space:]]*}"}
		if [[ ${#val} -ge 2 && $val == \"*\" ]]; then
			val=${val:1:${#val}-2}
		fi
		case $key in
			instance | username | mfa | api) LT_CFG[$key]=$val ;;
		esac
	done <"$file"
}

lt_config_load() {
	lt_config_parse "$(lt_config_dir)/config"
}

lt_cfg() { printf '%s' "${LT_CFG[$1]:-}"; }

# lt_config_save: write LT_CFG to the profile's config file.
lt_config_save() {
	local dir key tmp
	dir=$(lt_config_dir)
	(umask 077 && mkdir -p "$dir")
	chmod 700 "$dir"
	tmp=$(mktemp "$dir/config.XXXXXX")
	{
		for key in instance username mfa api; do
			[[ -n ${LT_CFG[$key]:-} ]] || continue
			[[ ${LT_CFG[$key]} == *[$'"\n']* ]] && lt_die "config value for $key may not contain quotes or newlines"
			printf '%s="%s"\n' "$key" "${LT_CFG[$key]}"
		done
	} >"$tmp"
	chmod 600 "$tmp"
	mv "$tmp" "$dir/config"
}

lt_token_file() { printf '%s/token' "$(lt_config_dir)"; }

lt_token_read() {
	local f
	f=$(lt_token_file)
	[[ -f $f ]] || return 1
	local t
	IFS= read -r t <"$f" || [[ -n $t ]]
	[[ -n $t ]] || return 1
	printf '%s' "$t"
}

lt_token_save() {
	local dir
	dir=$(lt_config_dir)
	(umask 077 && mkdir -p "$dir")
	chmod 700 "$dir"
	(umask 077 && printf '%s\n' "$1" >"$dir/token")
	chmod 600 "$dir/token"
}

lt_token_delete() { rm -f "$(lt_token_file)"; }

# Cached API version: "<version> <instance>" in <profile>/api_cache.
lt_api_cache_read() {
	local f v inst
	f="$(lt_config_dir)/api_cache"
	[[ -f $f ]] || return 1
	read -r v inst <"$f" || true
	[[ $inst == "$1" && ($v == v3 || $v == v4) ]] || return 1
	printf '%s' "$v"
}

lt_api_cache_write() {
	local dir
	dir=$(lt_config_dir)
	[[ -d $dir ]] || return 0
	printf '%s %s\n' "$1" "$2" >"$dir/api_cache"
}

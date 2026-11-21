#!/usr/bin/env bash
# luti.sh - compatibility wrapper for the original luti report watcher.
# Maps the old flags onto the new CLI and runs `bash/luti watch`.
# For everything else use bash/luti directly (bash/luti --help).
set -uo pipefail

LUTI_SH_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
LUTI="$LUTI_SH_DIR/bash/luti"

usage() {
	cat <<EOF
Usage: $0 [OPTIONS]
Shows open report counts and refreshes them (runs: bash/luti watch).

Options:
  -h, --help                          Show this help message and exit
  -f=FILE, --config=FILE              Read instance/username/MFA from an old-style luti config file
  -i=INSTANCE, --instance=INSTANCE    Instance (example: https://lemmy.world)
  -u=USERNAME, --username=USERNAME    Username
  -p=PASSWORD, --password=PASSWORD    Password (deprecated: visible to other users; you will be asked instead)
  -m, --mfa                           Ask for a TOTP code when logging in
  -r=REFRESH, --refresh=REFRESH       Refresh interval in seconds (default: 60)

The login is saved in the luti profile (default: \$LUTI_PROFILE or "default"),
so later runs need no options. See bash/luti --help for the full client.
EOF
}

instance="" username="" password="" mfa=false refresh=60 config=""

# read_old_config FILE: parse the old my_instance=/my_username=/my_password=/USE_MFA= file.
# The file is read line by line and never sourced.
read_old_config() {
	local line key val
	[[ -r $1 ]] || {
		echo "luti.sh: cannot read config file '$1'" >&2
		exit 1
	}
	while IFS= read -r line || [[ -n $line ]]; do
		[[ $line == *=* ]] || continue
		key=${line%%=*}
		key=${key//[[:space:]]/}
		[[ $key == \#* ]] && continue
		val=${line#*=}
		val=${val#"${val%%[![:space:]]*}"}
		if [[ $val == \"* ]]; then
			val=${val:1}
			val=${val%%\"*}
		else
			val=${val%%#*}
			val=${val%"${val##*[![:space:]]}"}
		fi
		case $key in
			my_instance) [[ -z $instance ]] && instance=$val ;;
			my_username) [[ -z $username ]] && username=$val ;;
			my_password)
				if [[ -n $val ]]; then
					echo "luti.sh: warning: my_password in config files is deprecated; luti now saves a login token instead" >&2
					[[ -z $password ]] && password=$val
				fi
				;;
			USE_MFA) [[ $val == true ]] && mfa=true ;;
		esac
	done <"$1"
}

while [[ $# -gt 0 ]]; do
	case $1 in
		-h | --help)
			usage
			exit 0
			;;
		-f=* | --config=*) config=${1#*=} ;;
		-i=* | --instance=*) instance=${1#*=} ;;
		-u=* | --username=*) username=${1#*=} ;;
		-p=* | --password=*)
			password=${1#*=}
			echo "luti.sh: warning: -p/--password is deprecated (other users can see it in the process list); leave it out to be asked" >&2
			;;
		-m | --mfa) mfa=true ;;
		-r=* | --refresh=*) refresh=${1#*=} ;;
		-r | --refresh)
			refresh=${2:-}
			shift
			;;
		*)
			echo "Unknown option: $1" >&2
			usage >&2
			exit 1
			;;
	esac
	shift
done

[[ -n $config ]] && read_old_config "$config"
[[ $refresh =~ ^[0-9]+$ && $refresh -gt 0 ]] || {
	echo "luti.sh: refresh interval must be a positive number" >&2
	exit 1
}

login_args=()
[[ -n $instance ]] && login_args+=(--instance "$instance")
[[ -n $username ]] && login_args+=(--username "$username")
[[ $mfa == true ]] && login_args+=(--mfa)

need_login=false
if [[ ${#login_args[@]} -gt 0 || -n $password ]]; then
	need_login=true
elif ! "$LUTI" whoami >/dev/null 2>&1; then
	need_login=true
fi

if [[ $need_login == true ]]; then
	if [[ -n $password ]]; then
		totp=""
		if [[ $mfa == true ]]; then
			read -r -p "Enter MFA Token: " totp
			[[ $totp =~ ^[0-9]+$ ]] || {
				echo "invalid MFA token" >&2
				exit 1
			}
		fi
		printf '%s\n%s\n' "$password" "$totp" | "$LUTI" login ${login_args[@]+"${login_args[@]}"} || exit 1
	else
		"$LUTI" login ${login_args[@]+"${login_args[@]}"} || exit 1
	fi
fi
password=""

exec "$LUTI" watch --refresh "$refresh"

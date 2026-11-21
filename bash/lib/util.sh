# shellcheck shell=bash
# Small helpers shared by every module: messages, prompts, option checks.

# Global state, set by bash/luti from the command line.
LT_JSON=${LT_JSON:-0}      # 1 = print raw API JSON
LT_NORM=${LT_NORM:-0}      # 1 = print normalized JSON
LT_YES=${LT_YES:-0}        # 1 = skip confirmation prompts

lt_err() { printf 'luti: %s\n' "$*" >&2; }
lt_warn() { printf 'luti: warning: %s\n' "$*" >&2; }
lt_die() { lt_err "$@"; exit 1; }
lt_info() { printf '%s\n' "$*" >&2; }

# lt_need_arg OPTION VALUE: fail when an option is missing its value.
lt_need_arg() {
	if [[ $# -lt 2 || -z $2 || $2 == --* ]]; then
		lt_die "option $1 needs a value"
	fi
}

# lt_need_int NAME VALUE
lt_need_int() {
	[[ $2 =~ ^[0-9]+$ ]] || lt_die "$1 must be a number, got '$2'"
}

# lt_confirm PROMPT: true when --yes was given or the user answers y.
lt_confirm() {
	local ans
	[[ $LT_YES == 1 ]] && return 0
	if [[ ! -t 0 ]]; then
		lt_err "$1 -- refusing without --yes (no terminal to ask)"
		return 1
	fi
	read -r -p "$1 [y/N] " ans
	[[ $ans == y || $ans == Y || $ans == yes ]]
}

# lt_prompt VAR PROMPT: read a line into VAR (prompt on stderr).
lt_prompt() {
	local __v
	printf '%s' "$2" >&2
	IFS= read -r __v || true
	printf -v "$1" '%s' "$__v"
}

# lt_prompt_secret VAR PROMPT: like lt_prompt but without echo.
lt_prompt_secret() {
	local __v
	printf '%s' "$2" >&2
	IFS= read -rs __v || true
	printf '\n' >&2
	printf -v "$1" '%s' "$__v"
}

# lt_jq ARGS...: jq with luti's jq library (bash/lib/luti.jq) loaded.
lt_jq() {
	jq -L "$LT_LIB" "$@"
}

# lt_output RAW NORMALIZED DISPLAY_FN: print according to --json / --norm.
lt_output() {
	if [[ $LT_JSON == 1 ]]; then
		printf '%s\n' "$1"
	elif [[ $LT_NORM == 1 ]]; then
		printf '%s\n' "$2"
	else
		"$3" <<<"$2"
	fi
}

# lt_help_requested ARGS...: true if -h or --help is among ARGS.
lt_help_requested() {
	local a
	for a in "$@"; do
		[[ $a == -h || $a == --help ]] && return 0
	done
	return 1
}

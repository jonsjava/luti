# shellcheck shell=bash
# CLI helpers: messages, prompts, option checks, output. CLI code may exit;
# the library (bash/lib) never does.

CLI_JSON=0   # --json: raw API responses (sets LUTI_RAW=1)
CLI_NORM=0   # --norm: normalized JSON
CLI_YES=0    # --yes: no confirmation prompts
CLI_WIDTH=${COLUMNS:-100}

cli_err() { printf 'luti: %s\n' "$*" >&2; }
cli_die() {
	cli_err "$@"
	exit 1
}
cli_info() { printf '%s\n' "$*" >&2; }

# cli_need_arg OPTION [VALUE]: fail when an option is missing its value.
cli_need_arg() {
	if [[ $# -lt 2 || -z $2 || $2 == --* ]]; then
		cli_die "option $1 needs a value"
	fi
}

cli_need_int() {
	[[ -n $2 && $2 != *[!0-9]* ]] || cli_die "$1 must be a number, got '$2'"
}

cli_help_requested() {
	local a
	for a in "$@"; do
		[[ $a == -h || $a == --help ]] && return 0
	done
	return 1
}

# cli_confirm PROMPT: true when --yes was given or the user answers y.
cli_confirm() {
	local ans
	[[ $CLI_YES == 1 ]] && return 0
	if [[ ! -t 0 ]]; then
		cli_err "$1 -- refusing without --yes (no terminal to ask)"
		return 1
	fi
	read -r -p "$1 [y/N] " ans
	[[ $ans == y || $ans == Y || $ans == yes ]]
}

cli_prompt() { # cli_prompt VAR PROMPT
	local __v
	printf '%s' "$2" >&2
	IFS= read -r __v || true
	printf -v "$1" '%s' "$__v"
}

cli_prompt_secret() { # cli_prompt_secret VAR PROMPT
	local __v
	printf '%s' "$2" >&2
	IFS= read -rs __v || true
	printf '\n' >&2
	printf -v "$1" '%s' "$__v"
}

# cli_ready: instance and API version known (detected once and cached per profile).
cli_ready() {
	[[ -n $LUTI_INSTANCE ]] || cli_die "no instance configured for profile '$LUTI_PROFILE'; run 'luti login' or pass --instance"
	LUTI_INSTANCE=$(luti_normalize_instance "$LUTI_INSTANCE")
	if [[ -z $LUTI_API ]]; then
		LUTI_API=$(luti_detect_version "$LUTI_INSTANCE") || exit 1
		luti_config_cache_api
	fi
	[[ $LUTI_API == v3 || $LUTI_API == v4 ]] || cli_die "unknown API version '$LUTI_API' (use v3 or v4)"
}

cli_login_required() {
	cli_ready
	[[ -n $LUTI_TOKEN ]] || cli_die "not logged in (profile '$LUTI_PROFILE'); run 'luti login'"
}

# cli_jq ARGS...: jq with the display module.
cli_jq() { jq -L "$CLI_DIR" "$@"; }

# cli_show OUT FILTER: print OUT as JSON (--json/--norm) or render it with a display.jq FILTER.
cli_show() {
	if [[ $CLI_JSON == 1 || $CLI_NORM == 1 ]]; then
		printf '%s\n' "$1"
	else
		cli_jq -r --argjson w "$CLI_WIDTH" "include \"display\"; $2" <<<"$1"
	fi
}

# cli_show_list OUT FILTER: like cli_show for {items, next}; prints the next-page hint.
cli_show_list() {
	cli_show "$1" ".items | $2"
	[[ $CLI_JSON == 1 || $CLI_NORM == 1 ]] && return 0
	local next
	next=$(jq -r 'if .next == null then empty elif (.next | type) == "number" then "--page \(.next)" else "--cursor \(.next)" end' <<<"$1")
	[[ -n $next ]] && cli_info "next: $next"
	return 0
}

# cli_ok OUT MESSAGE: for write commands; JSON with --json/--norm, else MESSAGE.
cli_ok() {
	if [[ $CLI_JSON == 1 || $CLI_NORM == 1 ]]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# cli_field OUT JQ: read a field from a normalized result (empty in --json mode).
cli_field() {
	[[ $CLI_JSON == 1 ]] && return 0
	jq -r "$2 // empty" <<<"$1"
}

# cli_body TEXT FILE: TEXT, or the contents of FILE (- = stdin).
cli_body() {
	if [[ -n $2 ]]; then
		if [[ $2 == - ]]; then cat; else
			[[ -r $2 ]] || cli_die "cannot read $2"
			cat -- "$2"
		fi
	else
		printf '%s' "$1"
	fi
}

# cli_page_opts PAGE CURSOR: JSON fragment for --page / --cursor.
cli_page_opts() {
	jq -nc --arg p "$1" --arg c "$2" '(if $p != "" then {page: ($p | tonumber)} else {} end) + (if $c != "" then {cursor: $c} else {} end)'
}

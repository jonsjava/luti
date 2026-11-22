# shellcheck shell=bash
# Internal helpers. Regex matching (=~) is avoided so BASH_REMATCH is never touched.

_luti_err() { printf 'luti: %s\n' "$*" >&2; }

# _luti_is_id VALUE: a positive integer
_luti_is_id() { [[ -n ${1:-} && $1 != *[!0-9]* ]]; }

# _luti_need_id WHAT VALUE
_luti_need_id() {
	_luti_is_id "${2:-}" && return 0
	_luti_err "$1: expected a numeric id, got '${2:-}'"
	return 1
}

# _luti_bool VALUE DEFAULT: print true or false
_luti_bool() {
	case ${1:-$2} in
		true | 1 | yes | on) printf 'true' ;;
		false | 0 | no | off) printf 'false' ;;
		*) printf '%s' "$2" ;;
	esac
}

# _luti_jq ARGS...: jq with luti.jq loadable via include "luti".
_luti_jq() { jq -L "$LUTI_LIB_DIR" "$@"; }

# _luti_req FILTER [OPTS] [JQ_ARGS...]: build a request in jq.
# FILTER runs with the options object as input and $v (API version) and
# $spec (endpoint map) bound. jq errors become a plain message.
_luti_req() {
	local filter=$1 opts=${2:-} out
	[[ -n $opts ]] || opts='{}'
	shift
	[[ $# -gt 0 ]] && shift
	out=$(jq -nc -L "$LUTI_LIB_DIR" --arg v "$LUTI_API" --slurpfile spec "$(_luti_spec_file)" \
		--argjson o "$opts" "$@" "include \"luti\"; \$spec[0] as \$spec | \$o | $filter" 2>&1) || {
		out=${out#jq: error (at <unknown>): }
		_luti_err "${out#jq: error: }"
		return 1
	}
	printf '%s\n' "$out"
}

# _luti_emit RAW NORM: print the normalized result, or the raw one with LUTI_RAW=1.
_luti_emit() {
	if [[ ${LUTI_RAW:-0} == 1 ]]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi
}

# _luti_norm RAW FILTER [JQ_ARGS...]: normalize RAW with FILTER and emit.
_luti_norm() {
	local raw=$1 filter=$2 norm
	shift 2
	if [[ ${LUTI_RAW:-0} == 1 ]]; then
		printf '%s\n' "$raw"
		return 0
	fi
	norm=$(_luti_jq -c --arg v "$LUTI_API" "$@" "include \"luti\"; $filter" <<<"$raw") || return 1
	printf '%s\n' "$norm"
}

# _luti_emit_list OP RAW ITEM_FILTER [REQUEST]: print {items, next} for a list response.
_luti_emit_list() {
	local op=$1 raw=$2 f=$3 req=${4:-}
	[[ -n $req ]] || req='{}'
	_luti_norm "$raw" "(spec_list(\$l) | map($f)) as \$i | {items: \$i, next: next_page(\$v; \$req; \$i | length)}" \
		--argjson l "$(_luti_list_key "$op")" --argjson req "$req"
}

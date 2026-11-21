# shellcheck shell=bash
# shellcheck disable=SC2034  # variables here are used by the .bats files
# Shared setup for luti's Bash tests.
#
# Tools (installed locally, nothing system-wide):
#   cd tests/bash/.tools && npm i bats && python3 -m venv venv && venv/bin/pip install shellcheck-py
# Run:
#   tests/bash/.tools/node_modules/.bin/bats tests/bash
# Integration tests need the dev servers:
#   docker compose -f dev/docker-compose.yml up -d && dev/seed.sh
# They are skipped when the servers are unreachable, unless LUTI_REQUIRE_SERVERS=1.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
LUTI="$REPO_ROOT/bash/luti"
FIXTURES="$REPO_ROOT/tests/bash/fixtures"
export LUTI_SPEC="$REPO_ROOT/spec/endpoints.json"

# Isolated config dir per test (or per file when set in setup_file).
lt_test_config() {
	export XDG_CONFIG_HOME="${1:-$BATS_TEST_TMPDIR}/config"
	mkdir -p "$XDG_CONFIG_HOME"
	unset LUTI_PROFILE
}

# Load luti's library functions into the test shell (for unit tests).
lt_load_lib() {
	LT_ROOT=$REPO_ROOT
	LT_LIB="$REPO_ROOT/bash/lib"
	local m
	for m in util config api transform display; do
		# shellcheck source=/dev/null
		. "$LT_LIB/$m.sh"
	done
}

# Put the curl stub first in PATH. It records each call in $STUB_DIR and
# answers with $STUB_DIR/response (body) and $STUB_DIR/code (HTTP status).
lt_stub_curl() {
	export STUB_DIR="$BATS_TEST_TMPDIR/stub"
	mkdir -p "$STUB_DIR"
	export PATH="$REPO_ROOT/tests/bash/stubs:$PATH"
	printf '{}' >"$STUB_DIR/response"
	printf '200' >"$STUB_DIR/code"
}

stub_respond() { # stub_respond CODE BODY
	printf '%s' "$1" >"$STUB_DIR/code"
	printf '%s' "$2" >"$STUB_DIR/response"
}

# Write a profile config without logging in.
lt_write_profile() { # lt_write_profile PROFILE INSTANCE API [TOKEN]
	local d="$XDG_CONFIG_HOME/luti/$1"
	mkdir -p "$d"
	printf 'instance="%s"\nusername="tester"\nmfa=false\napi=%s\n' "$2" "$3" >"$d/config"
	[[ -n ${4:-} ]] && printf '%s\n' "$4" >"$d/token"
	return 0
}

# refute CMD...: succeed only if CMD fails (bats ignores a bare "! cmd" mid-test).
refute() {
	if "$@"; then
		return 1
	fi
	return 0
}

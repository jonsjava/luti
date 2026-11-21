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
	export XDG_STATE_HOME="${1:-$BATS_TEST_TMPDIR}/state"
	mkdir -p "$XDG_CONFIG_HOME"
	unset LUTI_PROFILE
}

# Load luti's library into the test shell (for unit tests), with a clean
# connection: set LUTI_INSTANCE / LUTI_API / LUTI_TOKEN in the test.
lt_load_lib() {
	unset LUTI_INSTANCE LUTI_TOKEN LUTI_API LUTI_RAW LUTI_PROFILE LUTI_USERNAME LUTI_MFA LUTI_CONFIG_API
	# shellcheck source=/dev/null
	. "$REPO_ROOT/bash/lib/luti.sh"
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

stub_route() { # stub_route "GET api/v4/post/list" BODY
	mkdir -p "$STUB_DIR/routes"
	local r=${1/ /_}
	printf '%s' "$2" >"$STUB_DIR/routes/${r//\//_}"
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

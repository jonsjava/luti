# shellcheck shell=bash
# shellcheck disable=SC2034  # LUTI_* settings are read by the modules and by callers
# luti library: a Lemmy API client for Bash (Lemmy 0.19 / API v3 and 1.0 / API v4).
#
#   source /path/to/luti/lib/luti.sh
#
# Loading defines luti_* (public) and _luti_* (internal) functions and LUTI_*
# variables. It runs nothing else: no requests, no config reads, no `exit`,
# no changes to shell options, IFS or traps. Functions report failure with a
# non-zero return code and a message on stderr. Needs bash 4.3+, curl and jq.
# See bash/README.md for the public functions.

if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt 4 ] ||
	{ [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 3 ]; }; then
	echo "luti: bash 4.3 or newer is required" >&2
	return 1
fi

LUTI_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LUTI_VERSION="1.1.0"

# Connection settings: set these directly, use luti_connect, or luti_config_load.
LUTI_INSTANCE=${LUTI_INSTANCE:-}  # base URL, e.g. https://lemmy.world
LUTI_TOKEN=${LUTI_TOKEN:-}        # JWT; empty = anonymous
LUTI_API=${LUTI_API:-}            # v3 | v4; empty = detect on first request
LUTI_SPEC=${LUTI_SPEC:-}          # endpoint map; empty = found next to the library
LUTI_TIMEOUT=${LUTI_TIMEOUT:-30}  # curl --max-time, seconds
LUTI_RAW=${LUTI_RAW:-0}           # 1 = data functions print raw API JSON instead of the common shape

# Set by luti_config_load (opt-in).
LUTI_PROFILE=${LUTI_PROFILE:-default}
LUTI_USERNAME=${LUTI_USERNAME:-}
LUTI_MFA=${LUTI_MFA:-false}
LUTI_CONFIG_API=${LUTI_CONFIG_API:-}

# shellcheck source=util.sh
. "$LUTI_LIB_DIR/util.sh"
# shellcheck source=config.sh
. "$LUTI_LIB_DIR/config.sh"
# shellcheck source=api.sh
. "$LUTI_LIB_DIR/api.sh"
# shellcheck source=auth.sh
. "$LUTI_LIB_DIR/auth.sh"
# shellcheck source=content.sh
. "$LUTI_LIB_DIR/content.sh"
# shellcheck source=community.sh
. "$LUTI_LIB_DIR/community.sh"
# shellcheck source=inbox.sh
. "$LUTI_LIB_DIR/inbox.sh"
# shellcheck source=mod.sh
. "$LUTI_LIB_DIR/mod.sh"
# shellcheck source=open.sh
. "$LUTI_LIB_DIR/open.sh"
# shellcheck source=watch.sh
. "$LUTI_LIB_DIR/watch.sh"
# shellcheck source=stars.sh
. "$LUTI_LIB_DIR/stars.sh"

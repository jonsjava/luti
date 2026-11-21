# shellcheck shell=bash disable=SC2034
# Package metadata for basher (https://github.com/basherpm/basher):
#   basher install jonsjava/luti
# Links bash/luti onto PATH. The CLI resolves the symlink to find its library
# and spec, so nothing else needs installing. Requires bash 4+, curl and jq.
BINS="bash/luti"
DEPS=""

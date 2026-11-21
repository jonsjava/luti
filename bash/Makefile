# Install the luti CLI and library.
#
#   make -C bash install                       # /usr/local
#   make -C bash install PREFIX=$HOME/.local   # per user, no root
#   make -C bash install DESTDIR=/tmp/pkg      # staged (for packaging)
#   make -C bash uninstall [PREFIX=...]
#
# Layout:
#   $(PREFIX)/bin/luti                 the CLI
#   $(PREFIX)/share/luti/lib/luti.sh   the library (source this from your scripts)
#   $(PREFIX)/share/luti/cli/          CLI-only modules
#   $(PREFIX)/share/luti/spec/         endpoints.json, the API v3/v4 endpoint map

PREFIX  ?= /usr/local
DESTDIR ?=
BINDIR  := $(DESTDIR)$(PREFIX)/bin
DATADIR := $(DESTDIR)$(PREFIX)/share/luti
SPEC    := ../spec/endpoints.json
INSTALL ?= install

LIB_FILES := $(wildcard lib/*.sh) lib/luti.jq
CLI_FILES := $(wildcard cli/*.sh) cli/display.jq

.PHONY: all install uninstall check test

all:
	@echo "Nothing to build. Run 'make install' (PREFIX=$(PREFIX))."

install:
	$(INSTALL) -d "$(BINDIR)" "$(DATADIR)/lib" "$(DATADIR)/cli" "$(DATADIR)/spec"
	$(INSTALL) -m 755 luti "$(BINDIR)/luti"
	$(INSTALL) -m 644 $(LIB_FILES) "$(DATADIR)/lib/"
	$(INSTALL) -m 644 $(CLI_FILES) "$(DATADIR)/cli/"
	$(INSTALL) -m 644 $(SPEC) "$(DATADIR)/spec/endpoints.json"

uninstall:
	rm -f "$(BINDIR)/luti"
	rm -rf "$(DATADIR)"

check:
	../tests/bash/.tools/venv/bin/shellcheck luti lib/*.sh cli/*.sh ../luti.sh

test:
	../tests/bash/.tools/node_modules/.bin/bats ../tests/bash

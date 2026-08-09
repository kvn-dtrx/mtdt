# ---
# title: Makefile for mtdt
# ---

# Make targets follow paradigmata (install = deploy; ops in justfile).

# ---

XDG_DATA_HOME ?= $(HOME)/.local/share
WIRE := $(CURDIR)/bin/make-wire.bash

.PHONY: install

install: ## Symlink wiring scripts into MY_LOCAL_HOME/bin
	@bash "$(WIRE)" "$(CURDIR)"

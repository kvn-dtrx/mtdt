# ---
# title: Makefile for mtdt
# ---

# Make targets follow paradigmata (install = deploy; ops in justfile).

# ---

XDG_DATA_HOME ?= $(HOME)/.local/share
WIRE := $(CURDIR)/bin/make-wire.py
LOG_LIBEXEC := $(CURDIR)/src/wire/logging/libexec

.PHONY: install

install: ## Symlink wiring scripts into MY_LOCAL_HOME/bin
	@if [ ! -f "$(LOG_LIBEXEC)/log-error" ]; then \
	    command -v dia > /dev/null 2>&1 || { \
	        printf 'Missing %s (dia not on PATH to pull scripts/log-*)\n' \
	            "$(LOG_LIBEXEC)/log-error" >&2; \
	        exit 1; \
	    }; \
	    dia "$(LOG_LIBEXEC)"; \
	fi
	@python3 "$(WIRE)" "$(CURDIR)"

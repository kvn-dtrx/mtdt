# ---
# title: Makefile for mtdt-project
# ---

# ---

.PHONY: install

install: ## Symlink wiring scripts into MY_LOCAL_HOME/bin
	@bin/make-install.bash

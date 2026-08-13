#!/usr/bin/env sh

# dia:file scripts/make-help.sh

# ---
# description: >-
#   Lists all make targets with description; more precisely, all lines
#   conceptually matching "identifier: ## description"
# ---

# ---

script="$(realpath "${0}")"
script_dir="$(dirname "${script}")"
ls_make_targets="${script_dir}/_ls-make-targets.awk"

printf "\n"
printf "\033[1;37m    %s\033[0m\n" "Available targets for make:"
printf "\n"

"${ls_make_targets}" Makefile | sed -e "s/^/    /"

printf "\n"
printf "\033[1;37m    %s\033[0m\n" "Important make flags:"
printf "\n"

printf "    %-16s: %s\n" \
    "-n" "Dry-run (print commands without running them)" \
    "-s" "Silent mode (don't print executed commands)" \
    "--debug[=b|v|a]" "Debug info (b=basic [default], v=verbose, a=all)"

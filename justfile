# ---
# title: justfile for mtdt
# ---

# ---

set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

projects := env_var_or_default("MTDT_PROJECTS_ROOT", home_directory() / "data" / "projects")

default:
    @just --list --unsorted

# Writes .mtdt.local.yaml from the private fork catalogue
deploy-mtdt-local *args:
    @src/wire/bin/mtdt deploy local {{ if args == "" { quote(projects) } else { args } }}

# Reports drift between .mtdt.local.yaml and the fork catalogue
check-mtdt-local *args:
    @src/wire/bin/mtdt deploy local --check {{ if args == "" { quote(projects) } else { args } }}

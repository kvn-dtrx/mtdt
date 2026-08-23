# Mtdt

## Synopsis

Specification, query, and deployment tooling for `.mtdt.yaml` and its local
forge overlay. The metadata is used to sync forge settings and to materialise
`LICENSE` from `project.license`. A separate helper can drop a static
`CONTRIBUTING.md` template.

This repository does **not** embed shared config snippets (that is dia).

## Layout

```
config/wire.ini           install mounts only (no host map)
docs/spec.md              normative schema
docs/example.mtdt.yaml    commented filled example (generic placeholders)
src/wire/bin/             installable CLIs (source of truth)
src/wire/lib/mtdt_metadata.py  shared mtdt parsing and project discovery
src/wire/logging/libexec/ shared log-* (dia: scripts/log-* )
examples/config/forks.yaml      public fork-catalogue example
share/templates/mtdt.yaml       blank .mtdt.yaml scaffold (init-mtdt)
share/templates/license/        license text templates
share/templates/contributing/   contributing templates
```

Host- or identity-bound data lives in each project's own `.mtdt.yaml` (authors,
forge URLs), not in this toolkit repo beyond this project's metadata file.

## Install

```bash
make install   # or: bin/make-install.bash
```

Uses `${MY_LOCAL_HOME:-$HOME/.local}/bin` and strips the file extension from
each wiring script name (e.g. `deploy-license.sh` → `deploy-license`).

## Command-line interface

`mtdt` is the primary PATH interface:

```bash
mtdt get project.name path/to/project
mtdt resolve path/to/project
mtdt validate ~/data/projects
mtdt check remotes path/to/project
mtdt sync remotes path/to/project
mtdt deploy license path/to/project
mtdt update github visibility ~/data/projects
```

Run `mtdt help` for the complete command map. The former flat commands remain installed as compatibility shims for scripts and existing muscle memory.

## Legacy command map

| Script | Role |
| --- | --- |
| `update-gh-repo-descriptions` | Push `project.description` via `gh repo edit` |
| `update-gh-repo-visibility` | Push `forges.github.visibility` |
| `update-gh-repo-names` | Prompt to rename GitHub toward mtdt slug (`derive-project-slug(name)`); `--dirname` = legacy |
| `derive-project-slug` | Print local directory slug derived from `project.name` (stdin/args) |
| `check-project-dirname` | Report dirname ↔ slug divergences; optional `--fix` renames (blocks if destination exists) |
| `check-forge-push` | `git push --dry-run` HEAD to effective `forges.github.url` (needs network + creds) |
| `resolve-mtdt` | Print `.mtdt.yaml` ⊕ `.mtdt.local.yaml` (`forges:` overlay only) |
| `deploy-mtdt-local` | Materialise `.mtdt.local.yaml` from the private fork catalogue |
| `mtdt-get` | Read a dotted property from base or effective metadata |
| `mtdt-project-id` | Print `project.id` for consumers without duplicating YAML parsing |
| `mtdt-list-projects` | List `project.id` and checkout path as TSV records |
| `split-mtdt-forks` | Move fork forge URL into `.mtdt.local.yaml`; base URL → upstream parent |
| `check-mtdt-remotes` | Check `origin`/`upstream` vs mtdt; `--fix` writes remotes (URL scheme from gitconfig) |
| `deploy-license` | Render `LICENSE.txt` (or `project.license.file`) from `project.license` |
| `deploy-contributing` | Copy static `CONTRIBUTING.md` template; fill `{{name}}` from `project.name` only |
| `flush-pyproject` | Patch existing `pyproject.toml` with overlapping identity fields (skip if absent) |
| `validate-mtdt` | Basic structural checks on `.mtdt.yaml` |
| `init-mtdt` | Scaffold `.mtdt.yaml` from `share/templates/mtdt.yaml` (fresh UUID) |

All directory-walking scripts accept one or more roots (default: `.`).
`init-mtdt` takes an optional target directory (default: `.`).
`derive-project-slug` takes name strings or stdin lines (not tree roots).

The private fork catalogue defaults to
`${XDG_CONFIG_HOME:-~/.config}/mtdt/forks.yaml`; override it with
`MTDT_FORKS_FILE`. A private repository may install that file, but mtdt does
not depend on the repository that stores it.

Environment plans, space mounts, project-tree layout, and editor workspaces
remain in **meta-project**. Those tools consume `project.id` through the public
mtdt commands without owning or reimplementing the metadata format.

### Property queries

`mtdt-get` accepts a project directory or a `.mtdt.yaml` path. Its default
`raw` format is intended for scalar shell values:

```bash
mtdt-get project.id /path/to/project
mtdt-get project.license.type /path/to/project
mtdt-get --effective forges.github.url /path/to/project
mtdt-get --format json project.authors /path/to/project
mtdt-get --format yaml project.license /path/to/project
```

The property syntax traverses mapping keys separated by dots; it does not
implement a general `jq`/`yq` expression language. Missing properties exit 1.
Collections in raw mode exit 2 and require `--format json` or `--format yaml`.
`mtdt-project-id` remains the semantic convenience command for consumers that
specifically require an identity and uses the same shared query implementation.

Local dirname ↔ `project.name` rules are normative in [`docs/spec.md`](docs/spec.md)
(no stored `project.slug`; forge slug only via `forges.*.url`).

### Further ideas (not implemented)

- `update-gh-repo-homepage.sh` — sync `project.homepage` / topics from `tags`
- `diff-gh-mtdt.sh` — show drift between `.mtdt.yaml` and live `gh repo view`
- `deploy-citation.sh` — emit `CITATION.cff` from authors + name + year

## Dependencies

- `yq` (YAML queries)
- `gh` (GitHub CLI) for the `update-gh-*` scripts
- POSIX `sh`
- Python ≥3.11 (stdlib only for `derive-project-slug`; `PyYAML` + `tomlkit` for `flush-pyproject`)

## Origin notes

- Spec adapted from a former Synerga scaffold note (removed after import)
- GitHub sync scripts relocated from `shell-scripts` wiring (removed after import)

## Colophon

**Author:** [kvn-dtrx](https://github.com/kvn-dtrx)

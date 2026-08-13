# Mtdt

## Synopsis

Specification and deployment tooling for `.mtdt.yaml` — per-repository
metadata used to sync forge settings and to materialise `LICENSE` from
`project.license`. A separate helper can drop a static `CONTRIBUTING.md`
template (only `project.name` is substituted — there is no contributing
schema in `.mtdt.yaml`).

This repository does **not** embed shared config snippets (that is dia).

## Layout

```
config/wire.ini           install mounts only (no host map)
docs/spec.md              normative schema
docs/example.mtdt.yaml    commented filled example (generic placeholders)
src/wire/bin/             installable CLIs (source of truth)
src/wire/logging/libexec/ shared log-* (dia: scripts/log-* )
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

## Scripts

| Script | Role |
| --- | --- |
| `update-gh-repo-descriptions` | Push `project.description` via `gh repo edit` |
| `update-gh-repo-visibility` | Push `forges.github.visibility` |
| `update-gh-repo-names` | Prompt to rename GitHub toward mtdt slug (`derive-project-slug(name)`); `--dirname` = legacy |
| `derive-project-slug` | Print local directory slug derived from `project.name` (stdin/args) |
| `check-project-dirname` | Report dirname ↔ slug divergences; optional `--fix` renames (blocks if destination exists) |
| `check-forge-push` | `git push --dry-run` HEAD to effective `forges.github.url` (needs network + creds) |
| `resolve-mtdt` | Print `.mtdt.yaml` ⊕ `.mtdt.local.yaml` (`forges:` overlay only) |
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

Catalog deploys (forks → `.mtdt.local.yaml`, env-plans → `.env`) live in
**meta-project** (CLIs) with live catalogs in private **meta-project-annex**.

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

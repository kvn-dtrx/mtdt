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
docs/spec.md              normative schema
docs/example.mtdt.yaml    commented filled example
src/wire/bin/             installable CLIs (source of truth)
templates/mtdt.yaml       blank .mtdt.yaml scaffold (init-mtdt)
templates/license/        license text templates
templates/contributing/   contributing templates
```

## Install

```bash
make install   # or: bin/make-install.bash
```

Uses `${MY_LOCAL_HOME:-$HOME/.local}/bin` and strips the file extension from
each wiring script name (e.g. `deploy-license.sh` → `deploy-license`).

## Scripts

| Script | Role |
|--------|------|
| `update-gh-repo-descriptions` | Push `project.description` via `gh repo edit` |
| `update-gh-repo-visibility` | Push `forges.github.visibility` |
| `update-gh-repo-names` | Prompt when local directory name ≠ GitHub name |
| `deploy-license` | Render `LICENSE` (or `project.license.file`) from `project.license` |
| `deploy-contributing` | Copy static `CONTRIBUTING.md` template; fill `{{name}}` from `project.name` only |
| `flush-pyproject` | Patch existing `pyproject.toml` with overlapping identity fields (skip if absent) |
| `validate-mtdt` | Basic structural checks on `.mtdt.yaml` |
| `init-mtdt` | Scaffold `.mtdt.yaml` from `templates/mtdt.yaml` (fresh UUID) |

All directory-walking scripts accept one or more roots (default: `.`).
`init-mtdt` takes an optional target directory (default: `.`).

### Further ideas (not implemented)

- `update-gh-repo-homepage.sh` — sync `project.homepage` / topics from `tags`
- `diff-gh-mtdt.sh` — show drift between `.mtdt.yaml` and live `gh repo view`
- `deploy-citation.sh` — emit `CITATION.cff` from authors + name + year

## Dependencies

- `yq` (YAML queries)
- `gh` (GitHub CLI) for the `update-gh-*` scripts
- POSIX `sh`
- Python ≥3.11 with `PyYAML` and `tomlkit` (for `flush-pyproject` only)

## Origin notes

- Spec adapted from a former Synerga scaffold note (removed after import)
- GitHub sync scripts relocated from `shell-scripts` wiring (removed after import)

## Colophon

**Author:** [kvn-dtrx](https://github.com/kvn-dtrx)

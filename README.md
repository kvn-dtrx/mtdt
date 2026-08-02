# Mtdt

## Synopsis

Specification and deployment tooling for `.mtdt.yaml` — per-repository
metadata used to sync forge settings and to materialise files such as
`license.txt` / `CONTRIBUTING.md`.

This repository does **not** embed shared config snippets (that is dia).

## Layout

```
docs/spec.md           schema and purpose
scripts/               deployers and GitHub sync helpers
templates/license/     license text templates
templates/contributing/ contributing templates
```

## Scripts

| Script | Role |
|--------|------|
| `update-gh-repo-descriptions.sh` | Push `project.description` via `gh repo edit` |
| `update-gh-repo-visibility.sh` | Push `project.github.visibility` |
| `update-gh-repo-names.sh` | Prompt when local directory name ≠ GitHub name |
| `deploy-license.sh` | Render `license.txt` from `project.license` |
| `deploy-contributing.sh` | Render `CONTRIBUTING.md` from template + mtdt |
| `validate-mtdt.sh` | Basic structural checks on `.mtdt.yaml` |
| `init-mtdt.sh` | Scaffold a new `.mtdt.yaml` with a fresh UUID |

All directory-walking scripts accept one or more roots (default: `.`).
`init-mtdt.sh` takes an optional target directory (default: `.`).

### Further ideas (not implemented)

- `update-gh-repo-homepage.sh` — sync `project.homepage` / topics from `tags`
- `diff-gh-mtdt.sh` — show drift between `.mtdt.yaml` and live `gh repo view`
- `deploy-citation.sh` — emit `CITATION.cff` from authors + name + year

## Dependencies

- `yq` (YAML queries)
- `gh` (GitHub CLI) for the `update-gh-*` scripts
- POSIX `sh`

## Origin notes

- Spec adapted from a former Synerga scaffold note (removed after import)
- GitHub sync scripts relocated from `shell-scripts` wiring (removed after import)

## Colophon

**Author:** [kvn-dtrx](https://github.com/kvn-dtrx)

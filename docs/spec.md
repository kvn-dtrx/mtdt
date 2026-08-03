# ---
title: .mtdt.yaml specification
category: MINT
created: 2025-08-31
updated: 2026-08-04
---

---

## Purpose

`.mtdt.yaml` is the per-repository metadata descriptor and source of truth for
project identity, licensing, and forge settings. Tools in this repository
deploy files (e.g. `LICENSE`) and sync remote forge settings from it.

It is intentionally separate from snippet embedding (dia).

Companion files:

| File | Role |
|------|------|
| [`example.mtdt.yaml`](example.mtdt.yaml) | Commented illustration of a filled file |
| [`../templates/mtdt.yaml`](../templates/mtdt.yaml) | Blank scaffold (`init-mtdt`; copy by hand) |

## Document shape

Exactly two required top-level keys, in this order:

1. `project` — identity and license of the work
2. `forges` — hosting platforms and their repo settings

No other top-level keys are defined. Unknown keys should be rejected by
validators once tooling covers them; today `validate-mtdt` only flags
legacy `project.github` and `subtrees`.

## `project`

Fixed key order:

`id` → `name` → `description` → `authors` → `license`

| Key | Type | Rules |
|-----|------|--------|
| `id` | string (UUID) | Required; stable unique id |
| `name` | string | Required; human-readable project name |
| `description` | string \| null | Prefer folded scalar `>-`; sentence case; no trailing full stop |
| `authors` | list of maps | Required; non-empty. Each entry: `name` (required), `mail`, optional `role` |
| `license` | null \| map | `null` = no license deployment |

### `project.license` (when not null)

| Key | Type | Rules |
|-----|------|--------|
| `type` | string | SPDX-ish id used to select `templates/license/*` (e.g. `MIT`, `Apache-2.0`, `ISC`) |
| `year` | int \| string \| list of int | See year forms below |
| `copyright-owner` | string \| list | Optional; default = author names joined |
| `file` | string | Optional output path; default `LICENSE` |

Year forms:

- single integer — `2026`
- inclusive interval string — `2022-2024`
- discrete list — `[2025, 2026]`

## `forges`

Map keyed by lowercase host id (`github`, `gitlab`, …). Hosts are optional
individually; omit a host if unused. Entry field order: `url` → `visibility`.

| Key | Type | Rules |
|-----|------|--------|
| `url` | string \| null | Canonical repo URL on that host |
| `visibility` | `public` \| `private` \| `internal` \| null | Forge visibility; `null` skips sync |

Current sync scripts read `forges.github` only (`gh`). Additional hosts are
schema-valid for declaration; tooling may ignore them until implemented.

## Relation to `pyproject.toml`

When both files exist, `.mtdt.yaml` remains authoritative for identity.
`flush-pyproject` patches an *existing* `pyproject.toml` only:

- `project.description`
- `project.authors` (`mail` → `email`)
- `project.license` as `{ file = … }` when `license.file` is set, or when
  pyproject has no license yet (default `LICENSE`)
- `project.urls.Source` from `forges.github.url`

It does not create `pyproject.toml`, and does not touch distribution `name`,
`version`, dependencies, or `[tool.*]`.

## Non-goals

- Snippet libraries and marker embedding
- Local projects tree / editor workspaces
- Git hook installation
- Owning packaging metadata (version, deps, entry points)
- Git subtree / local remote orchestration

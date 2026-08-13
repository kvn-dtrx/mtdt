# ---
title: .mtdt.yaml specification
created: 2025-08-31
---

---

# Purpose

`.mtdt.yaml` is the per-repository metadata descriptor and source of truth for
project identity, licensing, and **canonical** forge settings — written from the
**owner / upstream** viewpoint of the work. Tools deploy files (e.g. `LICENSE`)
and sync forge settings from it.

Clone-specific forge overlays (typical: a personal fork URL) are **not**
versioned in the project repo. They are catalogued centrally in private
meta-project-annex (`src/mtdt/forks.yaml`, keyed by `project.id`) and
materialised as `.mtdt.local.yaml` by meta-project's `deploy-mtdt-local`.
`resolve-mtdt` merges that overlay (forges only). Env secret *pointers* live
in the same annex (`src/mtdt/env-plans.yaml` → meta `deploy-env-plans`);
values stay in krypta / XDG phrase files.

It is intentionally separate from snippet embedding (dia).

Companion files:

| File | Role |
| --- | --- |
| [`example.mtdt.yaml`](example.mtdt.yaml) | Commented illustration of a filled file |
| [`../share/templates/mtdt.yaml`](../share/templates/mtdt.yaml) | Blank scaffold (`init-mtdt`; copy by hand) |

## Document shape

Exactly two required top-level keys, in this order:

1. `project` — identity and license of the work
2. `forges` — hosting platforms and their repo settings

No other top-level keys are defined. Unknown keys should be rejected by
validators once tooling covers them; today `validate-mtdt` only flags
legacy `project.github` and `subtrees`.

## `.mtdt.local.yaml` (optional, untracked)

Same directory as `.mtdt.yaml`. **Only** top-level `forges:` is allowed; entries
deep-merge over the base (local host fields win). Ignore the file in git.

Source of truth for known forks: private meta-project-annex
`src/mtdt/forks.yaml` → meta `deploy-mtdt-local` (env `MTDT_FORKS_FILE` /
`META_PROJECT_ANNEX` / `META_PROJECT`). Env plans: annex
`src/mtdt/env-plans.yaml` → `deploy-env-plans` (`MTDT_ENV_PLANS_FILE`).

| Consumer | Uses |
| --- | --- |
| `deploy-license`, `deploy-contributing`, `flush-pyproject`, dirname checks | base `.mtdt.yaml` only |
| `validate-mtdt` (forge warnings), `check-forge-push`, `update-gh-repo-visibility`, `check-mtdt-remotes` | effective / split base↔local as documented per tool |
| meta `deploy-mtdt-local` | annex forks catalog → working-tree `.mtdt.local.yaml` |
| meta `deploy-env-plans` | annex env-plans catalog → checkout `.env` keys (values via `retrieve-envvar`) |

`split-mtdt-forks` detects GitHub forks and moves the fork URL into local while
pointing the base `forges.github.url` at the upstream parent (also add the
entry to meta-project `forks.yaml`).

`check-mtdt-remotes` checks that split against git remotes (exit 1 on drift);
`--fix` applies `git remote add` / `set-url` / `remove`. Identity compares
HTTPS and SSH as equal; the written URL scheme comes from gitconfig:

1. `mtdt.githubProtocol` = `ssh` | `https` (repo or global), else
2. `url.<base>.insteadOf` mapping between `https://github.com/` and
   `git@github.com:` / `ssh://git@github.com/`, else
3. leave the URL form from `.mtdt.yaml` / `.mtdt.local.yaml` as-is

- own project (no distinct local URL): `origin` ← base; drop `upstream` if present
- fork (local URL ≠ base): `origin` ← local; `upstream` ← base

# `project`

Fixed key order:

`id` → `name` → `description` → `authors` → `license`

| Key | Type | Rules |
| --- | --- | --- |
| `id` | string (UUID) | Required; stable unique id |
| `name` | string | Required; human-readable project name (see local slug below) |
| `description` | string \| null | Prefer folded scalar `>-`; sentence case; no trailing full stop |
| `authors` | list of maps | Required; non-empty. Each entry: `name` (required), `mail`, optional `role` |
| `license` | null \| map | `null` = no license deployment (omit license file). Fine for private/WIP; `validate-mtdt` warns (non-fatal) when any forge is `public` |

## `project.license` (when not null)

| Key | Type | Rules |
| --- | --- | --- |
| `type` | string | Selects `share/templates/license/*`. Known: `MIT`, `ISC`, `Apache-2.0`, `GPL-3.0`, `WTFPL` (joke/public-domain-ish), `proprietary` (all-rights-reserved stub). Aliases: `ARR`, `all-rights-reserved` → proprietary |
| `year` | int \| string \| list of int | See year forms below |
| `copyright-owner` | string \| list | Optional; default = author names joined |
| `file` | string | Optional output path; default `LICENSE.txt` |

Year forms:

- single integer — `2026`
- inclusive interval string — `2022-2024`
- discrete list — `[2025, 2026]`

## Local directory slug (derived, not stored)

Do **not** add `project.slug` to `.mtdt.yaml`. The local repository directory
basename should equal the slug derived from `project.name` by
`derive-project-slug` / `check-project-dirname`.

Algorithm (normative):

1. Trim leading/trailing whitespace.
2. If the name ends with `.github.io` (case-insensitive), remember that suffix
   and strip it for the following steps (GitHub Pages repos keep the literal
   suffix on the directory).
3. Replace every `: ` (colon + space) with `_` — e.g. `DA Project: Artsy` →
   directory `da-project_artsy`.
4. Replace `.` between two lowercase letters with `-` (e.g. `Reveal.js` →
   `Reveal-js`).
5. Remove any remaining `.` (abbreviations such as `B.Sc.` → `BSc`).
6. Replace runs of whitespace with `-`.
7. Drop every character outside `[A-Za-z0-9_-]`.
8. Lowercase; collapse repeated `-`; strip leading/trailing `-` / `_`.
9. Re-attach `.github.io` when step 2 applied.

Implications for `project.name`:

- Put word breaks in the display name (spaces or hyphens). CamelCase alone does
  not invent hyphens (`IllInvList` → `illinvlist`; prefer `Ill Inv List`).
- Prefer a **short** identity name when the directory should stay short; put
  long titles in `description` (or document body), not in `name`.
- Years in the directory come from the name as written (`Bewerbungen 2021` →
  `bewerbungen-2021`, not from expanding `21`).
- Forge / GitHub repo names are taken from the last path segment of
  `forges.*.url` (not a separate field). Prefer that they equal the derived
  local slug; `validate-mtdt` warns on mismatch. `update-gh-repo-names`
  renames the live GitHub repo toward that slug by default (`--dirname`
  keeps the old basename-as-authority behavior).

# `forges`

Map keyed by lowercase host id (`github`, `gitlab`, …). Hosts are optional
individually; omit a host if unused. Entry field order: `url` → `visibility`.

| Key | Type | Rules |
| --- | --- | --- |
| `url` | string \| null | Canonical repo URL on that host |
| `visibility` | `public` \| `private` \| `internal` \| null | Forge visibility; `null` skips sync |

Current sync scripts read `forges.github` only (`gh`). Additional hosts are
schema-valid for declaration; tooling may ignore them until implemented.

# Relation to `pyproject.toml`

When both files exist, `.mtdt.yaml` remains authoritative for identity.
`flush-pyproject` patches an *existing* `pyproject.toml` only:

- `project.description`
- `project.authors` (`mail` → `email`)
- `project.license` as `{ file = … }` when `license.file` is set, or when
  pyproject has no license yet (default `LICENSE.txt`)
- `project.urls.Source` from base `forges.github.url` (not the local overlay)

It does not create `pyproject.toml`, and does not touch distribution `name`,
`version`, dependencies, or `[tool.*]`.

# Non-goals

- Snippet libraries and marker embedding
- Local projects tree / editor workspaces
- Git hook installation
- Owning packaging metadata (version, deps, entry points)
- Git subtree / local remote orchestration
- Storing fork remotes in the versioned `.mtdt.yaml`

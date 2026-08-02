# ---
title: .mtdt.yaml
category: MINT
created: 2025-08-31
updated: 2026-08-02
---

---

## Purpose

`.mtdt.yaml` is a per-repository metadata descriptor. It is the source of truth
for project identity (name, description, authors), licensing, and forge
settings (GitHub/GitLab). Tools in this repository read it to deploy files
(e.g. `LICENSE`) and to sync remote repository settings.

It is intentionally separate from snippet embedding (dia): consumers who only
want metadata deployment need not adopt marker-based resource pulls.

## Schema

Key order under `project:` is fixed:

`id` → `name` → `description` → `authors` → `license` → `github`

```yaml
project:
  # Unique project identifier (UUID)
  id: "<PROJECT_ID>"
  # Human-readable project name
  name: "<PROJECT_NAME>"
  # Brief description; prefer YAML folded style >-
  description: >-
    <SHORT_DESCRIPTION>
  authors:
    - name: "<AUTHOR_NAME>"
      mail: "<EMAIL_OR_NULL>"
      # Optional: maintainer, contributor, …
      role: "<ROLE_OR_NULL>"
  # null if the project has no declared license
  license: null
  # or:
  # license:
  #   type: MIT            # e.g. MIT, Apache-2.0, ISC
  #   year: 2025           # int
  #   # year: 2022-2024    # inclusive interval (string)
  #   # year: [2001, 2042] # discrete years (list)
  #   # copyright-owner:   # optional override; default = author names
  #   # file: LICENSE      # optional output path; default LICENSE
  github:
    url: "<GITHUB_URL_OR_NULL>"
    visibility: "<public|private|internal|null>"
  # Optional forge / discovery fields (not required by current scripts):
  # gitlab:
  #   url: "<GITLAB_URL>"
  #   visibility: "<public|private|internal>"
  # homepage: "<HOMEPAGE_URL>"
  # tags: ["latex", "template"]
  # version: "0.1.0"

# Only when the repository uses git subtrees — stays a sibling of project:,
# never folded into project:
subtrees:
  - path: docs
    remote: docs
    branch: main
    description: >-
      Documentation subtree
    github: git@github.com:example/docs.git
```

## Conventions

- Description: sentence case, no trailing full stop; YAML scalar `>-`.
- `license: null` means “no license deployment”; omit forge sync side effects
  that depend on license content.
- Year forms: single integer, interval string `START-END`, or list of integers.
- `subtrees` is top-level beside `project`, never inside it.

## Non-goals

- Snippet libraries and marker embedding (see dia / dia-resources).
- Local projects tree / editor workspaces (see meta-project).
- Git hook installation (separate concern).

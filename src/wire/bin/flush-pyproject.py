#!/usr/bin/env python3
# ---
# description: >-
#   Flushes overlapping identity fields from .mtdt.yaml into an existing
#   pyproject.toml (PEP 621): description, authors, license.file (when set or
#   missing), urls.Source. Skips repos without pyproject.toml. Does not touch
#   name, version, or deps.
# ---

# ---

from __future__ import annotations

import argparse
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("flush-pyproject requires PyYAML\n")
    raise SystemExit(1) from exc

try:
    import tomlkit
    from tomlkit.items import Table
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("flush-pyproject requires tomlkit\n")
    raise SystemExit(1) from exc


DEFAULT_LICENSE_FILE = "LICENSE.txt"


def load_mtdt(path: Path) -> dict:
    """Return the full .mtdt.yaml mapping (must include top-level project:)."""
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or "project" not in data:
        raise ValueError(f"{path}: missing top-level project:")
    project = data["project"]
    if not isinstance(project, dict):
        raise ValueError(f"{path}: project: must be a mapping")
    return data


def license_file_rel(project: dict) -> str | None:
    """Return mtdt license.file when explicitly set; else None (caller decides)."""
    license_ = project.get("license")
    if license_ is None or not isinstance(license_, dict):
        return None
    if not license_.get("type"):
        return None
    out = license_.get("file")
    if isinstance(out, str) and out.strip():
        return out.strip()
    return None


def authors_pep621(project: dict) -> list[dict[str, str]]:
    raw = project.get("authors") or []
    if not isinstance(raw, list):
        return []
    out: list[dict[str, str]] = []
    for entry in raw:
        if not isinstance(entry, dict):
            continue
        name = entry.get("name")
        if not name:
            continue
        item: dict[str, str] = {"name": str(name)}
        mail = entry.get("mail")
        if mail and mail != "null":
            item["email"] = str(mail)
        out.append(item)
    return out


def ensure_table(parent: Table, key: str) -> Table:
    existing = parent.get(key)
    if isinstance(existing, Table):
        return existing
    table = tomlkit.table()
    parent[key] = table
    return table


def _normalize_authors(value: object) -> list[tuple[str | None, str | None]]:
    if value is None:
        return []
    out: list[tuple[str | None, str | None]] = []
    try:
        for item in value:  # type: ignore[union-attr]
            out.append((item.get("name"), item.get("email")))  # type: ignore[union-attr]
    except (TypeError, AttributeError):
        return []
    return out


def _license_file_in_pyproject(proj: Table) -> str | None:
    old = proj.get("license")
    if isinstance(old, Table):
        file = old.get("file")
        return str(file) if file else None
    if isinstance(old, dict):
        file = old.get("file")
        return str(file) if file else None
    return None


def flush_document(doc: tomlkit.TOMLDocument, mtdt: dict) -> list[str]:
    """Apply overlapping fields; return list of changed keys."""
    changed: list[str] = []
    project = mtdt["project"]
    proj = ensure_table(doc, "project")

    description = project.get("description")
    if isinstance(description, str) and description.strip():
        # Folded YAML may leave trailing newline; PEP 621 is a single line/string
        text = " ".join(description.split())
        if proj.get("description") != text:
            proj["description"] = text
            changed.append("project.description")

    authors = authors_pep621(project)
    if authors:
        old_norm = _normalize_authors(proj.get("authors"))
        new_norm = [(a["name"], a.get("email")) for a in authors]
        if old_norm != new_norm:
            arr = tomlkit.array()
            arr.multiline(True)
            for author in authors:
                table = tomlkit.inline_table()
                table["name"] = author["name"]
                if "email" in author:
                    table["email"] = author["email"]
                arr.append(table)
            proj["authors"] = arr
            changed.append("project.authors")

    # License: only write when mtdt sets license.file, or pyproject has no license
    # yet (then default LICENSE.txt, matching deploy-license). Never clobber an
    # existing file= path with the default.
    lic_explicit = license_file_rel(project)
    license_meta = project.get("license")
    has_type = (
        isinstance(license_meta, dict)
        and bool(license_meta.get("type"))
    )
    if has_type:
        existing = _license_file_in_pyproject(proj)
        target = lic_explicit
        if target is None and existing is None:
            target = DEFAULT_LICENSE_FILE
        if target is not None and target != existing:
            lic = tomlkit.inline_table()
            lic["file"] = target
            proj["license"] = lic
            changed.append("project.license")

    forges = mtdt.get("forges") or {}
    github = forges.get("github") if isinstance(forges, dict) else None
    if isinstance(github, dict):
        url = github.get("url")
        if isinstance(url, str) and url.strip() and url != "null":
            urls = ensure_table(proj, "urls")
            if urls.get("Source") != url:
                urls["Source"] = url
                changed.append("project.urls.Source")

    return changed


def process_repo(mtdt_path: Path, *, dry_run: bool) -> int:
    repo = mtdt_path.parent
    pyproject = repo / "pyproject.toml"
    if not pyproject.is_file():
        return 0

    try:
        mtdt = load_mtdt(mtdt_path)
    except ValueError as exc:
        sys.stderr.write(f"{exc}\n")
        return 1

    text = pyproject.read_text(encoding="utf-8")
    doc = tomlkit.parse(text)
    changed = flush_document(doc, mtdt)
    if not changed:
        print(f"Unchanged {pyproject}")
        return 0

    new_text = tomlkit.dumps(doc)
    if dry_run:
        print(f"Would update {pyproject}: {', '.join(changed)}")
        return 0

    pyproject.write_text(new_text, encoding="utf-8")
    print(f"Updated {pyproject}: {', '.join(changed)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Flush .mtdt.yaml identity fields into existing pyproject.toml files."
        )
    )
    parser.add_argument(
        "-n",
        "--dry-run",
        action="store_true",
        help="show what would change without writing",
    )
    parser.add_argument(
        "roots",
        nargs="*",
        default=["."],
        help="directories to search for .mtdt.yaml (default: .)",
    )
    args = parser.parse_args(argv)

    status = 0
    seen: set[Path] = set()
    for root in args.roots:
        root_path = Path(root).resolve()
        if not root_path.exists():
            sys.stderr.write(f"No such path: {root}\n")
            status = 1
            continue
        paths = (
            [root_path]
            if root_path.is_file() and root_path.name == ".mtdt.yaml"
            else sorted(root_path.rglob(".mtdt.yaml"))
        )
        for mtdt_path in paths:
            mtdt_path = mtdt_path.resolve()
            if mtdt_path in seen:
                continue
            # Skip nested venvs / git metadata
            if any(part in {".git", ".venv", "venv", "node_modules"} for part in mtdt_path.parts):
                continue
            seen.add(mtdt_path)
            status = process_repo(mtdt_path, dry_run=args.dry_run) or status
    return status


if __name__ == "__main__":
    raise SystemExit(main())

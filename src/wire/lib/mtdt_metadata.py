#!/usr/bin/env python3

# ---
# description: >-
#   Shared reading and discovery operations for .mtdt.yaml metadata
# ---

# ---

# --- Imports ---


import copy
import os
from collections.abc import Iterator
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    raise SystemExit("mtdt metadata helpers require PyYAML") from exc

MTDT_BASENAME = ".mtdt.yaml"
LOCAL_BASENAME = ".mtdt.local.yaml"
MISSING = object()
SKIP_DIRS = {".git", ".venv", "__pycache__", "node_modules", "venv"}

# --- Main Code ---


def mtdt_path(value: Path) -> Path:
    path = value.expanduser()
    return path / MTDT_BASENAME if path.is_dir() else path


def load_yaml_mapping(path: Path) -> dict:
    if not path.is_file():
        raise FileNotFoundError(path)
    try:
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise ValueError(f"{path}: invalid YAML: {exc}") from exc
    if data is None:
        return {}
    if not isinstance(data, dict):
        raise ValueError(f"{path}: root must be a mapping")
    return data


def _merge_forges(base: object, overlay: object) -> dict:
    current = base if isinstance(base, dict) else {}
    if not isinstance(overlay, dict):
        return copy.deepcopy(current)
    merged_forges: dict = copy.deepcopy(current)
    for host, entry in overlay.items():
        if not isinstance(entry, dict):
            merged_forges[host] = copy.deepcopy(entry)
            continue
        current_entry = merged_forges.get(host)
        if isinstance(current_entry, dict):
            merged_entry = copy.deepcopy(current_entry)
            merged_entry.update(entry)
            merged_forges[host] = merged_entry
        else:
            merged_forges[host] = copy.deepcopy(entry)
    return merged_forges


def load_metadata(value: Path, *, effective: bool = False) -> dict:
    path = mtdt_path(value)
    base = load_yaml_mapping(path)
    if not effective:
        return base

    local_path = path.parent / LOCAL_BASENAME
    if not local_path.is_file():
        return base
    local = load_yaml_mapping(local_path)
    unexpected = sorted(str(key) for key in local if key != "forges")
    if unexpected:
        raise ValueError(
            f"{local_path}: only top-level forges: allowed "
            f"(found: {', '.join(unexpected)})"
        )
    if "forges" in local:
        base = copy.deepcopy(base)
        base["forges"] = _merge_forges(base.get("forges"), local.get("forges"))
    return base


def get_property(data: dict, dotted_path: str) -> object:
    parts = dotted_path.split(".")
    if not dotted_path or any(not part for part in parts):
        raise ValueError(f"invalid property path: {dotted_path!r}")
    current: object = data
    for part in parts:
        if not isinstance(current, dict) or part not in current:
            return MISSING
        current = current[part]
    return current


def project_id(value: Path) -> str | None:
    raw = get_property(load_metadata(value), "project.id")
    if raw is MISSING or raw is None:
        return None
    text = str(raw).strip()
    return text if text and text != "null" else None


def iter_mtdt_files(roots: list[Path]) -> Iterator[Path]:
    for root in roots:
        root = root.expanduser()
        if root.is_file():
            if root.name.lower() == MTDT_BASENAME:
                yield root
            continue
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
            for name in sorted(filenames):
                if name.lower() == MTDT_BASENAME:
                    yield Path(dirpath) / name


def iter_projects(roots: list[Path]) -> Iterator[tuple[Path, str]]:
    seen: set[Path] = set()
    for path in iter_mtdt_files(roots):
        directory = path.parent.resolve()
        if directory in seen:
            continue
        seen.add(directory)
        found = project_id(path)
        if found is not None:
            yield directory, found

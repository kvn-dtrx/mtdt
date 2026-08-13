#!/usr/bin/env python3

# ---
# description: >-
#   Resolves effective mtdt metadata: .mtdt.yaml with optional .mtdt.local.yaml
#   overlay. Local may only override forges: (deep-merge per host). Writes
#   merged YAML to stdout. Without a local file, echoes the base file bytes.
# ---

# ---

from __future__ import annotations

import argparse
import copy
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("resolve-mtdt requires PyYAML\n")
    raise SystemExit(1) from exc

LOCAL_NAME = ".mtdt.local.yaml"


def _merge_forges(base: object, overlay: object) -> dict:
    if not isinstance(base, dict):
        base = {}
    if not isinstance(overlay, dict):
        return copy.deepcopy(base)
    out: dict = copy.deepcopy(base)
    for host, entry in overlay.items():
        if not isinstance(entry, dict):
            out[host] = copy.deepcopy(entry)
            continue
        cur = out.get(host)
        if isinstance(cur, dict):
            merged = copy.deepcopy(cur)
            merged.update(entry)
            out[host] = merged
        else:
            out[host] = copy.deepcopy(entry)
    return out


def resolve(base_path: Path) -> tuple[dict | None, str | None]:
    """Return (merged_mapping, raw_base_text_if_no_local)."""
    if not base_path.is_file():
        raise FileNotFoundError(base_path)
    raw = base_path.read_text(encoding="utf-8")
    local_path = base_path.parent / LOCAL_NAME
    if not local_path.is_file():
        return None, raw

    base = yaml.safe_load(raw)
    if not isinstance(base, dict):
        raise ValueError(f"{base_path}: root must be a mapping")

    local = yaml.safe_load(local_path.read_text(encoding="utf-8"))
    if local is None:
        local = {}
    if not isinstance(local, dict):
        raise ValueError(f"{local_path}: root must be a mapping")

    unexpected = sorted(k for k in local if k != "forges")
    if unexpected:
        raise ValueError(
            f"{local_path}: only top-level forges: allowed "
            f"(found: {', '.join(unexpected)})"
        )

    if "forges" in local:
        base = copy.deepcopy(base)
        base["forges"] = _merge_forges(base.get("forges"), local.get("forges"))
    return base, None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Merge .mtdt.yaml with optional .mtdt.local.yaml (forges: only) "
            "and print effective YAML."
        )
    )
    parser.add_argument(
        "mtdt",
        type=Path,
        help="path to .mtdt.yaml",
    )
    args = parser.parse_args(argv)

    try:
        merged, raw = resolve(args.mtdt.resolve())
    except (OSError, ValueError, yaml.YAMLError) as exc:
        sys.stderr.write(f"{exc}\n")
        return 1

    if raw is not None:
        sys.stdout.write(raw)
        if raw and not raw.endswith("\n"):
            sys.stdout.write("\n")
        return 0

    yaml.safe_dump(
        merged,
        sys.stdout,
        sort_keys=False,
        allow_unicode=True,
        default_flow_style=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

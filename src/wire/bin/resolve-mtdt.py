#!/usr/bin/env python3

# ---
# description: >-
#   Resolves effective mtdt metadata: .mtdt.yaml with optional .mtdt.local.yaml
#   overlay. Local may only override forges: (deep-merge per host). Writes
#   merged YAML to stdout. Without a local file, echoes the base file bytes.
# ---

# ---


import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("resolve-mtdt requires PyYAML\n")
    raise SystemExit(1) from exc

_WIRE_LIB_RAW = os.environ.get("WIRE_LIB", "").strip()
_LIB = (
    Path(_WIRE_LIB_RAW).expanduser()
    if _WIRE_LIB_RAW
    else Path(__file__).resolve().parents[1] / "lib"
)
sys.path.insert(0, str(_LIB))

from mtdt_metadata import LOCAL_BASENAME, load_metadata  # noqa: E402


def resolve(base_path: Path) -> tuple[dict | None, str | None]:
    """Return (merged_mapping, raw_base_text_if_no_local)."""
    if not base_path.is_file():
        raise FileNotFoundError(base_path)
    raw = base_path.read_text(encoding="utf-8")
    local_path = base_path.parent / LOCAL_BASENAME
    if not local_path.is_file():
        return None, raw
    return load_metadata(base_path, effective=True), None


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

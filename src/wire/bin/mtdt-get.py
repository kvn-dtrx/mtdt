#!/usr/bin/env python3

# ---
# description: >-
#   Reads one dotted property from base or effective mtdt metadata
# ---

# ---

# --- Imports ---


import argparse
import json
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("mtdt-get requires PyYAML\n")
    raise SystemExit(1) from exc

_WIRE_LIB_RAW = os.environ.get("WIRE_LIB", "").strip()
_LIB = (
    Path(_WIRE_LIB_RAW).expanduser()
    if _WIRE_LIB_RAW
    else Path(__file__).resolve().parents[1] / "lib"
)
sys.path.insert(0, str(_LIB))

from mtdt_metadata import MISSING, get_property, load_metadata  # noqa: E402

# --- Auxiliary Code ---


def write_raw(value: object) -> bool:
    if isinstance(value, (dict, list)):
        return False
    if value is None:
        text = "null"
    elif isinstance(value, bool):
        text = "true" if value else "false"
    else:
        text = str(value)
    sys.stdout.write(text)
    if not text.endswith("\n"):
        sys.stdout.write("\n")
    return True


# --- Main Code ---


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Read a dotted property from .mtdt.yaml."
    )
    parser.add_argument(
        "--effective",
        action="store_true",
        help="merge the local forge overlay before querying",
    )
    parser.add_argument(
        "--format",
        choices=("raw", "json", "yaml"),
        default="raw",
        help="output format (default: raw; collections require json or yaml)",
    )
    parser.add_argument("property", help="dotted mapping path, e.g. project.id")
    parser.add_argument("path", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)

    try:
        value = get_property(
            load_metadata(args.path, effective=args.effective),
            args.property,
        )
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    if value is MISSING:
        print(f"{args.path}: missing property {args.property}", file=sys.stderr)
        return 1

    if args.format == "raw":
        if write_raw(value):
            return 0
        print(
            f"{args.property} is a collection; use --format json or --format yaml",
            file=sys.stderr,
        )
        return 2
    if args.format == "json":
        json.dump(value, sys.stdout, ensure_ascii=False, indent=2)
        sys.stdout.write("\n")
        return 0
    yaml.safe_dump(value, sys.stdout, allow_unicode=True, sort_keys=False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

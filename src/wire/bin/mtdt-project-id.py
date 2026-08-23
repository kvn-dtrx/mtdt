#!/usr/bin/env python3

# ---
# description: >-
#   Prints project.id from a project directory or .mtdt.yaml file
# ---

# ---

# --- Imports ---


import argparse
import os
import sys
from pathlib import Path

_WIRE_LIB_RAW = os.environ.get("WIRE_LIB", "").strip()
_LIB = (
    Path(_WIRE_LIB_RAW).expanduser()
    if _WIRE_LIB_RAW
    else Path(__file__).resolve().parents[1] / "lib"
)
sys.path.insert(0, str(_LIB))

from mtdt_metadata import project_id  # noqa: E402

# --- Main Code ---


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", nargs="?", type=Path, default=Path.cwd())
    args = parser.parse_args()
    try:
        found = project_id(args.path)
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    if found is None:
        print(f"{args.path}: missing project.id", file=sys.stderr)
        return 1
    print(found)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

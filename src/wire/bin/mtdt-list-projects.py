#!/usr/bin/env python3

# ---
# description: >-
#   Lists mtdt projects as project.id and checkout path TSV records
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

from mtdt_metadata import iter_projects  # noqa: E402

# --- Main Code ---


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="*", type=Path, default=[Path.cwd()])
    args = parser.parse_args()
    try:
        for directory, project_id in iter_projects(args.roots):
            print(f"{project_id}\t{directory}")
    except (OSError, ValueError) as exc:
        print(exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

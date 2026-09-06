#!/usr/bin/env python3

# ---
# description: >-
#   Derives the local repository directory slug from a project display name
#   (stdin and/or arguments). Normative rules: docs/spec.md
# ---

# ---


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

from mtdt_slug import project_slug  # noqa: E402


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Derive local repo directory slug from project display name(s)."
    )
    parser.add_argument(
        "names",
        nargs="*",
        help="display name(s); if omitted, read non-empty lines from stdin",
    )
    args = parser.parse_args(argv)

    if args.names:
        sources = args.names
    else:
        sources = [line.rstrip("\n") for line in sys.stdin if line.strip()]

    if not sources:
        print("derive-project-slug: no input name(s)", file=sys.stderr)
        return 2

    for name in sources:
        print(project_slug(name))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

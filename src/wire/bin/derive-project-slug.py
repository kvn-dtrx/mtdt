#!/usr/bin/env python3

# ---
# description: >-
#   Derives the local repository directory slug from a project display name
#   (stdin and/or arguments). Normative rules: docs/spec.md
# ---

# ---

from __future__ import annotations

import argparse
import re
import sys

_GITHUB_IO = ".github.io"


def project_slug(name: str) -> str:
    """Derive local directory slug from project.name (see docs/spec.md)."""
    s = name.strip()
    if not s:
        return ""

    github_io = s.lower().endswith(_GITHUB_IO)
    if github_io:
        s = s[: -len(_GITHUB_IO)]

    # Title subtitle split used in several archived project names
    s = s.replace(": ", "_")

    # product.suffix (e.g. Reveal.js) → product-suffix; keep abbreviation dots for strip
    s = re.sub(r"(?<=[a-z])\.(?=[a-z])", "-", s)

    # Remaining dots (B.Sc., …) drop — not directory separators
    s = s.replace(".", "")

    s = re.sub(r"\s+", "-", s)
    s = re.sub(r"[^a-zA-Z0-9_-]+", "", s)
    s = s.lower()
    s = re.sub(r"-{2,}", "-", s)
    s = re.sub(r"^[-_]+|[-_]+$", "", s)

    if github_io:
        s = f"{s}{_GITHUB_IO}"
    return s


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

#!/usr/bin/env python3

"""Repository slug derivation shared by mtdt commands."""

import re

_GITHUB_IO = ".github.io"


def project_slug(name: str) -> str:
    """Derive the repository slug from project.name (see docs/spec.md)."""
    slug = name.strip()
    if not slug:
        return ""

    github_io = slug.lower().endswith(_GITHUB_IO)
    if github_io:
        slug = slug[: -len(_GITHUB_IO)]

    slug = slug.replace(": ", "_")
    slug = re.sub(r"(?<=[a-z])\.(?=[a-z])", "-", slug)
    slug = slug.replace(".", "")
    slug = re.sub(r"\s+", "-", slug)
    slug = re.sub(r"[^a-zA-Z0-9_-]+", "", slug)
    slug = slug.lower()
    slug = re.sub(r"-{2,}", "-", slug)
    slug = re.sub(r"^[-_]+|[-_]+$", "", slug)

    if github_io:
        slug = f"{slug}{_GITHUB_IO}"
    return slug

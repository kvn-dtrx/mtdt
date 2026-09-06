#!/usr/bin/env python3

# ---
# description: >-
#   Synchronises GitLab project descriptions, names, and visibility from
#   effective mtdt metadata
# ---


import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import quote, urlsplit

_WIRE_LIB_RAW = os.environ.get("WIRE_LIB", "").strip()
_LIB = (
    Path(_WIRE_LIB_RAW).expanduser()
    if _WIRE_LIB_RAW
    else Path(__file__).resolve().parents[1] / "lib"
)
sys.path.insert(0, str(_LIB))

from mtdt_metadata import iter_mtdt_files, load_metadata  # noqa: E402
from mtdt_slug import project_slug  # noqa: E402

_SCP_URL = re.compile(r"^git@(?P<host>[^:]+):(?P<path>.+)$")
_VISIBILITIES = {"public", "private", "internal"}


def forge_path(url: str) -> tuple[str, str]:
    """Return hostname and namespace/project from an SSH or HTTP forge URL."""
    raw = url.strip()
    scp_match = _SCP_URL.fullmatch(raw)
    if scp_match is not None:
        host = scp_match.group("host")
        path = scp_match.group("path")
    else:
        parsed = urlsplit(raw)
        if parsed.scheme not in {"http", "https", "ssh"} or not parsed.hostname:
            raise ValueError(f"unsupported forge URL: {url!r}")
        if parsed.query or parsed.fragment:
            raise ValueError(f"forge URL must not contain query or fragment: {url!r}")
        host = parsed.hostname
        path = parsed.path.lstrip("/")

    path = path.rstrip("/")
    if path.endswith(".git"):
        path = path[:-4]
    if len(path.split("/")) < 2 or any(not part for part in path.split("/")):
        raise ValueError(f"forge URL must identify namespace/project: {url!r}")
    return host.lower(), path


def gitlab_project(metadata: dict) -> tuple[str, str] | None:
    """Resolve GitLab target, deriving it from effective GitHub when absent."""
    forges = metadata.get("forges")
    if not isinstance(forges, dict):
        return None

    gitlab = forges.get("gitlab")
    if isinstance(gitlab, dict):
        gitlab_url = gitlab.get("url")
        if isinstance(gitlab_url, str) and gitlab_url.strip():
            return forge_path(gitlab_url)

    github = forges.get("github")
    if not isinstance(github, dict):
        return None
    github_url = github.get("url")
    if github_url is None or github_url == "":
        return None
    if not isinstance(github_url, str):
        raise ValueError("forges.github.url must be a string or null")
    host, path = forge_path(github_url)
    if host != "github.com":
        raise ValueError(f"cannot derive GitLab project from GitHub host {host!r}")
    return "gitlab.com", path


def desired_visibility(metadata: dict) -> str | None:
    forges = metadata.get("forges")
    if not isinstance(forges, dict):
        return None
    gitlab = forges.get("gitlab")
    if isinstance(gitlab, dict) and "visibility" in gitlab:
        raw = gitlab.get("visibility")
    else:
        github = forges.get("github")
        raw = github.get("visibility") if isinstance(github, dict) else None
    if raw is None or raw == "":
        return None
    if not isinstance(raw, str) or raw not in _VISIBILITIES:
        raise ValueError(
            f"GitLab visibility must be public, private, internal, or null: {raw!r}"
        )
    return raw


def run_glab(
    project_dir: Path, hostname: str, api_id: str, *args: str
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["glab", "api", f"projects/{api_id}", "--hostname", hostname, *args],
        cwd=project_dir,
        check=False,
        capture_output=True,
        text=True,
    )


def live_project(project_dir: Path, hostname: str, path: str) -> tuple[dict, str]:
    api_id = quote(path, safe="")
    result = run_glab(project_dir, hostname, api_id, "--output", "json")
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        raise RuntimeError(f"glab cannot read {hostname}/{path}: {detail}")
    try:
        project = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"glab returned invalid JSON for {hostname}/{path}") from exc
    if not isinstance(project, dict):
        raise RuntimeError(f"glab returned no project object for {hostname}/{path}")
    return project, api_id


def update_project(
    project_dir: Path,
    hostname: str,
    api_id: str,
    fields: dict[str, str],
) -> None:
    arguments = ["--method", "PUT", "--silent"]
    for key, value in fields.items():
        arguments.extend(("--raw-field", f"{key}={value}"))
    result = run_glab(project_dir, hostname, api_id, *arguments)
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit status {result.returncode}"
        raise RuntimeError(detail)


def confirm_rename(path: str, target: str) -> bool:
    try:
        with open("/dev/tty", "r+", encoding="utf-8") as terminal:
            terminal.write(f"Rename GitLab project to '{target}'? [y/N] ")
            terminal.flush()
            answer = terminal.readline().strip()
    except OSError:
        print(f"SKIP {path}: no tty for rename confirmation", file=sys.stderr)
        return False
    return answer.lower().startswith("y")


def sync_project(
    subject: str,
    project_dir: Path,
    metadata: dict,
    *,
    yes: bool,
) -> str:
    target = gitlab_project(metadata)
    if target is None:
        return "skipped"
    hostname, path = target
    live, api_id = live_project(project_dir, hostname, path)

    if subject == "descriptions":
        project = metadata.get("project")
        desired = project.get("description") if isinstance(project, dict) else None
        if desired is None or desired == "":
            return "skipped"
        if not isinstance(desired, str):
            raise ValueError("project.description must be a string or null")
        if (live.get("description") or "") == desired:
            return "unchanged"
        update_project(project_dir, hostname, api_id, {"description": desired})
        print(f"UPDATED {hostname}/{path}: description")
        return "updated"

    if subject == "visibility":
        desired = desired_visibility(metadata)
        if desired is None:
            return "skipped"
        if live.get("visibility") == desired:
            return "unchanged"
        current = live.get("visibility") or "unknown"
        update_project(project_dir, hostname, api_id, {"visibility": desired})
        print(f"UPDATED {hostname}/{path}: visibility {current} -> {desired}")
        return "updated"

    project = metadata.get("project")
    display_name = project.get("name") if isinstance(project, dict) else None
    if not isinstance(display_name, str) or not display_name.strip():
        raise ValueError("project.name must be a non-empty string")
    desired = project_slug(display_name)
    if not desired:
        raise ValueError("project.name produced an empty slug")
    current = live.get("path")
    if current == desired:
        return "unchanged"

    print(
        f"Divergence detected ({project_dir}):\n"
        f"  project.name: {display_name}\n"
        f"  GitLab:       {current}\n"
        f"  target:       {desired}"
    )
    if not yes and not confirm_rename(path, desired):
        return "skipped"
    update_project(
        project_dir,
        hostname,
        api_id,
        {"path": desired, "name": desired},
    )
    print(f"UPDATED {hostname}/{path}: renamed to {desired}")
    return "updated"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Synchronise GitLab projects from effective mtdt metadata."
    )
    parser.add_argument("subject", choices=("descriptions", "names", "visibility"))
    parser.add_argument(
        "--yes", action="store_true", help="rename without prompting (names only)"
    )
    parser.add_argument("roots", nargs="*", type=Path, default=[Path.cwd()])
    args = parser.parse_args(argv)

    counts = {"unchanged": 0, "updated": 0, "skipped": 0, "errors": 0}
    for metadata_file in iter_mtdt_files(args.roots):
        project_dir = metadata_file.parent.resolve()
        if not (project_dir / ".git").exists():
            continue
        try:
            metadata = load_metadata(metadata_file, effective=True)
            outcome = sync_project(args.subject, project_dir, metadata, yes=args.yes)
            counts[outcome] += 1
        except (OSError, RuntimeError, ValueError) as exc:
            print(f"ERROR {project_dir}: {exc}", file=sys.stderr)
            counts["errors"] += 1

    print(" ".join(f"{key}={value}" for key, value in counts.items()))
    return 1 if counts["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())

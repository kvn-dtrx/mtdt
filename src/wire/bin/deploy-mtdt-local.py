#!/usr/bin/env python3

# ---
# description: >-
#   Deploys .mtdt.local.yaml from the private fork catalogue by project.id;
#   default writes, while --check only reports drift
# ---

# ---

# --- Imports ---


import argparse
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError as exc:  # pragma: no cover
    sys.stderr.write("deploy-mtdt-local requires PyYAML\n")
    raise SystemExit(1) from exc

_WIRE_LIB_RAW = os.environ.get("WIRE_LIB", "").strip()
_LIB = (
    Path(_WIRE_LIB_RAW).expanduser()
    if _WIRE_LIB_RAW
    else Path(__file__).resolve().parents[1] / "lib"
)
sys.path.insert(0, str(_LIB))

from mtdt_metadata import iter_projects, load_yaml_mapping  # noqa: E402

# --- Auxiliary Code ---


def config_home() -> Path:
    raw = os.environ.get("XDG_CONFIG_HOME", "").strip()
    return Path(raw).expanduser() if raw else Path.home() / ".config"


def forks_catalog_path() -> Path:
    raw = os.environ.get("MTDT_FORKS_FILE", "").strip()
    return Path(raw).expanduser() if raw else config_home() / "mtdt/forks.yaml"


def expected_local(entry: dict) -> dict | None:
    github = entry.get("github")
    if not isinstance(github, dict):
        return None
    url = github.get("url")
    if not url or url == "null":
        return None
    visibility = github.get("visibility")
    return {
        "forges": {
            "github": {
                "url": str(url),
                "visibility": (
                    None if visibility is None or visibility == "null" else visibility
                ),
            }
        }
    }


def dumped(data: dict, *, sort_keys: bool) -> str:
    return yaml.safe_dump(
        data,
        default_flow_style=False,
        allow_unicode=True,
        sort_keys=sort_keys,
    )


def log(level: str, message: str) -> None:
    stream = sys.stderr if level in {"ERROR", "WARN"} else sys.stdout
    print(f"[{level}]: {message}", file=stream)


# --- Main Code ---


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Write .mtdt.local.yaml from the mtdt fork catalogue."
    )
    parser.add_argument("--check", action="store_true")
    parser.add_argument("roots", nargs="*", type=Path, default=[Path.cwd()])
    args = parser.parse_args(argv)

    forks_file = forks_catalog_path()
    try:
        catalogue = load_yaml_mapping(forks_file)
    except (OSError, ValueError, yaml.YAMLError) as exc:
        log("ERROR", f"cannot load fork catalogue: {exc}")
        return 1
    forks = catalogue.get("forks")
    if not isinstance(forks, dict):
        log("ERROR", f"{forks_file}: missing forks: mapping")
        return 1

    written = unchanged = missing = drift = skipped = 0
    try:
        projects = iter_projects(args.roots)
        for project_dir, project_id in projects:
            entry = forks.get(project_id)
            if not isinstance(entry, dict):
                skipped += 1
                continue
            wanted = expected_local(entry)
            if wanted is None:
                log(
                    "ERROR",
                    f"{project_dir}: catalogue entry {project_id} missing github.url",
                )
                drift += 1
                continue

            local_file = project_dir / ".mtdt.local.yaml"
            wanted_text = dumped(wanted, sort_keys=False)
            if local_file.is_file():
                current = yaml.safe_load(local_file.read_text(encoding="utf-8"))
                if isinstance(current, dict) and dumped(
                    current, sort_keys=True
                ) == dumped(wanted, sort_keys=True):
                    unchanged += 1
                    continue
                if args.check:
                    log("WARN", f"DIVERGE {project_dir}")
                    drift += 1
                    continue
                local_file.write_text(wanted_text, encoding="utf-8")
                log("INFO", f"updated {local_file}")
                written += 1
                continue

            if args.check:
                log("WARN", f"MISSING {project_dir}")
                missing += 1
                continue
            local_file.write_text(wanted_text, encoding="utf-8")
            log("INFO", f"wrote {local_file}")
            written += 1
    except (OSError, ValueError, yaml.YAMLError) as exc:
        log("ERROR", str(exc))
        return 1

    log(
        "INFO",
        f"unchanged={unchanged} written={written} missing={missing} "
        f"drift={drift} skipped={skipped} catalogue={forks_file}",
    )
    return 1 if args.check and (drift or missing) else 0


if __name__ == "__main__":
    raise SystemExit(main())

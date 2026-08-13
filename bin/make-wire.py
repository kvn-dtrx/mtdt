#!/usr/bin/env python3

# dia:file wire/make-wire.py

# ---
# description: >-
#   Unified wire: reads config/wire.ini from the target repo (sidecar).
#   Each [mount.<strategy>] or [mount.<strategy>.<label>] has
#   from/root/mode/require[/depth/skip]; strategy is the first dotted segment
#   (lib|libexec|home|root|bin|sbin). require=exists skips missing from=;
#   ${WIRE_HOST} defaults to hostname -s (per-device overlays).
#   depth=N (bin/sbin): leaf dir is the strategy (…/<pkg>/bin).
#   skip=comma-list of package names.
#   Types: PATH stubs (bin/sbin), flat trees (lib/libexec), hash capsules (home/root).
# ---
# Usage: make-wire.py [mount_name] [repo_dir]
# Env:   WIRE_MODE overrides ini mode for all selected mounts.
#        WIRE_HOST selects device overlay paths in from=.
#
# Embed: host header is shebang, blank, then dia:file wire/make-wire.py;
# body below is the snippet after its shebang.

# ---

from __future__ import annotations

import os
import re
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

# --- Configuration ---

STUB_SKIP_PREFIXES = ("make-", ".")
STUB_SKIP_SUFFIXES = (".awk", ".md", ".txt")
LEAF_SKIP_NAMES = {"__pycache__", ".DS_Store"}
LEAF_SKIP_SUFFIXES = (".pyc",)
HOME_SLOT_NAMES = {
    "bin",
    "sbin",
    "lib",
    "libexec",
    "config",
    "root",
    "home",
    ".DS_Store",
    ".gitignore",
    "README.md",
    ".luarc.json",
}
VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}")

# --- Auxiliary Code ---


@dataclass
class Mount:
    name: str
    from_raw: str
    root_raw: str
    mode: str
    require: str
    depth: str
    skip: str


def die(message: str, code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(code)


def walk_to_mtdt(start: Path) -> Path | None:
    current = start.resolve()
    if current.is_file():
        current = current.parent
    for directory in [current, *current.parents]:
        if (directory / ".mtdt.yaml").is_file():
            return directory
    return None


def find_repo_dir() -> Path | None:
    found = walk_to_mtdt(Path.cwd())
    if found is not None:
        return found
    return walk_to_mtdt(Path(__file__).resolve())


def hostname_short() -> str:
    try:
        proc = subprocess.run(
            ["hostname", "-s"],
            check=False,
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
    except OSError:
        pass
    return socket.gethostname().split(".")[0] or "localhost"


def expand_vars(text: str, env: dict[str, str]) -> str:
    remaining = text
    while True:
        match = VAR_RE.search(remaining)
        if match is None:
            return remaining
        name = match.group(1)
        default = match.group(3) or ""
        value = env.get(name, "")
        if not value:
            value = default
        remaining = remaining[: match.start()] + value + remaining[match.end() :]


def resolve_value(raw: str, env: dict[str, str]) -> str:
    text = raw
    expand = True
    if len(text) >= 2 and text[0] == text[-1] and text[0] in {'"', "'"}:
        quote = text[0]
        text = text[1:-1]
        expand = quote != "'"
    if expand:
        return expand_vars(text, env)
    return text


def decode_hash_name(name: str) -> str:
    if name.startswith("_"):
        name = "." + name[1:]
    name = name.replace("##", " ")
    name = name.replace("#", "/")
    cut = name.find("_.")
    if cut != -1:
        name = name[:cut]
    return name


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def chmod_exec(path: Path) -> None:
    try:
        mode = path.stat().st_mode
        path.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    except OSError:
        pass


def chown_root(path: Path) -> None:
    last_error: OSError | None = None
    for group in ("wheel", "root"):
        try:
            shutil.chown(path, user="root", group=group)
            if path.is_dir() and not path.is_symlink():
                for child in path.rglob("*"):
                    shutil.chown(child, user="root", group=group)
            return
        except OSError as exc:
            last_error = exc
    if last_error is not None:
        raise last_error


def materialise(src: Path, dest: Path, mode: str, require: str = "") -> None:
    ensure_parent(dest)
    if mode == "symlink":
        if dest.is_symlink() or dest.is_file():
            dest.unlink()
        elif dest.exists():
            die(f"Path already occupied: {dest}")
        dest.symlink_to(src)
        print(f"symlinked {dest} -> {src}")
        return
    if mode == "copy":
        if dest.is_symlink() or dest.is_file():
            dest.unlink()
        elif dest.is_dir():
            shutil.rmtree(dest)
        if src.is_dir():
            shutil.copytree(src, dest, symlinks=True)
        else:
            shutil.copy2(src, dest)
        if require == "root":
            chown_root(dest)
        print(f"copied {dest} <- {src}")
        return
    die(f"mode must be symlink or copy (got {mode})")


def pkg_skipped(name: str, skip: str) -> bool:
    if not skip:
        return False
    for item in skip.split(","):
        if item.strip() == name:
            return True
    return False


def iter_named_dirs(root: Path, name: str, depth: int) -> list[Path]:
    leaf_depth = depth + 1
    found: list[Path] = []
    for dirpath, dirnames, _filenames in os.walk(root, followlinks=True):
        current = Path(dirpath)
        try:
            relative = current.relative_to(root)
        except ValueError:
            continue
        parts = () if str(relative) == "." else relative.parts
        if len(parts) == leaf_depth and parts[-1] == name:
            found.append(current)
        if len(parts) >= leaf_depth:
            dirnames.clear()
    return found


def empty_fields() -> dict[str, str]:
    return {
        "from": "",
        "root": "",
        "mode": "symlink",
        "require": "",
        "depth": "0",
        "skip": "",
    }


def parse_wire_ini(path: Path) -> list[Mount]:
    mounts: list[Mount] = []
    current = ""
    fields = empty_fields()

    def flush() -> None:
        if not current:
            return
        if not fields["from"] or not fields["root"]:
            die(f"Mount {current} needs from= and root=")
        mounts.append(
            Mount(
                name=current,
                from_raw=fields["from"],
                root_raw=fields["root"],
                mode=fields["mode"],
                require=fields["require"],
                depth=fields["depth"],
                skip=fields["skip"],
            )
        )

    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if " #" in line:
            line = line[: line.index(" #")].rstrip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            flush()
            section = line[1:-1]
            if section.startswith("mount."):
                current = section[len("mount.") :]
                fields = empty_fields()
            else:
                current = ""
            continue
        if not current or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key in fields:
            fields[key] = value
    flush()
    return mounts


def write_stub(
    src: Path,
    dest: Path,
    libexec_dir: Path,
    lib_dir: Path,
    wire_root: Path,
    shared: Path | None,
) -> None:
    ensure_parent(dest)
    if dest.is_symlink() or dest.is_file():
        dest.unlink()
    elif dest.exists():
        die(f"Path already occupied: {dest}")
    lines = [
        "#!/bin/sh",
        "# Generated by make-wire — do not edit.",
        f'WIRE_ROOT="{wire_root}"',
        f'WIRE_LIB="{lib_dir}"',
        f'WIRE_LIBEXEC="{libexec_dir}"',
    ]
    if shared is not None:
        lines.extend(
            [
                f'WIRE_LIBEXEC_SHARED="{shared}"',
                'PATH="${WIRE_LIBEXEC}:${WIRE_LIBEXEC_SHARED}:${PATH}"',
                "export WIRE_ROOT WIRE_LIB WIRE_LIBEXEC WIRE_LIBEXEC_SHARED PATH",
            ]
        )
    else:
        lines.extend(
            [
                'PATH="${WIRE_LIBEXEC}:${PATH}"',
                "export WIRE_ROOT WIRE_LIB WIRE_LIBEXEC PATH",
            ]
        )
    lines.append(f'exec "{src}" "${{@}}"')
    dest.write_text("\n".join(lines) + "\n", encoding="utf-8")
    dest.chmod(dest.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    print(f"wrapped {dest} -> {src}")


def install_leaves(src_dir: Path, dest_dir: Path, mode: str, exec_mode: bool) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    for src in sorted(src_dir.iterdir()):
        if not src.is_file():
            continue
        name = src.name
        if name.startswith(".") or name in LEAF_SKIP_NAMES or name.endswith(
            LEAF_SKIP_SUFFIXES
        ):
            continue
        if exec_mode:
            chmod_exec(src)
        materialise(src, dest_dir / name, mode)


def has_subdir(path: Path) -> bool:
    return any(child.is_dir() for child in path.iterdir())


def state_bak(kind: str) -> Path:
    home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    base = home / f"make-wire-{kind}"
    base.mkdir(parents=True, exist_ok=True)
    return Path(tempfile.mkdtemp(prefix="bak.", dir=base))


def relocate(dest: Path, bak: Path) -> None:
    if dest.is_symlink():
        dest.unlink()
    elif dest.exists():
        shutil.move(str(dest), bak / dest.name)


# --- Main Code ---


class Wire:
    def __init__(self, repo_dir: Path) -> None:
        self.repo_dir = repo_dir.resolve()
        self.pkg = self.repo_dir.name
        self.wire_ini = self.repo_dir / "config" / "wire.ini"
        if not self.wire_ini.is_file():
            die(f"Missing {self.wire_ini}")
        self.mounts = parse_wire_ini(self.wire_ini)
        self.env = dict(os.environ)
        self.ensure_defaults()
        self.from_path = Path()
        self.root_path = Path()
        self.mode = "symlink"
        self.require = ""
        self.depth = 0
        self.skip = ""
        self.label = ""

    def ensure_defaults(self) -> None:
        if not self.env.get("MY_LOCAL_HOME"):
            self.env["MY_LOCAL_HOME"] = str(Path.home() / ".local")
        if not self.env.get("WIRE_HOST"):
            self.env["WIRE_HOST"] = hostname_short()
        self.env["pkg"] = self.pkg
        self.env.setdefault("HOME", str(Path.home()))
        os.environ["MY_LOCAL_HOME"] = self.env["MY_LOCAL_HOME"]
        os.environ["WIRE_HOST"] = self.env["WIRE_HOST"]
        self.local_home = Path(self.env["MY_LOCAL_HOME"])

    def resolve(self, raw: str) -> str:
        return resolve_value(raw, self.env)

    def libexec_for(self, label: str) -> Path:
        if label:
            for mount in self.mounts:
                if mount.name == f"libexec.{label}" and mount.root_raw:
                    return Path(self.resolve(mount.root_raw))
            capsule = self.repo_dir / "src" / "wire" / label
            if capsule.is_dir():
                for node in capsule.glob("_local#libexec#*"):
                    decoded = decode_hash_name(node.name)
                    return Path.home() / decoded
        return self.local_home / "libexec" / label

    def shared_libexec(self) -> Path | None:
        if (self.repo_dir / "src" / "wire" / "logging" / "libexec").is_dir():
            return self.local_home / "libexec" / "logging"
        return None

    def stub_dir(self, src_dir: Path, wire_pkg: str) -> None:
        self.root_path.mkdir(parents=True, exist_ok=True)
        shared = self.shared_libexec()
        for src in sorted(src_dir.iterdir()):
            if not src.is_file():
                continue
            base = src.name
            if base.startswith(STUB_SKIP_PREFIXES) or base.endswith(STUB_SKIP_SUFFIXES):
                continue
            chmod_exec(src)
            name = base.rsplit(".", 1)[0] if "." in base else base
            if not name:
                continue
            dest = self.root_path / name
            write_stub(
                src.resolve(),
                dest,
                self.libexec_for(wire_pkg),
                self.local_home / "lib" / wire_pkg,
                self.repo_dir,
                shared,
            )

    def wire_stub(self, leaf: str) -> None:
        if self.depth == 0:
            if not self.from_path.exists():
                die(f"Missing {self.from_path}")
            wire_pkg = self.label or self.pkg
            self.stub_dir(self.from_path, wire_pkg)
            return
        for leaf_dir in iter_named_dirs(self.from_path, leaf, self.depth):
            wire_pkg = leaf_dir.parent.name
            if pkg_skipped(wire_pkg, self.skip):
                continue
            self.stub_dir(leaf_dir, wire_pkg)

    def wire_tree(self, leaf: str) -> None:
        if not self.from_path.is_dir():
            die(f"Missing {self.from_path}")
        exec_mode = leaf == "libexec"
        install_leaves(self.from_path, self.root_path, self.mode, exec_mode)
        nodes = list(self.from_path.glob(f"_local#{leaf}#*"))
        nodes.extend(self.from_path.glob(f"*/_local#{leaf}#*"))
        for src_node in nodes:
            dest = self.root_path / decode_hash_name(src_node.name)
            if src_node.is_dir():
                install_leaves(src_node, dest, self.mode, exec_mode)
            else:
                materialise(src_node, dest, self.mode)
        for src_node in sorted(self.from_path.glob(f"*/{leaf}")):
            if not src_node.is_dir():
                continue
            pkg = src_node.parent.name
            if pkg_skipped(pkg, self.skip) or pkg == "hosts":
                continue
            dest = self.local_home / leaf / pkg
            if has_subdir(src_node) and leaf == "libexec":
                materialise(src_node, dest, self.mode)
            else:
                install_leaves(src_node, dest, self.mode, exec_mode)

    def wire_home(self) -> None:
        if not self.from_path.is_dir():
            die(f"Missing {self.from_path}")
        bak = state_bak("home")
        xdg_config = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
        try:
            for tool_dir in sorted(p for p in self.from_path.iterdir() if p.is_dir()):
                tool = tool_dir.name
                if pkg_skipped(tool, self.skip) or tool == "hosts":
                    continue
                for src_node in tool_dir.iterdir():
                    base = src_node.name
                    if base in HOME_SLOT_NAMES:
                        continue
                    if base.startswith("_") or "#" in base:
                        die(f"wire home: {tool}/{base} must live under home/")
                config_dir = tool_dir / "config"
                if config_dir.is_dir():
                    dest = xdg_config / tool
                    ensure_parent(dest)
                    relocate(dest, bak)
                    materialise(config_dir, dest, self.mode)
                home_dir = tool_dir / "home"
                if not home_dir.is_dir():
                    continue
                for src_node in home_dir.iterdir():
                    base = src_node.name
                    if base in {".DS_Store", ".gitignore"}:
                        continue
                    if not (base.startswith("_") or "#" in base):
                        continue
                    dest = self.root_path / decode_hash_name(base)
                    ensure_parent(dest)
                    relocate(dest, bak)
                    materialise(src_node, dest, self.mode)
        finally:
            try:
                bak.rmdir()
            except OSError:
                pass

    def wire_root(self) -> None:
        if not self.from_path.is_dir():
            die(f"Missing {self.from_path}")
        bak = state_bak("root")

        def install_item(item: Path) -> None:
            name = item.name
            if name.startswith(".") or name == ".gitignore":
                return
            dest = self.root_path / decode_hash_name(name)
            ensure_parent(dest)
            if dest.exists() or dest.is_symlink():
                relocate(dest, bak)
            if item.is_dir():
                shutil.copytree(item, dest, symlinks=True)
            else:
                shutil.copy2(item, dest)
            chown_root(dest)
            print(f"copied {dest} <- {item}")

        try:
            if self.depth >= 1:
                for root_dir in iter_named_dirs(self.from_path, "root", self.depth):
                    pkg = root_dir.parent.name
                    if pkg_skipped(pkg, self.skip):
                        continue
                    for item in sorted(root_dir.iterdir()):
                        install_item(item)
                return
            root_dir = self.from_path / "root"
            if root_dir.is_dir():
                for item in sorted(root_dir.iterdir()):
                    install_item(item)
        finally:
            try:
                bak.rmdir()
            except OSError:
                pass

    def run_mount(self, mount: Mount) -> None:
        strategy = mount.name.split(".", 1)[0]
        self.label = mount.name.split(".", 1)[1] if "." in mount.name else ""
        self.mode = self.resolve(os.environ.get("WIRE_MODE", mount.mode))
        self.require = self.resolve(mount.require)
        depth_raw = self.resolve(mount.depth)
        self.depth = int(depth_raw) if depth_raw.isdigit() else 0
        self.skip = self.resolve(mount.skip)
        if self.mode not in {"symlink", "copy"}:
            die(f"mode must be symlink or copy (got {self.mode})")
        self.ensure_defaults()
        from_resolved = self.resolve(mount.from_raw)
        self.from_path = Path(from_resolved)
        if not self.from_path.is_absolute():
            self.from_path = self.repo_dir / self.from_path
        self.root_path = Path(self.resolve(mount.root_raw))
        if self.require == "root" and os.geteuid() != 0:
            print(f"wire mount={mount.name} skipped (requires root)")
            return
        if self.require == "exists" and not self.from_path.exists():
            print(f"wire mount={mount.name} skipped (missing {self.from_path})")
            return
        print(f"wire mount={mount.name} strategy={strategy} mode={self.mode}")
        if strategy in {"bin", "sbin"}:
            self.wire_stub(strategy)
        elif strategy in {"lib", "libexec"}:
            self.wire_tree(strategy)
        elif strategy == "home":
            self.wire_home()
        elif strategy == "root":
            self.wire_root()
        else:
            die(f"Unknown mount strategy: {strategy}")

    def run(self, mount_filter: str) -> None:
        ran = 0
        for mount in self.mounts:
            if mount_filter:
                if mount.name != mount_filter and not mount.name.startswith(
                    f"{mount_filter}."
                ):
                    continue
            self.run_mount(mount)
            ran += 1
        if ran == 0:
            if mount_filter:
                die(f"No mount [mount.{mount_filter}] in {self.wire_ini}")
            die(f"No [mount.*] sections in {self.wire_ini}")


def parse_args(argv: list[str]) -> tuple[str, Path]:
    mount_filter = argv[0] if argv else ""
    repo_dir = Path(argv[1]) if len(argv) > 1 else None
    if mount_filter and Path(mount_filter).is_dir() and repo_dir is None:
        repo_dir = Path(mount_filter)
        mount_filter = ""
    if repo_dir is None:
        found = find_repo_dir()
        if found is None:
            die("No .mtdt.yaml above here (pass repo_dir)")
        repo_dir = found
    if not repo_dir.is_dir():
        die("No .mtdt.yaml above here (pass repo_dir)")
    return mount_filter, repo_dir


def main() -> int:
    mount_filter, repo_dir = parse_args(sys.argv[1:])
    Wire(repo_dir).run(mount_filter)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

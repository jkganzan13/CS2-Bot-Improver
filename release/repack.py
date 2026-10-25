#!/usr/bin/env python3
"""Rebuild a CS2 Bot Improver release zip with updated components.

The upstream release zip is used as the base (Panel, gameinfo.gi, .vpk files,
configs ...). Newer components are laid over it:

  --runtime ZIP   CounterStrikeSharp / Metamod release zips. Everything is
                  overwritten except files under a protected prefix that the
                  base already has (user-facing configs).
  --overlay DIR   Trees staged by the workflow (freshly built plugins, data).
                  Everything is overwritten.

Every overlay must find an "addons" folder; the package root is the folder
that contains it. A markdown report of what changed is written to --report.

  --install-json PATH  Also write an install manifest at PATH (relative to the
                       package root): every file the package installs into
                       game/csgo with its SHA-256, plus the --meta values.
                       The updater uses it to tell untouched files from ones
                       the user (or the Panel) changed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

# Paths (relative to the package root) that keep the base's copy if it has one.
PROTECTED_PREFIXES = (
    "addons/counterstrikesharp/configs/",
    "addons/metamod/metaplugins.ini",
    "addons/metamod.vdf",
    "addons/metamod_x64.vdf",
)


def find_root(tree: Path) -> Path:
    """Return the shallowest directory under tree that contains 'addons'."""
    candidates = sorted(
        (p.parent for p in tree.rglob("addons") if p.is_dir()),
        key=lambda p: len(p.relative_to(tree).parts),
    )
    if not candidates:
        sys.exit(f"error: no 'addons' folder found in {tree}")
    return candidates[0]


def extract(zip_path: Path, dest: Path) -> Path:
    with zipfile.ZipFile(zip_path) as zf:
        for member in zf.namelist():
            target = (dest / member).resolve()
            if not str(target).startswith(str(dest.resolve())):
                sys.exit(f"error: unsafe path {member!r} in {zip_path}")
        zf.extractall(dest)
    return find_root(dest)


def is_protected(rel: str) -> bool:
    return any(rel == p or rel.startswith(p) for p in PROTECTED_PREFIXES)


def apply_overlay(src_root: Path, dst_root: Path, protect: bool) -> dict[str, list[str]]:
    changes: dict[str, list[str]] = {"added": [], "replaced": [], "unchanged": [], "kept": []}
    for src in sorted(p for p in src_root.rglob("*") if p.is_file()):
        rel = PurePosixPath(*src.relative_to(src_root).parts).as_posix()
        dst = dst_root / rel
        if dst.exists():
            if protect and is_protected(rel):
                changes["kept"].append(rel)
                continue
            if dst.read_bytes() == src.read_bytes():
                changes["unchanged"].append(rel)
                continue
            changes["replaced"].append(rel)
        else:
            changes["added"].append(rel)
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)
    return changes


def is_installed_file(rel: str) -> bool:
    """True for files that end up in game/csgo (the Panel .exe at the root does not)."""
    return "/" in rel or not rel.lower().endswith(".exe")


def write_install_json(root: Path, rel_path: str, meta: dict[str, str]) -> int:
    files: dict[str, str] = {}
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        rel = path.relative_to(root).as_posix()
        if rel == rel_path or not is_installed_file(rel):
            continue
        files[rel] = hashlib.sha256(path.read_bytes()).hexdigest()
    data: dict[str, object] = {"schema": 1, **meta, "files": files}
    if "build" in data:
        data["build"] = int(str(data["build"]))
    target = root / rel_path
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8", newline="\n")
    return len(files)


def write_zip(root_parent: Path, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as zf:
        for path in sorted(root_parent.rglob("*")):
            arc = path.relative_to(root_parent).as_posix()
            if path.is_dir():
                zf.write(path, arc + "/")
            else:
                zf.write(path, arc)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--base", required=True, type=Path, help="upstream release zip")
    ap.add_argument("--runtime", action="append", default=[], type=Path, metavar="ZIP")
    ap.add_argument("--overlay", action="append", default=[], type=Path, metavar="DIR")
    ap.add_argument("--require", action="append", default=[], metavar="PATH",
                    help="file that must exist in the final package (relative to its root)")
    ap.add_argument("--out", required=True, type=Path)
    ap.add_argument("--report", type=Path)
    ap.add_argument("--install-json", metavar="PATH",
                    help="write an install manifest at this path (relative to the package root)")
    ap.add_argument("--meta", action="append", default=[], metavar="KEY=VALUE",
                    help="extra field for the install manifest (repeatable)")
    args = ap.parse_args()

    meta: dict[str, str] = {}
    for item in args.meta:
        key, sep, value = item.partition("=")
        if not sep or not key:
            ap.error(f"--meta expects KEY=VALUE, got {item!r}")
        meta[key] = value

    report = [f"### {args.out.name}", "", f"Base: `{args.base.name}`", ""]
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = Path(tmp)
        base_dir = tmp_path / "base"
        base_dir.mkdir()
        root = extract(args.base, base_dir)

        layers: list[tuple[str, Path, bool]] = []
        for i, rz in enumerate(args.runtime):
            d = tmp_path / f"runtime{i}"
            d.mkdir()
            layers.append((rz.name, extract(rz, d), True))
        for od in args.overlay:
            layers.append((str(od), find_root(od), False))

        for name, src_root, protect in layers:
            ch = apply_overlay(src_root, root, protect)
            report.append(
                f"- **{name}**: {len(ch['replaced'])} replaced, {len(ch['added'])} added, "
                f"{len(ch['unchanged'])} already identical, {len(ch['kept'])} kept from base"
            )
            for kind in ("replaced", "added", "kept"):
                if ch[kind]:
                    shown = ch[kind][:40]
                    more = f" … and {len(ch[kind]) - 40} more" if len(ch[kind]) > 40 else ""
                    report.append(f"  - {kind}: " + ", ".join(f"`{f}`" for f in shown) + more)
            if not (ch["replaced"] or ch["added"] or ch["unchanged"]):
                print(f"error: layer {name} contributed no files", file=sys.stderr)
                return 1

        missing = [r for r in args.require if not (root / r).is_file()]
        if missing:
            print("error: required files missing from package:\n  " + "\n  ".join(missing), file=sys.stderr)
            return 1

        if args.install_json:
            count = write_install_json(root, args.install_json, meta)
            report.append(f"- **install manifest** `{args.install_json}`: {count} files")

        write_zip(base_dir, args.out)

    report.append("")
    text = "\n".join(report) + "\n"
    print(text)
    if args.report:
        with args.report.open("a", encoding="utf-8") as fh:
            fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())

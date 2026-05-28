#!/usr/bin/env python3
import argparse
import shutil
from datetime import datetime, timezone
from pathlib import Path
import os


CHROMA_DIR = Path(os.getenv("VANNA_CHROMA_DIR", "/var/lib/vanna/chroma"))
SNAPSHOT_DIR = Path(os.getenv("VANNA_SNAPSHOT_DIR", "/var/lib/vanna/snapshots"))


def default_snapshot_name() -> str:
    return datetime.now(timezone.utc).strftime("vanna-memory-%Y%m%dT%H%M%SZ")


def snapshot_path(name: str) -> Path:
    if "/" in name or name in {"", ".", ".."}:
        raise SystemExit("snapshot name must be a simple directory name")
    return SNAPSHOT_DIR / name


def export_snapshot(name: str | None) -> None:
    name = name or default_snapshot_name()
    destination = snapshot_path(name)
    if destination.exists():
        raise SystemExit(f"snapshot already exists: {destination}")
    if not CHROMA_DIR.exists():
        raise SystemExit(f"Chroma directory does not exist: {CHROMA_DIR}")

    SNAPSHOT_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copytree(CHROMA_DIR, destination)
    print(f"exported {CHROMA_DIR} to {destination}")


def import_snapshot(name: str, force: bool) -> None:
    source = snapshot_path(name)
    if not source.exists():
        raise SystemExit(f"snapshot does not exist: {source}")

    if CHROMA_DIR.exists():
        if not force:
            raise SystemExit(f"Chroma directory already exists: {CHROMA_DIR}. Use --force to replace it.")
        shutil.rmtree(CHROMA_DIR)

    CHROMA_DIR.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, CHROMA_DIR)
    print(f"imported {source} to {CHROMA_DIR}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Export or import Vanna Chroma memory snapshots.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("name", nargs="?")

    import_parser = subparsers.add_parser("import")
    import_parser.add_argument("name")
    import_parser.add_argument("--force", action="store_true")

    args = parser.parse_args()
    if args.command == "export":
        export_snapshot(args.name)
    elif args.command == "import":
        import_snapshot(args.name, args.force)


if __name__ == "__main__":
    main()

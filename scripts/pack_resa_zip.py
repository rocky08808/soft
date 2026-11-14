#!/usr/bin/env python3
"""Pack the PyInstaller onedir folder into downloads/ReSA.zip."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: pack_resa_zip.py <dist/ReSA> <downloads/ReSA.zip>")
    root = Path(sys.argv[1]).resolve()
    dest = Path(sys.argv[2]).resolve()
    exe = root / "ReSA.exe"
    if not exe.is_file():
        raise SystemExit(f"missing {exe}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    count = 0
    with zipfile.ZipFile(dest, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in root.rglob("*"):
            if not path.is_file():
                continue
            archive.write(path, path.relative_to(root).as_posix())
            count += 1
    print(f"{dest} ({dest.stat().st_size} bytes, {count} files)")


if __name__ == "__main__":
    main()

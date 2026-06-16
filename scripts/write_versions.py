#!/usr/bin/env python3
"""Write product version to _version.py and downloads/versions.json."""

from __future__ import annotations

import json
import sys
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSIONS_PATH = ROOT / "downloads" / "versions.json"

PRODUCTS = {
    "resa": {
        "dir": ROOT / "agent",
        "url": "/download/ReSA.exe",
        "minSize": 1_048_576,
    },
    "rest": {
        "dir": ROOT / "rest-go",
        "url": "/download/ReST.zip",
        "minSize": 524_288,
    },
}


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit("usage: write_versions.py <resa|rest> [version]")

    product = sys.argv[1].strip().lower()
    if product not in PRODUCTS:
        raise SystemExit(f"unknown product: {product}")

    version = (
        sys.argv[2].strip()
        if len(sys.argv) > 2 and sys.argv[2].strip()
        else datetime.now().strftime("%Y.%m.%d.%H%M")
    )

    manifest: dict = {}
    if VERSIONS_PATH.is_file():
        manifest = json.loads(VERSIONS_PATH.read_text(encoding="utf-8"))

    meta = PRODUCTS[product]
    manifest[product] = {
        "version": version,
        "url": meta["url"],
        "minSize": meta["minSize"],
    }

    VERSIONS_PATH.parent.mkdir(parents=True, exist_ok=True)
    VERSIONS_PATH.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )

    version_file = meta["dir"] / (
        "version.txt" if product == "rest" else "_version.py"
    )
    if product == "rest":
        version_file.write_text(f"{version}\n", encoding="utf-8")
    else:
        version_file.write_text(f'VERSION = "{version}"\n', encoding="utf-8")
    print(version)


if __name__ == "__main__":
    main()

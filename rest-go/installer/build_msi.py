#!/usr/bin/env python3
"""Build ReST.msi with Python msilib (Windows only)."""

from __future__ import annotations

import os
import re
import shutil
import sys
from pathlib import Path

if sys.platform != "win32":
    raise SystemExit("ReST MSI build requires Windows")

import msilib
from msilib import CAB, Directory, Feature, add_data, add_tables, gen_uuid, init_database
from msilib import schema, sequence

ROOT = Path(__file__).resolve().parent.parent
INSTALLER = Path(__file__).resolve().parent
STAGING = INSTALLER / "staging"
DIST_EXE = ROOT / "dist" / "ReST.exe"
CONFIG = ROOT / "agent.config.json"
POST_PS1 = INSTALLER / "post-install.ps1"
OUT = ROOT.parent / "downloads" / "ReST.msi"
UPGRADE_CODE = "{B7C8D9E0-F1A2-4B3C-9D0E-1F2A3B4C5D6E}"


def msi_product_version(raw: str) -> str:
    """MSI ProductVersion: major.minor.build (each part has MSI limits)."""
    parts = [int(p) for p in re.findall(r"\d+", raw)]
    while len(parts) < 4:
        parts.append(0)
    major = 1
    minor = min(parts[1] * 100 + parts[2], 65535)
    build = min(parts[3], 65535)
    return f"{major}.{minor}.{build}"


def read_build_version() -> str:
    version_file = ROOT / "version.txt"
    if version_file.is_file():
        saved = version_file.read_text(encoding="utf-8").strip()
        if saved:
            return saved
    return "1.0.0"


def stage_files() -> None:
    if not DIST_EXE.is_file():
        raise SystemExit(f"missing {DIST_EXE} — run rest-go\\build.bat first")
    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)
    shutil.copy2(DIST_EXE, STAGING / "ReST.exe")
    if CONFIG.is_file():
        shutil.copy2(CONFIG, STAGING / "agent.config.json")
    else:
        shutil.copy2(ROOT / "default.config.json", STAGING / "agent.config.json")
    shutil.copy2(POST_PS1, STAGING / "post-install.ps1")


def build_msi() -> Path:
    stage_files()
    product_version = msi_product_version(read_build_version())
    product_code = gen_uuid()

    if OUT.is_file():
        OUT.unlink()

    db = init_database(
        str(OUT),
        schema,
        "ReST Remote Terminal",
        product_code,
        product_version,
        "ReST",
    )
    add_tables(db, sequence)

    add_data(
        db,
        "Property",
        [
            ("UpgradeCode", UPGRADE_CODE),
            ("ALLUSERS", "2"),
            ("ARPNOMODIFY", "1"),
            ("ARPURLINFOABOUT", "https://olxp.cc/install.html"),
            ("REINSTALLMODE", "amus"),
        ],
    )

    cab = CAB("rest.cab")
    root = Directory(db, cab, None, str(STAGING), "TARGETDIR", "SourceDir")
    app = Directory(db, cab, root, ".", "INSTALLDIR", "ReST")
    feat = Feature(db, "Complete", "ReST", "ReST terminal agent", 1, 1, directory="INSTALLDIR")
    feat.set_current()

    comp = "ReSTComponent"
    app.start_component(comp, feat, 0, keyfile="ReST.exe")
    app.add_file("ReST.exe")
    app.add_file("agent.config.json")
    app.add_file("post-install.ps1")

    add_data(
        db,
        "Registry",
        [
            (
                "ReSTRunKey",
                1,
                r"Software\Microsoft\Windows\CurrentVersion\Run",
                "ReST",
                "[#ReST.exe]",
                comp,
            )
        ],
    )

    ps1 = (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
        '-File "[#post-install.ps1]" -Action install'
    )
    ps1_un = (
        "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden "
        '-File "[#post-install.ps1]" -Action uninstall'
    )

    add_data(
        db,
        "CustomAction",
        [
            ("SetInstallDir", 51, "INSTALLDIR", "[LocalAppDataFolder]ReST"),
            ("PostInstall", 1762, "INSTALLDIR", f'powershell.exe {ps1}'),
            ("PostUninstall", 1762, "INSTALLDIR", f'powershell.exe {ps1_un}'),
        ],
    )

    add_data(
        db,
        "InstallExecuteSequence",
        [
            ("SetInstallDir", 'NOT Installed', 50),
            ("PostInstall", 'NOT Installed', 6600),
            ("PostUninstall", 'REMOVE="ALL"', 3400),
        ],
    )

    cab.commit(db)
    db.Commit()
    return OUT


def main() -> None:
    out = build_msi()
    size_mb = out.stat().st_size / 1024 / 1024
    print(f"Done: {out}")
    print(f"size: {size_mb:.2f} MB")


if __name__ == "__main__":
    main()

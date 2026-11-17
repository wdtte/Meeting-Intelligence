#!/usr/bin/env python3
"""Inspect a packaged installer without writing to its filesystem."""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout.strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


image, expected_version, expected_arch = sys.argv[1:]
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="meeting-dmg-check-") as scratch:
    mount = Path(scratch) / "volume"
    mount.mkdir()
    run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), image)
    try:
        app = mount / "Meeting Intelligence.app"
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        require(info["CFBundleShortVersionString"] == expected_version, "Unexpected app version")
        arch = run("lipo", "-archs", str(app / "Contents/MacOS/MeetingIntelligence"))
        require(arch == expected_arch, "Unexpected app architecture")
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run("python3", str(root / "scripts/verify-app.py"), str(app))
        for name in ("MeetingIntelligence", "meeting", "meeting-summary"):
            require((app / "Contents/MacOS" / name).is_file(), f"Missing executable: {name}")
        for name in ("AppIcon.icns", "AppIcon.png", "TranscriptExport.html"):
            require((app / "Contents/Resources" / name).is_file(), f"Missing resource: {name}")
        shortcut = mount / "Applications"
        require(shortcut.is_symlink() and shortcut.readlink() == Path("/Applications"),
                "Missing Applications shortcut")
        require((mount / ".DS_Store").stat().st_size > 0, "Missing Finder layout")
        require((mount / ".background/background.tiff").is_file(), "Missing Retina background")
        require((mount / ".VolumeIcon.icns").read_bytes()
                == (root / "Resources/Installer/volume-icon.icns").read_bytes(), "Wrong volume icon")
        for name in ("README.md", "LICENSE"):
            require((mount / ".Documentation" / name).read_bytes() == (root / name).read_bytes(),
                    f"Missing or incorrect documentation: {name}")
        print(f"Verified DMG: version {expected_version}, {expected_arch}, signature, resources and installer assets")
    finally:
        run("hdiutil", "detach", str(mount))

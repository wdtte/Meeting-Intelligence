#!/usr/bin/env python3
"""Check edition boundaries, bundled dependencies and minimum runtime versions."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def version(value):
    return tuple(int(part) for part in value.split("."))[:2]


def verify(app):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    edition = info.get("MIBuildEdition")
    require(edition in ("standard", "compatibility"), "Missing or unknown build edition")
    compatibility = edition == "compatibility"
    minimum = "15.0" if compatibility else "26.0"
    require(info["LSMinimumSystemVersion"] == minimum, "Incorrect minimum macOS version")
    executables = ["MeetingIntelligence", "meeting", "meeting-summary"]
    if compatibility:
        executables.append("meeting-whisper")
    arch = run("lipo", "-archs", str(contents / "MacOS/MeetingIntelligence"))
    require(arch in ("arm64", "x86_64"), "Expected a native, single-architecture app")
    for name in executables:
        executable = contents / "MacOS" / name
        require(executable.is_file(), f"Missing executable: {name}")
        require(run("lipo", "-archs", str(executable)) == arch, f"Wrong architecture: {name}")
        build = run("xcrun", "vtool", "-show-build", str(executable))
        targets = re.findall(r"\bminos\s+([0-9.]+)", build)
        require(targets and all(version(target) <= version(minimum) for target in targets),
                f"{name} requires a newer OS than the package: {targets}")
        if name in ("MeetingIntelligence", "meeting"):
            require(all(version(target) == version(minimum) for target in targets), f"Wrong Swift deployment target: {name}")
        for line in run("otool", "-L", str(executable)).splitlines()[1:]:
            dependency = line.strip().split(" (", 1)[0]
            require(dependency.startswith(("/System/Library/", "/usr/lib/")),
                    f"Unbundled dependency in {name}: {dependency}")
    resources = contents / "Resources"
    for name in ("AppIcon.icns", "AppIcon.png", "TranscriptExport.html"):
        require((resources / name).is_file(), f"Missing resource: {name}")
    model_files = [path for path in contents.rglob("*") if path.is_file()
                   and (path.suffix.lower() in (".bin", ".gguf", ".ggml", ".safetensors", ".pt")
                        or "whisper" in path.name.lower())]
    if compatibility:
        manifest = json.loads((resources / "Whisper/manifest.json").read_text())
        expected = json.loads((Path(__file__).resolve().parent.parent / "Helpers/whisper/manifest.json").read_text())
        require(manifest == expected, "Unexpected Whisper dependency manifest")
        model = resources / "Whisper" / manifest["model"]["name"]
        require(model.stat().st_size == manifest["model"]["bytes"], "Incorrect model size")
        require(hashlib.sha256(model.read_bytes()).hexdigest() == manifest["model"]["sha256"], "Incorrect model checksum")
        for name in ("whisper.cpp-LICENSE", "Whisper-model-LICENSE", "miniaudio.h-LICENSE", "stb_vorbis.c-LICENSE"):
            require((resources / "Whisper/Licenses" / name).stat().st_size > 0, f"Missing license: {name}")
    else:
        require(not model_files and not (resources / "Whisper").exists(),
                f"Standard edition must not contain Whisper or models: {model_files}")
    run("codesign", "--verify", "--deep", "--strict", str(app))
    print(f"Verified {edition}: macOS {minimum}+, {arch}, signatures, resources, dependencies and model isolation")
    return edition


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())

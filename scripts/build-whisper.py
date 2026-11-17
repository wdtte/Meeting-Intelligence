#!/usr/bin/env python3
"""Prepare the pinned, offline Whisper runtime for the compatibility edition only."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Helpers/whisper/manifest.json"
WORK = ROOT / "build/whisper"


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def download(item, destination):
    if destination.exists() and digest(destination) == item["sha256"]:
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    pending = destination.with_suffix(".next")
    try:
        subprocess.run(["curl", "--fail", "--location", "--retry", "3", "--output", str(pending), item["url"]], check=True)
        if digest(pending) != item["sha256"]:
            raise RuntimeError(f"Checksum mismatch: {destination.name}")
        pending.replace(destination)
    finally:
        pending.unlink(missing_ok=True)


def main():
    cmake = os.environ.get("CMAKE", "cmake")
    if not shutil.which(cmake):
        raise RuntimeError("Compatibility builds require CMake 3.21+ (for example: brew install cmake).")
    manifest = json.loads(MANIFEST.read_text())
    archive = WORK / "downloads/source.tar.gz"
    download(manifest["source"], archive)
    revision = manifest["source"]["revision"]
    source = WORK / f"whisper.cpp-{revision}"
    if not source.exists():
        with tarfile.open(archive) as tar:
            # The archive is pinned by SHA-256; still reject out-of-tree paths and links.
            for member in tar.getmembers():
                target = (WORK / member.name).resolve()
                if WORK.resolve() not in target.parents or member.issym() or member.islnk():
                    raise RuntimeError("Unsafe source archive entry")
            tar.extractall(WORK)
    arch = platform.machine()
    if arch not in ("arm64", "x86_64"):
        raise RuntimeError("Unsupported architecture")
    build = WORK / f"cmake-{revision}-{arch}-macos15"
    # Static CPU/Accelerate build avoids GPU driver differences, runtime dylibs,
    # Homebrew paths, and host-specific instruction sets on older Intel Macs.
    subprocess.run([cmake, "-S", str(source), "-B", str(build),
                    "-DCMAKE_BUILD_TYPE=Release", "-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0",
                    f"-DCMAKE_OSX_ARCHITECTURES={arch}", "-DBUILD_SHARED_LIBS=OFF",
                    "-DWHISPER_BUILD_TESTS=OFF", "-DWHISPER_BUILD_SERVER=OFF",
                    "-DWHISPER_CURL=OFF", "-DGGML_METAL=OFF", "-DGGML_OPENMP=OFF",
                    "-DGGML_NATIVE=OFF", "-DGGML_AVX=OFF", "-DGGML_AVX2=OFF",
                    "-DGGML_FMA=OFF", "-DGGML_F16C=OFF", "-DGGML_CCACHE=OFF"], check=True)
    subprocess.run([cmake, "--build", str(build), "--config", "Release", "--target", "whisper-cli",
                    "--parallel", str(min(8, os.cpu_count() or 2))], check=True)
    runtime = WORK / "runtime"
    runtime.mkdir(exist_ok=True)
    shutil.copy2(build / "bin/whisper-cli", runtime / "meeting-whisper")
    download(manifest["model"], runtime / manifest["model"]["name"])
    licenses = runtime / "Licenses"
    licenses.mkdir(exist_ok=True)
    shutil.copy2(source / "LICENSE", licenses / "whisper.cpp-LICENSE")
    shutil.copy2(ROOT / "Helpers/whisper/LICENSE.openai", licenses / "Whisper-model-LICENSE")
    # The CLI's audio decoders carry their own permissive notices.
    for header in ("miniaudio.h", "stb_vorbis.c"):
        for path in source.rglob(header):
            text = path.read_text()
            marker = text.rfind("ALTERNATIVE 2 - MIT No Attribution") if header == "miniaudio.h" else text.rfind("ALTERNATIVE A - MIT License")
            if marker == -1:
                raise RuntimeError(f"Missing license in {path}")
            (licenses / f"{header}-LICENSE").write_text(text[marker:])
            break
        else:
            raise RuntimeError(f"Missing dependency header: {header}")
    shutil.copy2(MANIFEST, runtime / "manifest.json")
    print(f"Prepared offline Whisper runtime: {runtime}")


if __name__ == "__main__":
    main()

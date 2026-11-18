#!/usr/bin/env python3
"""Compare previous/candidate packaged CLIs against a synthetic v1 custom-path library.
No real user library, recording, credential, or provider call is used.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import tempfile
import uuid
import wave

parser = argparse.ArgumentParser()
parser.add_argument("previous_app", type=Path)
parser.add_argument("candidate_app", type=Path)
args = parser.parse_args()

def run(app, base, *arguments):
    result = subprocess.run([str(app / "Contents/MacOS/meeting"), "--data-dir", str(base), *arguments], check=True, capture_output=True)
    return json.loads(result.stdout)

def tree(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in root.rglob("*") if p.is_file()}

def info(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        value = plistlib.load(stream)
    return {key: value.get(key) for key in ["CFBundleShortVersionString", "CFBundleVersion", "MICommit", "MIBuildEdition"]}

with tempfile.TemporaryDirectory(prefix="meeting-upgrade-") as temporary:
    root = Path(temporary)
    base, audio, historical, transcripts = [root / name for name in ["Data", "CurrentAudio", "HistoricalAudio", "HistoricalTranscripts"]]
    for folder in [base, audio, historical, transcripts]:
        folder.mkdir()
    meeting_id, chunk_id, segment_id = [str(uuid.uuid4()).upper() for _ in range(3)]
    folder = historical / meeting_id
    folder.mkdir()
    with wave.open(str(folder / "synthetic.wav"), "wb") as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
        stream.writeframes(b"".join(struct.pack("<h", int(math.sin(i * math.tau * 440 / 16000) * 3000)) for i in range(16000)))
    transcript_path = transcripts / f"{meeting_id}.json"
    manifest = {"schemaVersion": 1, "id": meeting_id, "title": "Synthetic upgrade fixture", "applicationName": "系统音频", "bundleIdentifier": "", "startedAt": 816000000, "endedAt": 816000001, "status": "completed", "chunks": [{"id": chunk_id, "fileName": "synthetic.wav", "offset": 0, "duration": 1, "sampleRate": 16000, "channels": 1, "isComplete": True}], "transcriptPath": str(transcript_path)}
    segments = [{"id": segment_id, "chunkID": chunk_id, "source": "application", "start": 0.1, "end": 0.8, "text": "Synthetic text: release on Friday."}]
    # Swift JSONEncoder.sortedKeys v1 fingerprint, no optional engine/null fields.
    fingerprint = hashlib.sha256(json.dumps({"recordingID": meeting_id, "locale": "en-US", "segments": segments}, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode()).hexdigest()
    document = {"schemaVersion": 1, "recordingID": meeting_id, "locale": "en-US", "engine": "Apple SpeechTranscriber", "segments": segments, "processedChunks": [chunk_id], "status": "completed", "summary": {"provider": "openAICompatible", "status": "completed", "text": "Synthetic summary: Friday release.", "inputFingerprint": fingerprint}}
    (folder / "recording.json").write_text(json.dumps(manifest))
    transcript_path.write_text(json.dumps(document))
    # Foundation URL Codable uses absolute file URL strings.
    settings = {"audioDirectory": audio.as_uri() + "/", "transcriptDirectory": (root / "NewTranscripts").as_uri() + "/", "audioHistoryDirectories": [audio.as_uri() + "/", historical.as_uri() + "/"]}
    (base / "settings.json").write_text(json.dumps(settings))
    before = tree(root)
    installed = root / "Installed.app"
    shutil.copytree(args.previous_app, installed)
    previous = run(installed, base, "transcript", meeting_id, "--require-complete")
    previous_export = root / "previous-export.json"
    run(installed, base, "export", meeting_id, "--format", "json", "--output", str(previous_export))
    shutil.rmtree(installed)
    shutil.copytree(args.candidate_app, installed)
    candidate = run(installed, base, "transcript", meeting_id, "--require-complete")
    candidate_export = root / "candidate-export.json"
    run(installed, base, "export", meeting_id, "--format", "json", "--output", str(candidate_export))
    first = json.loads(previous_export.read_text())["data"]
    second = json.loads(candidate_export.read_text())["data"]
    assert previous["schema_version"] == "1" and candidate["schema_version"] == "2"
    assert first["meeting_id"] == second["meeting_id"] == meeting_id
    assert second["content_state"] == "complete"
    assert first["summary"]["text"] == second["summary"]["text"] == document["summary"]["text"]
    for key in ["segment_id", "chunk_id", "source", "start", "end", "text"]:
        assert first["segments"][0][key] == second["segments"][0][key]
    after = tree(root)
    assert all(after.get(path) == digest for path, digest in before.items()), "Upgrade/read modified synthetic source data"
    print(json.dumps({"previous": info(args.previous_app), "candidate": info(args.candidate_app), "os": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(), "architecture": subprocess.check_output(["uname", "-m"], text=True).strip(), "result": "PASS", "checks": ["actual bundle replacement", "historical custom paths", "meeting ID and count", "timestamped transcript", "legacy summary fingerprint", "JSON export", "source bytes unchanged"]}, ensure_ascii=False, indent=2))

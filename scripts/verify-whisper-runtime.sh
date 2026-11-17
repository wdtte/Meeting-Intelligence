#!/bin/zsh
set -euo pipefail
app_path="${1:?Usage: verify-whisper-runtime.sh /path/to/Meeting Intelligence.app}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/meeting-whisper-smoke.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
"$app_path/Contents/MacOS/meeting" --help > "$scratch/help.txt"
rg -q 'macOS 15.0' "$scratch/help.txt"
# System speech synthesis only; never record a microphone or open user data.
say -r 160 -o "$scratch/speech.aiff" 'The meeting starts at nine. We will discuss the project plan tomorrow.'
afconvert -f WAVE -d LEI16@16000 -c 1 "$scratch/speech.aiff" "$scratch/speech.wav"
"$app_path/Contents/MacOS/meeting-whisper" \
  --model "$app_path/Contents/Resources/Whisper/ggml-base-q5_1.bin" \
  --file "$scratch/speech.wav" --language en --output-json \
  --output-file "$scratch/result" --no-prints --suppress-nst > /dev/null 2>&1
python3 - "$scratch/result.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    entries = json.load(source)['transcription']
text = ' '.join(entry['text'] for entry in entries).lower()
assert 'meeting' in text and 'project' in text, 'Synthetic speech was not recognized'
assert all(0 <= entry['offsets']['from'] < entry['offsets']['to'] for entry in entries), 'Invalid timestamps'
print('Verified offline Whisper recognition and CLI on this macOS runtime')
PY

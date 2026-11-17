# macOS 15 compatibility edition

Two build editions share the same application identity, storage locations, schema version 1, cloud transcription, summaries, and read-only CLI. Compatibility support requires a compatibility package; existing published releases do not gain macOS 15 support automatically.

| Edition | Minimum system | Local engine | Bundled model |
| --- | --- | --- | --- |
| `standard` (default) | macOS 26 | Apple SpeechTranscriber | None; Apple manages its own resources outside the app |
| `compatibility` | macOS 15 | whisper.cpp 1.8.2, multilingual Whisper base q5_1 | 59,707,625 bytes, included for offline use |

Use the standard edition on macOS 26+. The compatibility edition always uses Whisper, including when launched on a newer system. Chinese and English are supported initially. Recognition runs sequentially on a background queue, using CPU/Accelerate with at most four threads; recordings continue independently if recognition is slower than real time. The engine reloads the model for each closed audio chunk. This bounds integration complexity but adds startup overhead; benchmark long meetings on older Intel hardware before promising live transcription throughput.

Both editions use ad-hoc signing in releases and are not notarized by Apple. If macOS blocks the first launch, dismiss the warning with **Done**, then open **System Settings → Privacy & Security → Security → Open Anyway** and authenticate and confirm when prompted. See the README's [English installation steps](../README.md#download-a-release) or [简体中文安装步骤](../README.md#下载发布版本) for the full procedure, including what to do if the button is missing.

## Build and package

Build with Swift 6.2+ and the macOS 26+ SDK for either edition. A newer SDK can target an older runtime. Compatibility builds also require CMake 3.21+ and network access at build time to fetch pinned whisper.cpp sources and model weights. End users need neither CMake nor an initial model download.

```sh
# Standard: no Whisper downloads, backend, licenses, or weights in the app.
./scripts/build-app.sh release
./scripts/package-release.sh

# Compatibility: isolated Swift/Cargo outputs and a separate app folder.
MEETING_BUILD_EDITION=compatibility ./scripts/build-app.sh release
./scripts/package-release.sh dist 'build/compatibility/Meeting Intelligence.app'
```

Install Node.js 24 and run `npm ci --prefix scripts/dmg` before packaging either edition. Standard asset names remain `Meeting-Intelligence-X.Y.Z-macos-ARCH.{dmg,zip}`. Compatibility assets append `-macos15-whisper` before the extension. Both formats have SHA-256 sidecars. No version bump or release tag is required for development.

`Helpers/whisper/manifest.json` pins source revision/archive checksum and model URL/checksum. Downloads and binaries remain under ignored `build/whisper/`. The app bundles only the static `meeting-whisper` executable, weights, manifest, and third-party license notices. No Homebrew dylibs, external model path, or runtime download is required. Preserve the MIT notices from OpenAI and the ggml authors and the decoder licenses when distributing compatibility packages. The standard app excludes Whisper implementation through a compile condition and strips any stale optional assets when rebuilt.

## Recognition and data compatibility

The existing audio conversion produces temporary 16 kHz mono PCM WAV, with phase-safe downmixing and a conservative silence gate. Whisper runs as a subprocess with explicit arguments, no shell, no transcript output in logs, and a 180-second per-chunk timeout. Pause/cancel terminates inference; an unresponsive process is killed after one second. Temporary WAV/JSON files are deleted on completion or failure. The original recordings remain available for retry.

Whisper's millisecond offsets are converted to the meeting timeline and clipped to the original chunk. Chinese output is normalized to Simplified Chinese to match the language picker. Track provenance remains `application`/`microphone`; it does not claim speaker diarization. New segments identify their engine. Missing engine fields in old transcripts still mean Apple SpeechTranscriber; resumed meetings can contain both engines without relabeling old results. No migration or rewriting of existing files is needed. The two editions use the same Bundle ID; install one at a time and quit the old app before replacing it.

## Verification

```sh
./scripts/test.sh
MEETING_BUILD_EDITION=compatibility ./scripts/test.sh
cargo test --locked --manifest-path Helpers/summary/Cargo.toml
python3 scripts/verify-app.py 'build/Meeting Intelligence.app'
python3 scripts/verify-app.py 'build/compatibility/Meeting Intelligence.app'
./scripts/verify-whisper-runtime.sh 'build/compatibility/Meeting Intelligence.app'
```

Routine tests use mock helpers and synthetic audio, including cancellation, forced termination, malformed output, track/timestamp mapping, silence, and corrupt/missing resources. The optional `MEETING_SPEECH_FIXTURE` test also exercises actual recognition and the full disk-backed two-track coordinator; use synthesized speech only.

Build/package verification checks signatures, deployment targets for all executables, native architecture, system-only dylib dependencies, model checksum and licenses, and absence of models/Whisper files in standard apps. DMGs are mounted read-only for the same checks. Release CI builds both editions on both architectures, then runs the compatibility CLI and actual Whisper inference with synthesized speech on macOS 15 runners before publication. Ordinary CI tests both editions without downloading models or compiling release binaries.

Compilation targeting macOS 15 and inference on a newer host do not replace macOS 15 execution. Full UI startup, system-audio/microphone permissions, Bluetooth/device recovery, sleep/wake, and a long dual-track meeting remain manual release checks on macOS 15, especially Intel. The macOS 15 workflow jobs must pass before publishing compatibility assets.

# v0.3.1 — Import exported meetings from HTML

## Changes / 更新

- The existing sidebar Import entry now accepts Meeting Intelligence HTML exports alongside WAV/M4A/MP3 audio. Restore embedded audio, subtitles and summary directly, without an API key, upload or local speech model. The original audio-file cloud import flow remains available.
- Restore title, exact subtitle timestamps/text, source/engine labels, speaker names and current summary text/model. Embedded audio is normalized into independent PCM chunks using the existing cancellable importer and publication journal. Deleting the original HTML does not break playback. Transcript-only HTML imports as readable content without audio.
- 现有“导入…”入口支持本应用导出的 HTML／HTM：恢复内嵌音频、字幕、发言人和摘要，无需 Key、不重复转写；兼容旧版 HTML 和纯转写导出。未完成的快照继续显示为部分内容，重新打开不会转写或上传。主动云端重转写合并音轨时替换已有字幕，避免不同来源的旧字幕重复。
- New HTML exports include locale, completion and speaker identity hints, preserving distinct speakers with identical names. Historical HTML lacks explicit IDs; it groups matching source/name pairs. HTML imports support embedded WAV/M4A/MP3 only, reject external audio URLs and invalid timelines, and never execute scripts or resolve external entities. Limits: 512 MiB per HTML, 8 MiB of markup/text, plus existing audio limits.

## Compatibility / 兼容性

Disk and CLI schemas remain **v2**, with v1/v2 reads. Imports create new IDs and do not modify or migrate existing meetings. No original paths, cloud tasks, provider checkpoints, token usage or keys are restored from HTML. Existing backup, journal recovery and metadata-restore protections remain in place. Text-only imports have no playable audio; their last subtitle timestamp is retained in import metadata. CLI require-complete rejects partial HTML snapshots.

数据格式不变；新导入记录使用 v2，旧会议不改写。数据和 Keychain 位于应用包之外，升级前退出旧应用并备份所有自定义／历史音频和转写目录。元数据备份不包含音频；旧版程序不能读取 v2，降级仍需匹配备份及另行保存后续变更。

## Validation / 验证

All checks use synthetic content and temporary libraries, with no real meeting recordings or paid provider requests.

- Swift: standard **153 tests** (6 app, 126 core, 21 CLI), compatibility **162 tests** (6 app, 135 core, 21 CLI). Rust: **15 tests**.
- HTML tests cover current and historical exports, exact UTF-8/newline/entity preservation, speaker overrides and identical names, owned audio after source deletion, summary fingerprint rebinding, transcript-only/partial snapshots, import selection in AppModel, no automatic ASR/cloud/summary requests, malformed/remote/entity inputs, size/timeline limits, cancellation, and both publication recovery boundaries.
- Native app release builds and DMG verification check signatures, resources, deployment targets, architecture, model isolation, mounted app contents and checksums. GitHub Release validates both architectures and editions, including macOS 15 compatibility runtime and the existing packaged v0.2.6 upgrade check, before publication.

Human listening and interactive UI checks are not part of this automated acceptance. Packages use ad-hoc signing and are **not notarized**.

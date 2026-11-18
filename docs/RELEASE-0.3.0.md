# v0.3.0 — Audio import, speakers and safe upgrades

## Changes / 更新

- Import a single WAV, M4A or MP3 into owned, frame-accurate PCM audio. Cloud-only import never prepares Apple/Whisper ASR. Preview duration, region, diarization and automatic summary before upload; cancel import safely.
- Qwen source-scoped long tasks preserve opening silence and gaps, resume saved task IDs, and keep successful results when another source fails. Speaker names and sentence corrections apply to transcript, summary, HTML and CLI exports. A new run keeps previous results and usage.
- 导入 WAV／M4A／MP3，直接云端转写；支持按来源的发言人区分、命名、逐句归属修正、回听和摘要。区分发言人的产品上限为每任务 120 分钟；关闭后仍校验独立文件限制。

## Disk and CLI compatibility / 格式兼容

New meetings use disk schema **2**; the app reads **1 and 2**. Browsing old meetings does not migrate or upload them. Using new features on an old meeting requires explicit v1 → v2 confirmation. Original manifest/transcript bytes are backed up under ~/Library/Application Support/Meeting Intelligence/Backups/<migration-id>/ with SHA-256 and a durable recovery journal. Backups contain metadata, not audio or keys; separately copy all audio and custom/history directories for a complete backup.

新版 CLI 输出 schema_version **"2"**，即使读取 v1 数据也是如此。chunk_id 可空，source 增加 imported，并增加发言人、session、执行计划和完成进度字段。自动化消费者请先读取 meeting schema。CLI 保持只读。

Older apps reject v2. Installing an older app alone does not downgrade data. Settings → Restore metadata backup verifies the backup and all targets, saves current metadata, and refuses conflicts from post-migration edits. Preserve those edits separately before resolving a conflict. New meetings outside that journal are retained. Backups are never automatically pruned. Bundle ID, storage locations, preference keys and Keychain identifiers are unchanged; an ad-hoc signed replacement may require renewed Keychain authorization.

## Acceptance evidence / 验收记录

All checks use synthetic audio, temporary libraries and mocked HTTP; no real meetings or paid provider requests.

- Swift suites: standard 144 tests (5 app + 118 core + 21 CLI), compatibility 153 tests (5 app + 127 core + 21 CLI); Rust 15 tests. Coverage includes: import formats/invalid inputs/cancellation, phase-safe conversion, initial silence/gaps/same-source overlaps, task-scoped identities, cross-chunk sentences, legacy summary fingerprints, manual attribution, schema/export completeness and usage.
- Durable migration and restore: exact original bytes, both replacement boundaries interrupted by an injected disk-write failure, repeated recovery, future/corrupt isolation, conflict protection, bad backup rejection and exclusive app writer lease.
- Mock Qwen requests verify diarization fields and 181 running polls beyond the former 180-poll budget. Reopening completed imports does not upload again. Provider contract details: [QWEN-FILETRANS-CONTRACT.md](QWEN-FILETRANS-CONTRACT.md).
- Local release builds verify ad-hoc signatures, deployment targets, resources and model isolation for both editions. Packaging checks mount DMGs read-only and validate app contents and checksums.
- scripts/verify-upgrade.py replaces an installed **actual v0.2.6 release bundle** with the candidate, reads and exports a synthetic v1 meeting from historical custom directories, compares ID/text/timestamps/summary and verifies all source bytes remain unchanged. Run in each architecture/edition Release job; logs record package version, commit, architecture and OS.
- Local host: arm64, macOS 27.2.1. CI Release matrix validates arm64/x86_64, standard/compatibility; compatibility runtime additionally executes synthetic speech on macOS 15. Workflow completion is the authoritative remote result.

Not executed: human speaker-quality evaluation, real Keychain/recording-permission dialogs, and interactive UI playback/HTML listening. Synthetic timeline/codec and export tests validate engineering behavior; they do not establish real diarization accuracy or account-specific Qwen availability. Packages retain ad-hoc signing and are **not notarized**.

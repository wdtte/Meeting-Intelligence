# Data format and upgrade compatibility

App versions and build numbers are independent of disk formats. v0.2.6 writes disk v1. This release writes v2 for new meetings and reads v1/v2. Opening an existing meeting does not migrate, upload or regenerate its summary. Bundle ID, data directories, UserDefaults keys and Keychain service/account names remain unchanged.

| Type | Required legacy fields | Optional/default semantics |
| --- | --- | --- |
| Recording | schemaVersion, id, title, applicationName, bundleIdentifier, startedAt, status, chunks | Existing optional metadata absent remains nil; absent origin means recorded; absent transcriptionPlan means localThenCloud |
| AudioChunk | id, fileName, offset, duration, sampleRate, channels, isComplete | absent source means application; v2 adds imported |
| TranscriptDocument | schemaVersion, recordingID, locale, engine, segments, processedChunks, status | error/cloud/summary absent remain nil; absent speaker/session/override collections are empty views |
| TranscriptSegment | id, source, start, end, text; v1 chunkID | absent engine means historical Apple provenance; v2 chunkID may be null, sessionID/speakerID/providerSpeakerID optional |
| Cloud configuration | provider, region, workspaceID, skipSilence | absent diarizationEnabled means false; absent strategy means legacyChunks; no old job is automatically converted or resubmitted |
| Cloud progress | runID, configuration, jobs, status | absent sessions/history means legacy-only; old jobs retain checkpoints and usage |
| Storage settings | audioDirectory, transcriptDirectory | absent audioHistoryDirectories defaults to saved audioDirectory; unversioned settings are legacy; explicit v1 accepted, invalid/future versions rejected |

Malformed enums/types fail decoding. Raw schema preflight runs before recovery writes. Future versions, corrupt JSON and access errors preserve original files. Known objects retain unknown JSON fields on ordinary metadata saves; removed array elements and job/override entries stay removed. The CLI reads only and uses the same version checks.

## On-demand v1 to v2 migration

Only explicitly enabling v2 functionality migrates a v1 meeting. Older apps cannot open v2. Before replacement, original manifest/transcript bytes are saved under ~/Library/Application Support/Meeting Intelligence/Backups/<migration-id>/. Journals record original paths, file sizes, SHA-256, versions, application version, prepared replacement hashes and state. This is a metadata backup, not an audio disaster-recovery backup. Copy audio and all current/history/custom directories separately. Keychain secrets are never exported.

The app holds a lifetime writer lease. Migration uses a separate nonblocking lock, validates complete audio references, rejects symlink targets, verifies all backups/targets, and replaces each target atomically on its own volume. A durable journal precedes the first replacement; no cross-volume atomicity is claimed. Startup finishes prepared transactions before recording recovery/background work. Modified targets and corrupt backups stop recovery. The CLI reports MIGRATION_BUSY for incomplete journals and never repairs them.

Settings provides Open migration backups and Restore metadata backup. Restore verifies all targets, preserves current metadata alongside the journal, and journals progress for interrupted restore recovery. Changes after migration trigger conflicts and block replacement. Copy the current library and resolve conflicting copies before restoring. New meetings outside the journal remain untouched. Backups are never automatically pruned. Downgrade requires matching v1 backup copies plus separately preserving post-backup changes; installing an old app alone is insufficient.

## Import publication

Single-file import uses private .import-<UUID> staging under the chosen audio root. One continuous resampler produces 16 kHz mono PCM split into frame-accurate chunks without capture gain. Manifest and pending transcript form the publication journal. Transcript writes occur on their target volume before a same-volume directory rename publishes the meeting. Startup discards unpublished staging with a re-import notice and finishes pending transcripts for published meetings. Cancellation removes only this import's staging. Source paths are not persisted.

### HTML snapshot import (v0.3.1)

HTML imports reuse the same staging, PCM normalization, cancellation and publication journal as audio imports. Disk and public CLI schemas remain v2; existing v1/v2 libraries are untouched. Each import allocates a new recording ID and fresh segment/speaker/session identities. Recording origin is imported, importMetadata.format is html, automaticSummary is false, and the existing localThenCloud plan has all imported chunks marked processed. No cloud configuration, tasks, checkpoints, token usage, source paths or keys are restored. Loading/submitting an HTML snapshot without an explicit cloud configuration never schedules ASR or changes a partial snapshot to complete.

Transcript sources and timestamps retain their exported provenance; owned merged-audio chunks use imported. Summary text/model are reattached with a fingerprint of the new document. Text-only exports have no chunks and duration 0 for audio/playback; importMetadata.duration records the latest subtitle end. Incomplete exports use interrupted transcript status and a recording notice, so CLI require-complete rejects them. Missing speaker IDs in historical HTML group matching source/name pairs; v1 HTML export metadata adds locale, completeness and explicit speaker identities for reliable future round trips, without paths or provider checkpoints. No existing metadata is rewritten or migrated by import.

The parser uses system libxml2 in offline HTML mode; it never executes scripts, resolves external entities or follows audio URLs. Base64 is validated and decoded in bounded blocks. HTML input is capped at 512 MiB, markup/text at 8 MiB; audio must pass the existing codec/duration/size checks, and subtitle times must fit embedded audio. Historical fixture, synthetic round trips, source deletion, partial CLI completeness, exact-byte preservation, cancellation and both journal recovery boundaries are covered in MeetingHTMLImportTests.swift alongside existing migration/restore suites.

## Public CLI v2

CLI envelopes advertise schema_version "2" even for disk v1. Segments add nullable session_id, speaker_id and speaker_name; chunk_id is nullable; source adds imported. Metadata adds origin, transcription_plan, cloud_session_count and cloud_completed_session_count. Cloud-only meetings have local_status not_requested, null local_completion_ratio, and completion based on required sessions and complete audio. Provider task IDs, credential identifiers and signed URLs are absent. Consumers should fetch meeting schema.

## Verification

AudioImportSafetyTests.swift and existing CLI suites cover v1 fingerprints/unknown fields, v2 round trips, corrupt/future isolation, original-byte backups, interrupted commit replay, conflicting restore, damaged backups, writer ownership, import cancellation and local-model independence. Tests use synthetic audio, temporary directories and mock providers, with no real library or paid requests. Live Keychain dialogs and real speaker accuracy require separate manual evaluation.

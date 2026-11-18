import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import MeetingCore

private func testRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("ImportSafety-\(UUID())") }
private func syntheticAudio(_ url: URL, rate: Double = 44100, seconds: Double = 0.4, stereo: Bool = true) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: stereo ? 2 : 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate * seconds))!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        let sample = Float(sin(Double(frame) * 2 * .pi * 440 / rate)) * 0.1
        for channel in 0..<Int(format.channelCount) { buffer.floatChannelData![channel][frame] = channel == 0 ? sample : -sample }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}
private func sessionFixture() -> (TranscriptDocument, CloudTranscriptionSession, CloudTranscriptionSession) {
    let config = CloudTranscriptionConfiguration(diarizationEnabled: true, strategy: .sourceSessions)
    let chunks = [AudioChunk(source: .application, fileName: "a.wav", offset: 0, duration: 10, sampleRate: 16000, channels: 1, isComplete: true),
                  AudioChunk(source: .application, fileName: "b.wav", offset: 10, duration: 10, sampleRate: 16000, channels: 1, isComplete: true)]
    var document = TranscriptDocument(recordingID: UUID(), locale: "zh-CN")
    document.cloud = CloudTranscriptionProgress(configuration: config)
    let a = CloudTranscriptionSession(runID: document.cloud!.runID, source: .application, chunks: chunks, fingerprint: "a", configuration: config)
    var mic = chunks; for i in mic.indices { mic[i].source = .microphone }
    let b = CloudTranscriptionSession(runID: document.cloud!.runID, source: .microphone, chunks: mic, fingerprint: "b", configuration: config)
    document.cloud?.sessions = [a, b]
    return (document, a, b)
}
@Test func sessionIdentityCrossChunkCommitEditsAndSummaryFingerprint() throws {
    var (document, a, b) = sessionFixture()
    var segment = TranscriptSegment(chunkID: nil, source: .application, start: 9.5, end: 10.5, text: "周五发布")
    segment.providerSpeakerID = "0"
    try document.commitSessionResult(.init(segments: [segment]), session: a)
    let speakerA = try #require(document.segments.first?.speakerID)
    let before = document.summaryRequest.fingerprint
    #expect(document.segments.first?.chunkID == nil)
    #expect(document.summaryRequest.text.contains("发言人 1"))
    try document.renameSpeaker(speakerA, name: "<李明>")
    #expect(document.summaryRequest.fingerprint != before)
    try document.commitSessionResult(.init(segments: [segment]), session: a)
    #expect(document.segments.count == 1)
    #expect(document.segments[0].speakerID == speakerA)
    segment.source = .microphone
    try document.commitSessionResult(.init(segments: [segment]), session: b)
    #expect(Set(document.segments.compactMap(\.speakerID)).count == 2)
    let id = document.segments[0].id
    try document.assignSpeaker(segmentID: id, speakerID: nil)
    #expect(document.speakerName(for: document.segments[0]) == "未区分发言人")
    let restored = try JSONDecoder().decode(TranscriptDocument.self, from: DiskFormat.encode(document))
    #expect(restored == document)
}
@Test func sessionsRejectWrongSourcesUnsortedTimesAndMissingTimestamps() throws {
    var (document, session, _) = sessionFixture()
    let wrong = TranscriptSegment(chunkID: nil, source: .microphone, start: 0, end: 1, text: "x")
    #expect(throws: MeetingError.self) { try document.commitSessionResult(.init(segments: [wrong]), session: session) }
    let first = TranscriptSegment(chunkID: nil, source: .application, start: 2, end: 3, text: "x")
    let second = TranscriptSegment(chunkID: nil, source: .application, start: 1, end: 2, text: "y")
    #expect(throws: MeetingError.self) { try document.commitSessionResult(.init(segments: [first, second]), session: session) }
    let missing = Data(#"{"transcripts":[{"channel_id":0,"text":"untimed"}]}"#.utf8)
    #expect(throws: MeetingError.self) { try QwenTranscriptionProvider.parse(missing, input: .init(session: session), sessionID: session.id) }
    let valid = Data(#"{"transcripts":[{"channel_id":0,"text":"x","sentences":[{"begin_time":9500,"end_time":10500,"text":"x","speaker_id":0}]}]}"#.utf8)
    let result = try QwenTranscriptionProvider.parse(valid, input: .init(session: session), sessionID: session.id)
    #expect(result.segments[0].start == 9.5)
    #expect(result.segments[0].providerSpeakerID == "0")
}
@Test func importingPreservesSourceFramesPhaseAndSurvivesSourceDeletion() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    let url = root.appendingPathComponent("Synthetic.wav")
    try syntheticAudio(url, seconds: 10.13)
    let original = try Data(contentsOf: url)
    let recording = try await AudioImporter.run(url: url, store: store, transcriptDirectory: root.appendingPathComponent("Transcripts"),
        configuration: .init(diarizationEnabled: true), locale: "zh-CN", automaticSummary: false)
    #expect(recording.effectivePlan == .cloudOnly)
    #expect(recording.chunks.count == 2)
    #expect(abs(recording.duration - 10.13) < 0.02)
    #expect(try Data(contentsOf: url) == original)
    #expect(!(try String(contentsOf: store.directory(for: recording.id).appendingPathComponent("recording.json"), encoding: .utf8)).contains(url.path))
    try FileManager.default.removeItem(at: url)
    for chunk in recording.chunks {
        let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
        #expect(abs(Double(file.length) / 16000 - chunk.duration) < 0.001)
    }
    let normalized = try await CloudSessionAudioBuilder.build(chunks: recording.chunks, store: store, recordingID: recording.id)
    defer { try? FileManager.default.removeItem(at: normalized) }
    let input = try AVAudioFile(forReading: normalized)
    let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1000)!
    try input.read(into: buffer)
    #expect((0..<Int(buffer.frameLength)).map { abs(buffer.floatChannelData![0][$0]) }.max()! > 0.05)
    #expect(try store.loadAll().count == 1)
}
@Test func sourceTrackKeepsInitialSilenceGapsAndDuration() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording.systemAudio(title: "fixture"); try store.save(recording)
    for (index, offset) in [0.25, 0.9].enumerated() {
        let name = "\(index).wav"
        try syntheticAudio(store.directory(for: recording.id).appendingPathComponent(name), rate: 48000, seconds: 0.2, stereo: true)
        recording.chunks.append(AudioChunk(source: .application, fileName: name, offset: offset, duration: 0.2, sampleRate: 48000, channels: 2, isComplete: true))
    }
    let url = try await CloudSessionAudioBuilder.build(chunks: recording.chunks, store: store, recordingID: recording.id)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    #expect(file.length == 17600)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
    try file.read(into: buffer)
    let samples = buffer.floatChannelData![0]
    #expect(abs(samples[1000]) < 0.0001)
    #expect(abs(samples[9000]) < 0.0001)
    #expect((4000..<7200).map { abs(samples[$0]) }.max()! > 0.05)
    #expect((14400..<17600).map { abs(samples[$0]) }.max()! > 0.05)
}
@Test func migrationPreservesOriginalBytesRecoversPartialCommitAndRejectsConflictingRestore() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("External"))
    var recording = Recording.systemAudio(title: "legacy"); recording.schemaVersion = 1; recording.status = .completed
    let transcript = root.appendingPathComponent("OldTranscripts/data.json")
    recording.transcriptPath = transcript.path
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN"); document.schemaVersion = 1
    try store.save(recording); try document.save(to: transcript)
    let manifest = store.directory(for: recording.id).appendingPathComponent("recording.json")
    let original = try Data(contentsOf: manifest), originalTranscript = try Data(contentsOf: transcript)
    let migration = DataMigration(base: root.appendingPathComponent("ApplicationData"))
    let backup = try #require(try migration.upgrade(manifest: manifest, transcript: transcript))
    #expect(try Data(contentsOf: backup.appendingPathComponent("0.original")) == original)
    #expect(try Data(contentsOf: backup.appendingPathComponent("1.original")) == originalTranscript)
    #expect(try DiskFormat.version(Data(contentsOf: transcript)) == 2)
    // Simulate interruption after the first of two target replacements.
    try originalTranscript.write(to: transcript)
    let journalURL = backup.appendingPathComponent("journal.json")
    var journal = try JSONDecoder().decode(DataMigration.Journal.self, from: Data(contentsOf: journalURL)); journal.state = "prepared"
    try DiskFormat.encode(journal).write(to: journalURL)
    try migration.recover(); try migration.recover()
    #expect(try DiskFormat.version(Data(contentsOf: transcript)) == 2)
    #expect(try migration.upgrade(manifest: manifest, transcript: transcript) == nil)
    try migration.restore(folder: backup)
    #expect(try Data(contentsOf: manifest) == original)
    #expect(try Data(contentsOf: transcript) == originalTranscript)
    let next = try #require(try migration.upgrade(manifest: manifest, transcript: transcript))
    var updated = try DiskFormat.read(Recording.self, at: manifest); updated.title = "new edit"; try store.save(updated)
    #expect(throws: MeetingError.self) { try migration.restore(folder: next) }
    #expect(try DiskFormat.read(Recording.self, at: manifest).title == "new edit")
}
@Test func futureFormatsAndCorruptRecordsNeverOverwriteOriginals() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    let recording = Recording.systemAudio(title: "good"); try store.save(recording)
    let future = root.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: future, withIntermediateDirectories: true)
    let url = future.appendingPathComponent("recording.json")
    let bytes = Data(#"{"schemaVersion":99}"#.utf8); try bytes.write(to: url)
    let catalog = try store.loadCatalog(recover: false)
    #expect(catalog.recordings.count == 1); #expect(catalog.warnings.count == 1)
    #expect(throws: MeetingReadError.self) { try DiskFormat.write(recording, to: url) }
    #expect(try Data(contentsOf: url) == bytes)
}
@Test func cloudOnlyCompletenessDoesNotInventLocalSuccess() throws {
    var (document, a, _) = sessionFixture()
    var recording = Recording.systemAudio(title: "import"); recording.transcriptionPlan = .cloudOnly; recording.status = .completed
    recording.cloudTranscription = a.configuration
    recording.chunks = a.chunkIDs.enumerated().map { AudioChunk(id: $0.element, source: .imported, fileName: "\($0.offset).wav", offset: Double($0.offset * 10), duration: 10, sampleRate: 16000, channels: 1, isComplete: true) }
    document.recordingID = recording.id; document.status = "not_requested"
    var session = a; session.source = .imported; session.status = "completed"; session.noSpeechRecognized = true
    document.cloud?.sessions = [session]; document.cloud?.status = "completed"
    let snapshot = MeetingReadSnapshot(recording: recording, transcript: document, transcriptURL: URL(fileURLWithPath: "/unused"), revision: "fixture")
    #expect(snapshot.contentState == "complete")
    let metadata = AgentTranscriptExport.metadata(snapshot)
    #expect(metadata["local_status"] as? String == "not_requested")
    #expect(metadata["local_completion_ratio"] is NSNull)
}

private actor SessionProviderFixture: TranscriptionProvider {
    nonisolated let id = TranscriptionProviderID.qwen
    nonisolated let engine = "Session fixture"
    var calls: [TranscriptionRequest] = []
    func prepare(locale: String) async throws -> String { locale }
    func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        calls.append(request)
        if request.checkpoint == nil { try await checkpoint(.init(phase: .submitted, taskID: "fixture-task", keyID: "fixture-key")) }
        var segment = TranscriptSegment(chunkID: nil, source: request.input.audioSource, start: 0.02, end: min(0.3, request.input.duration), text: "确认发布")
        segment.providerSpeakerID = "0"; segment.sessionID = request.sessionID
        return .init(segments: [segment], usage: .init(inputTokens: 10, outputTokens: 2))
    }
}
@Test @MainActor func cloudOnlyNeverPreparesLocalModelAndCountsSessionOnce() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    let url = root.appendingPathComponent("source.wav"); try syntheticAudio(url)
    let recording = try await AudioImporter.run(url: url, store: store, transcriptDirectory: root.appendingPathComponent("Transcripts"), configuration: .init(diarizationEnabled: true), locale: "zh-CN", automaticSummary: false)
    let provider = SessionProviderFixture()
    let coordinator = TranscriptionCoordinator(prepare: { _ in Issue.record("must not prepare local model"); throw CancellationError() }, recognize: { _, _, _ in Issue.record("must not run local ASR"); throw CancellationError() }, cloudFactory: { _ in provider }, summaryFactory: { nil })
    coordinator.load(recording); coordinator.submit(recording, store: store)
    await coordinator.wait(for: recording.id)
    let document = try #require(coordinator.documents[recording.id])
    #expect(document.status == "not_requested")
    #expect(document.processedChunks.isEmpty)
    #expect(document.cloud?.status == "completed")
    #expect(document.segments.count == 1)
    #expect(document.cloud?.sessions?.count == 1)
    coordinator.submit(recording, store: store, retry: true); await coordinator.wait(for: recording.id)
    #expect(await provider.calls.count == 1)
    let reopened = TranscriptionCoordinator(prepare: { _ in Issue.record("local prepare after reopen"); return "" }, recognize: { _, _, _ in [] }, cloudFactory: { _ in provider }, summaryFactory: { nil })
    reopened.load(recording); reopened.submit(recording, store: store, retry: true); await reopened.wait(for: recording.id)
    #expect(await provider.calls.count == 1)
    let report = APIUsageReport(recordings: [recording], documents: [recording.id: document], days: nil)
    #expect(report.transcription.resultCount == 1)
    #expect(report.transcription.inputTokens == 10)
    let snapshot = MeetingReadSnapshot(recording: recording, transcript: document, transcriptURL: URL(fileURLWithPath: recording.transcriptPath!), revision: "fixture")
    #expect(snapshot.contentState == "complete")
    let exported = String(decoding: try AgentTranscriptExport.json(AgentTranscriptExport.snapshot(snapshot)), as: UTF8.self)
    #expect(exported.contains("speaker_name")); #expect(!exported.contains("fixture-task")); #expect(!exported.contains("fixture-key"))
}
@Test func versionOneSummaryAndUnknownFieldsSurviveOrdinarySaveWithoutMigration() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("transcript.json")
    let recordingID = UUID(), chunkID = UUID(), segmentID = UUID()
    let legacy = """
    {"schemaVersion":1,"recordingID":"\(recordingID)","locale":"zh-CN","engine":"Apple SpeechTranscriber","segments":[{"id":"\(segmentID)","chunkID":"\(chunkID)","source":"application","start":0,"end":1,"text":"合成历史文字","futureSegmentField":"retained"}],"processedChunks":["\(chunkID)"],"status":"completed","futureTopField":{"keep":true}}
    """
    try Data(legacy.utf8).write(to: url)
    var document = try TranscriptDocument.load(from: url, recordingID: recordingID)
    // Reconstruct the exact v1 fingerprint JSON, excluding future fields.
    var oldObject = try JSONSerialization.jsonObject(with: Data(legacy.utf8)) as! [String: Any]
    var segment = (oldObject["segments"] as! [[String: Any]])[0]; segment.removeValue(forKey: "futureSegmentField")
    let payload: [String: Any] = ["recordingID": recordingID.uuidString, "locale": "zh-CN", "segments": [segment]]
    let oldFingerprint = DataMigration.hash(try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    #expect(document.summaryRequest.fingerprint == oldFingerprint)
    document.summary = TranscriptSummary(inputFingerprint: oldFingerprint); document.summary?.status = "completed"; document.summary?.text = "旧摘要"
    try document.save(to: url)
    #expect(try DiskFormat.version(Data(contentsOf: url)) == 1)
    let saved = try TranscriptDocument.load(from: url, recordingID: recordingID)
    #expect(saved.currentSummary?.text == "旧摘要")
    oldObject = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    #expect((oldObject["futureTopField"] as? [String: Bool])?["keep"] == true)
    #expect((oldObject["segments"] as? [[String: Any]])?.first?["futureSegmentField"] as? String == "retained")
}
@Test func importValidationRejectsMislabeledEmptyAndOverLimitAudio() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("fixture.wav"); try syntheticAudio(source)
    let wrong = root.appendingPathComponent("pretend.mp3"); try FileManager.default.copyItem(at: source, to: wrong)
    #expect(throws: MeetingError.self) { _ = try AudioImporter.inspect(wrong) }
    let empty = root.appendingPathComponent("empty.wav"); try Data().write(to: empty)
    #expect(throws: (any Error).self) { _ = try AudioImporter.inspect(empty) }
    #expect(throws: MeetingError.self) { try CloudAudioLimits.validate(duration: 7200.1, diarization: true) }
    try CloudAudioLimits.validate(duration: 7200.1, diarization: false)
    #expect(throws: MeetingError.self) { try CloudAudioLimits.validate(duration: .infinity, diarization: false) }
}
@Test func importCancellationNeverPublishesOrChangesSource() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    let url = root.appendingPathComponent("source.wav"); try syntheticAudio(url)
    let original = try Data(contentsOf: url)
    let task = Task { try await AudioImporter.run(url: url, store: store, transcriptDirectory: root.appendingPathComponent("Transcripts"), configuration: .init(), locale: "zh-CN", automaticSummary: false) }
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled import published") } catch {}
    #expect(try store.loadAll().isEmpty)
    #expect(try Data(contentsOf: url) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
}
@Test func migrationRejectsDamagedBackupsAndWriterLeaseRejectsSecondInstance() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let lease = try LibraryWriterLease(base: root)
    #expect(throws: MeetingReadError.self) { _ = try LibraryWriterLease(base: root) }
    withExtendedLifetime(lease) {}
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    var recording = Recording.systemAudio(title: "legacy"); recording.schemaVersion = 1; try store.save(recording)
    let manifest = store.directory(for: recording.id).appendingPathComponent("recording.json")
    let migration = DataMigration(base: root)
    let folder = try #require(try migration.upgrade(manifest: manifest, transcript: nil))
    let bytes = try Data(contentsOf: manifest)
    try Data("corrupt".utf8).write(to: folder.appendingPathComponent("0.original"))
    #expect(throws: MeetingError.self) { try migration.restore(folder: folder) }
    #expect(try Data(contentsOf: manifest) == bytes)
}

@Test func importedM4AAndMP3DecodeUsingSystemCodecs() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    let wav = root.appendingPathComponent("synthetic.wav"); try syntheticAudio(wav, seconds: 0.5, stereo: false)
    let m4a = root.appendingPathComponent("synthetic.m4a")
    let convert = Process(); convert.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
    convert.arguments = ["-f", "m4af", "-d", "aac", wav.path, m4a.path]
    try convert.run(); convert.waitUntilExit(); #expect(convert.terminationStatus == 0)
    // Valid synthetic MPEG-1 Layer III silent frames: no external codec or real voice recording.
    let mp3 = root.appendingPathComponent("synthetic.mp3")
    var bytes = Data()
    for _ in 0..<40 { bytes.append(contentsOf: [0xff, 0xfb, 0x90, 0x64]); bytes.append(Data(repeating: 0, count: 413)) }
    try bytes.write(to: mp3)
    for url in [m4a, mp3] {
        let preview = try AudioImporter.inspect(url)
        #expect(preview.duration > 0)
        let recording = try await AudioImporter.run(url: url, store: store, transcriptDirectory: root.appendingPathComponent("Transcripts"), configuration: .init(), locale: "en-US", automaticSummary: false)
        #expect(abs(recording.duration - preview.duration) < 0.02)
        #expect(recording.chunks.allSatisfy { $0.audioSource == .imported && $0.isComplete })
    }
}

@Test func manualAttributionInvalidatesSummaryEvenWhenSpeakerIsUnchanged() throws {
    var (document, session, _) = sessionFixture()
    var segment = TranscriptSegment(chunkID: nil, source: .application, start: 1, end: 2, text: "明确承诺")
    segment.providerSpeakerID = "0"
    try document.commitSessionResult(.init(segments: [segment]), session: session)
    let current = document.summaryRequest.fingerprint
    let saved = try #require(document.segments.first)
    try document.assignSpeaker(segmentID: saved.id, speakerID: saved.speakerID)
    #expect(document.summaryRequest.fingerprint != current)
}
@Test func emptyHistoricalStorageHistoryDefaultsButInvalidHistoryFails() throws {
    let bytes = Data(#"{"audioDirectory":"file:///tmp/fixture-audio/","transcriptDirectory":"file:///tmp/fixture-text/"}"#.utf8)
    let settings = try JSONDecoder().decode(StorageSettings.self, from: bytes)
    #expect(settings.audioHistoryDirectories == [settings.audioDirectory])
    #expect(throws: (any Error).self) { _ = try JSONDecoder().decode(StorageSettings.self, from: Data(#"{"audioDirectory":"file:///tmp/a/","transcriptDirectory":"file:///tmp/t/","audioHistoryDirectories":"invalid"}"#.utf8)) }
    #expect(throws: MeetingReadError.self) { try StorageSettingsStore.checkVersion(Data(#"{"schemaVersion":99}"#.utf8)) }
}

@Test func migrationAndRestoreRecoverAtEveryReplacementBoundary() throws {
    for boundary in 0..<2 {
        let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
        var recording = Recording.systemAudio(title: "legacy"); recording.schemaVersion = 1
        let transcript = root.appendingPathComponent("ExternalText/legacy.json")
        recording.transcriptPath = transcript.path
        var document = TranscriptDocument(recordingID: recording.id, locale: "en-US"); document.schemaVersion = 1
        try store.save(recording); try document.save(to: transcript)
        let manifest = store.directory(for: recording.id).appendingPathComponent("recording.json")
        let originals = try [manifest, transcript].map { try Data(contentsOf: $0) }
        let interrupted = DataMigration(base: root, beforeReplace: { index in if index == boundary { throw MeetingError.message("synthetic disk failure") } })
        #expect(throws: MeetingError.self) { _ = try interrupted.upgrade(manifest: manifest, transcript: transcript) }
        #expect(throws: MeetingReadError.self) { try DataMigration.assertReadable(base: root) }
        let migration = DataMigration(base: root)
        try migration.recover(); try migration.recover()
        for url in [manifest, transcript] { #expect(try DiskFormat.version(Data(contentsOf: url)) == 2) }
        let backup = try #require(FileManager.default.contentsOfDirectory(at: migration.backupRoot, includingPropertiesForKeys: nil).first)
        #expect(throws: MeetingError.self) { try interrupted.restore(folder: backup) }
        #expect(throws: MeetingReadError.self) { try DataMigration.assertReadable(base: root) }
        try migration.recover(); try migration.recover()
        for (index, url) in [manifest, transcript].enumerated() { #expect(try Data(contentsOf: url) == originals[index]) }
        try DataMigration.assertReadable(base: root)
    }
}
@Test func overlappingSourceChunksRetainAbsoluteTimeline() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording.systemAudio(title: "overlap"); try store.save(recording)
    for (index, offset) in [0.0, 0.18].enumerated() {
        let name = "overlap-\(index).wav"
        try syntheticAudio(store.directory(for: recording.id).appendingPathComponent(name), rate: 16000, seconds: 0.2, stereo: false)
        recording.chunks.append(AudioChunk(source: .application, fileName: name, offset: offset, duration: 0.2, sampleRate: 16000, channels: 1, isComplete: true))
    }
    let result = try await CloudSessionAudioBuilder.build(chunks: recording.chunks, store: store, recordingID: recording.id)
    defer { try? FileManager.default.removeItem(at: result) }
    let file = try AVAudioFile(forReading: result)
    #expect(file.length == 6080)
    #expect(abs(Double(file.length) / 16000 - 0.38) < 0.001)
}

private actor PartialSessionProviderFixture: TranscriptionProvider {
    nonisolated let id = TranscriptionProviderID.qwen
    nonisolated let engine = "Partial session fixture"
    var calls: [AudioSource: Int] = [:]
    func prepare(locale: String) async throws -> String { locale }
    func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        let source = request.input.audioSource
        calls[source, default: 0] += 1
        if request.checkpoint == nil { try await checkpoint(.init(phase: .submitted, taskID: source.rawValue, keyID: "fixture")) }
        if source == .microphone, calls[source] == 1 { throw URLError(.networkConnectionLost) }
        if source == .microphone { #expect(request.checkpoint?.taskID == source.rawValue) }
        var segment = TranscriptSegment(chunkID: nil, source: source, start: 0.02, end: 0.2, text: source.label)
        segment.providerSpeakerID = "0"
        return .init(segments: [segment], usage: .init(inputTokens: 5, outputTokens: 1))
    }
}
@Test @MainActor func sourceFailureKeepsOtherResultAndResumesOnlySavedTask() async throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root.appendingPathComponent("Audio"))
    var recording = Recording.systemAudio(title: "source resume")
    recording.transcriptionPlan = .cloudOnly; recording.status = .completed; recording.automaticSummary = false
    let config = CloudTranscriptionConfiguration(diarizationEnabled: true, strategy: .sourceSessions)
    recording.cloudTranscription = config; recording.transcriptPath = root.appendingPathComponent("Transcript.json").path
    try store.save(recording)
    for source in [AudioSource.application, .microphone] {
        let name = source.rawValue + ".wav"
        try syntheticAudio(store.directory(for: recording.id).appendingPathComponent(name), rate: 16000, seconds: 0.4, stereo: false)
        recording.chunks.append(AudioChunk(source: source, fileName: name, offset: 0, duration: 0.4, sampleRate: 16000, channels: 1, isComplete: true))
    }
    try store.save(recording)
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    document.status = "not_requested"; document.cloud = .init(configuration: config)
    try document.save(to: URL(fileURLWithPath: recording.transcriptPath!))
    let provider = PartialSessionProviderFixture()
    func coordinator() -> TranscriptionCoordinator { .init(prepare: { _ in Issue.record("local prepare"); return "" }, recognize: { _, _, _ in [] }, cloudFactory: { _ in provider }, summaryFactory: { nil }) }
    let first = coordinator(); first.load(recording); first.submit(recording, store: store); await first.wait(for: recording.id)
    let partial = try #require(first.documents[recording.id])
    #expect(partial.cloud?.status == "interrupted")
    #expect(partial.segments.count == 1)
    #expect(partial.segments.first?.source == .application)
    let reopened = coordinator(); reopened.load(recording); reopened.submit(recording, store: store, retry: true); await reopened.wait(for: recording.id)
    let complete = try #require(reopened.documents[recording.id])
    #expect(complete.cloud?.status == "completed"); #expect(complete.segments.count == 2)
    #expect(await provider.calls[.application] == 1); #expect(await provider.calls[.microphone] == 2)
    #expect(Set(complete.speakers?.map { $0.id } ?? []).count == 2)
    #expect(APIUsageReport(recordings: [recording], documents: [recording.id: complete], days: nil).transcription.resultCount == 2)
}
@Test func storageDirectoryEditsPreserveUnknownConfigurationFields() throws {
    let root = testRoot(); defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageSettingsStore(base: root)
    var settings = StorageSettings.defaults(base: root)
    try store.save(settings, validating: settings.audioDirectory)
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsURL)) as! [String: Any]
    object["futurePreference"] = ["keep": true]
    try JSONSerialization.data(withJSONObject: object).write(to: store.settingsURL)
    settings = settings.changing(.transcript, to: root.appendingPathComponent("NewText"))
    try store.save(settings, validating: settings.transcriptDirectory)
    let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.settingsURL)) as! [String: Any]
    #expect((saved["futurePreference"] as? [String: Bool])?["keep"] == true)
}

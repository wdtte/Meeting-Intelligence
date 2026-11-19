import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func importHTMLFixture() throws -> (RecordingStore, Recording, TranscriptDocument) {
    let store = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("HTMLImportTests-\(UUID())"))
    var recording = Recording(title: "Review & <plan> {{TITLE}}", applicationName: "系统音频", bundleIdentifier: "fixture.private")
    recording.status = .completed
    try FileManager.default.createDirectory(at: store.directory(for: recording.id), withIntermediateDirectories: true)
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    buffer.frameLength = 48000
    for i in 0..<48000 { buffer.floatChannelData![0][i] = i < 16000 ? 0 : 0.1 * Float(sin(Double(i) * 0.1)) }
    let audio = try store.audioURL(recording: recording.id, fileName: "source.wav")
    do { let file = try CloudSessionAudioBuilder.pcmFile(audio); try file.write(from: buffer) }
    let chunk = AudioChunk(fileName: "source.wav", offset: 0, duration: 3, sampleRate: 16000, channels: 1, isComplete: true)
    recording.chunks = [chunk]
    var document = TranscriptDocument(recordingID: recording.id, locale: "en-US")
    document.status = "completed"; document.processedChunks = [chunk.id]
    let session = UUID()
    let first = Speaker(sessionID: session, providerSpeakerID: "0", displayName: "Alex & 李", createdOrder: 1)
    let second = Speaker(sessionID: session, providerSpeakerID: "1", displayName: "Alex & 李", createdOrder: 2)
    document.speakers = [first, second]
    document.segments = [
        TranscriptSegment(chunkID: chunk.id, source: .application, start: 1, end: 1.5, text: "<script>alert('x')</script> & \"quoted\"\n第二行"),
        TranscriptSegment(chunkID: chunk.id, source: .microphone, start: 2, end: 2.9, text: "周五发布。 data:audio/mp4;base64,example")
    ]
    document.segments[0].engine = "Qwen & <model>"; document.segments[0].speakerID = second.id
    document.segments[1].engine = "Apple SpeechTranscriber"; document.segments[1].speakerID = first.id
    document.speakerOverrides = [document.segments[0].id.uuidString: first.id, document.segments[1].id.uuidString: second.id]
    document.summary = TranscriptSummary(inputFingerprint: document.summaryRequest.fingerprint)
    document.summary?.status = "completed"
    document.summary?.text = "决定：周五发布。\n待办：<check> & {{SEGMENTS}}"
    document.summary?.model = "fixture-summary"
    return (store, recording, document)
}

@Test @MainActor func htmlImportRoundTripRestoresOwnedAudioTextSpeakersSummaryWithoutProviders() async throws {
    let (source, recording, document) = try importHTMLFixture()
    defer { try? FileManager.default.removeItem(at: source.root) }
    let url = source.root.appendingPathComponent("meeting.html")
    try await MeetingExporter.export(recording, transcript: document, store: source, kind: .transcriptAndAudio, to: url)
    let original = try Data(contentsOf: url)
    let preview = try await MeetingHTMLImporter.inspect(url)
    #expect(preview.isHTML && preview.hasAudio && preview.hasSummary && preview.isComplete)
    #expect(preview.segmentCount == 2 && preview.title == recording.title && abs(preview.duration - 3) < 0.02)
    let target = try RecordingStore(root: source.root.appendingPathComponent("Imported"))
    let imported = try await MeetingHTMLImporter.run(url: url, store: target, transcriptDirectory: source.root.appendingPathComponent("Transcripts"))
    #expect(try Data(contentsOf: url) == original)
    #expect(imported.id != recording.id && imported.title == recording.title && imported.origin == .imported)
    #expect(imported.cloudTranscription == nil && imported.automaticSummary == false)
    #expect(imported.chunks.allSatisfy { $0.audioSource == .imported })
    let restored = try TranscriptDocument.load(from: URL(fileURLWithPath: #require(imported.transcriptPath)), recordingID: imported.id)
    #expect(restored.locale == "en-US" && restored.status == "completed" && restored.cloud == nil)
    #expect(restored.segments.map(\.text) == document.segments.map(\.text))
    #expect(restored.segments.map(\.source) == document.segments.map(\.source))
    #expect(restored.segments.map(\.start) == [1, 2] && restored.segments.map(\.end) == [1.5, 2.9])
    #expect(restored.segments.allSatisfy { $0.chunkID == nil })
    #expect(restored.speakers?.count == 2)
    #expect(restored.segments[0].speakerID != restored.segments[1].speakerID)
    #expect(restored.speakerName(for: restored.segments[0]) == "Alex & 李")
    #expect(restored.currentSummary?.text == document.currentSummary?.text)
    #expect(restored.currentSummary?.model == "fixture-summary" && restored.currentSummary?.usage == nil)
    let snapshot = MeetingReadSnapshot(recording: imported, transcript: restored, transcriptURL: URL(fileURLWithPath: imported.transcriptPath!), revision: "fixture")
    try snapshot.requireTranscript(complete: true)
    let encoded = String(decoding: try DiskFormat.encode(restored), as: UTF8.self)
    #expect(!encoded.contains(source.root.path) && !encoded.contains("fixture.private"))
    try FileManager.default.removeItem(at: url)
    let playable = try #require(imported.chunks.first)
    let file = try AVAudioFile(forReading: target.audioURL(recording: imported.id, fileName: playable.fileName))
    #expect(file.length > 0 && abs(imported.duration - 3) < 0.02)
    let coordinator = TranscriptionCoordinator(prepare: { _ in Issue.record("HTML import prepared local ASR"); return "en-US" },
        recognize: { _, _, _ in Issue.record("HTML import transcribed audio"); return [] },
        cloudFactory: { _ in Issue.record("HTML import contacted cloud"); throw MeetingError.message("unexpected") },
        summaryFactory: { Issue.record("HTML import generated a summary"); return nil })
    coordinator.load(imported); coordinator.submit(imported, store: target); await coordinator.wait(for: imported.id)
    #expect(coordinator.documents[imported.id]?.currentSummary?.text == restored.currentSummary?.text)
    let reexport = source.root.appendingPathComponent("again.html")
    try await MeetingExporter.export(imported, transcript: restored, store: target, kind: .transcriptAndAudio, to: reexport)
    #expect(try await MeetingHTMLImporter.inspect(reexport).segmentCount == 2)
}

@Test @MainActor func htmlImportReadsLegacyExportAndTranscriptOnlySnapshots() async throws {
    let (source, recording, document) = try importHTMLFixture()
    defer { try? FileManager.default.removeItem(at: source.root) }
    let url = source.root.appendingPathComponent("legacy.HTM")
    try TranscriptHTMLWriter.write(recording: recording, transcript: document, audioURL: nil, to: url)
    var text = try String(contentsOf: url, encoding: .utf8)
    text = text.replacingOccurrences(of: #"<meta name="meeting-intelligence-[^>]+>"#, with: "", options: .regularExpression)
        .replacingOccurrences(of: #" data-(source|speaker-id)="[^"]*""#, with: "", options: .regularExpression)
    try text.write(to: url, atomically: true, encoding: .utf8)
    let preview = try await MeetingHTMLImporter.inspect(url)
    #expect(!preview.hasAudio && preview.hasSummary && preview.segmentCount == 2)
    let target = try RecordingStore(root: source.root.appendingPathComponent("Imported"))
    let imported = try await MeetingHTMLImporter.run(url: url, store: target, transcriptDirectory: source.root.appendingPathComponent("Transcripts"))
    let restored = try TranscriptDocument.load(from: URL(fileURLWithPath: imported.transcriptPath!), recordingID: imported.id)
    #expect(imported.chunks.isEmpty && imported.importMetadata?.duration == 2.9)
    #expect(restored.segments.map(\.text) == document.segments.map(\.text))
    #expect(restored.speakers?.count == 2 && restored.currentSummary != nil && restored.status == "completed")
    var partial = document; partial.status = "running"
    try TranscriptHTMLWriter.write(recording: recording, transcript: partial, audioURL: nil, to: url)
    #expect(!(try await MeetingHTMLImporter.inspect(url)).isComplete)
    let partialRecording = try await MeetingHTMLImporter.run(url: url, store: target, transcriptDirectory: source.root.appendingPathComponent("Transcripts"))
    let partialDocument = try TranscriptDocument.load(from: URL(fileURLWithPath: partialRecording.transcriptPath!), recordingID: partialRecording.id)
    #expect(partialDocument.status == "interrupted" && partialRecording.note != nil)
    let snapshot = MeetingReadSnapshot(recording: partialRecording, transcript: partialDocument, transcriptURL: url, revision: "partial")
    #expect(snapshot.contentState == "partial")
    let original = try Data(contentsOf: URL(fileURLWithPath: partialRecording.transcriptPath!))
    let coordinator = TranscriptionCoordinator(prepare: { _ in Issue.record("Snapshot prepared local ASR"); return "zh-CN" }, recognize: { _, _, _ in [] })
    coordinator.submit(partialRecording, store: target); await coordinator.wait(for: partialRecording.id)
    #expect(try Data(contentsOf: URL(fileURLWithPath: partialRecording.transcriptPath!)) == original)
    #expect(coordinator.documents[partialRecording.id]?.status == "interrupted")
}

@Test(arguments: [
    "<html><h1>ordinary web page</h1></html>",
    "<audio src='https://example.invalid/audio.m4a'></audio>",
    "<audio src='file:///etc/passwd'></audio>",
    "<audio src='data:audio/mp4;base64,AAAA!'></audio>",
    "<audio src='data:audio/mp4;base64,AAAA=AAA'></audio>",
    "<audio src='data:audio/mp4;base64,AA==AAAA'></audio>",
    "<audio src='data:audio/mp4;base64,AA=='></audio><audio src='data:audio/mp4;base64,AA=='></audio>",
    "<audio src='data:audio/ogg;base64,AAAA'></audio>",
    "<article class='segment' data-start='nan' data-end='3'><p class='segment-text'>bad</p></article>",
    "<article class='segment' data-start='2' data-end='1'><p class='segment-text'>bad</p></article>",
    "<article class='segment' data-start='1' data-end='999999'><p class='segment-text'>bad</p></article>",
    "<meta name='meeting-intelligence-export-version' content='99'>",
    "<!DOCTYPE html SYSTEM 'file:///etc/passwd'>",
    "<!DOCTYPE html [<!ENTITY x SYSTEM 'https://example.invalid/'>]>"
]) func htmlImportRejectsUnsafeAndMalformedFiles(fragment: String) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("InvalidHTML-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("input.html")
    let text = "<html><head>\(fragment)</head><body><header class='meeting-header'><h1>Test</h1></header><div id='segments'>\(fragment)</div></body></html>"
    let original = Data(text.utf8); try original.write(to: file)
    let store = try RecordingStore(root: root.appendingPathComponent("Recordings"))
    await #expect(throws: (any Error).self) { _ = try await MeetingHTMLImporter.inspect(file) }
    await #expect(throws: (any Error).self) { _ = try await MeetingHTMLImporter.run(url: file, store: store, transcriptDirectory: root.appendingPathComponent("Transcripts")) }
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    #expect(try Data(contentsOf: file) == original)
}

@Test func htmlImportCancellationAndPublicationRecoveryPreserveBoundaries() async throws {
    let (source, recording, document) = try importHTMLFixture()
    defer { try? FileManager.default.removeItem(at: source.root) }
    let file = source.root.appendingPathComponent("input.html")
    try await MeetingExporter.export(recording, transcript: document, store: source, kind: .transcriptAndAudio, to: file)
    let store = try RecordingStore(root: source.root.appendingPathComponent("Target"))
    let transcripts = source.root.appendingPathComponent("Transcripts")
    let task = Task {
        try await MeetingHTMLImporter.run(url: file, store: store, transcriptDirectory: transcripts) { progress in
            if progress > 0 { withUnsafeCurrentTask { $0?.cancel() } }
        }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).isEmpty)
    let transcriptFiles = (try? FileManager.default.contentsOfDirectory(atPath: transcripts.path)) ?? []
    #expect(transcriptFiles.isEmpty)
    var imported = Recording(title: "Interrupted HTML", applicationName: "导入 HTML", bundleIdentifier: "")
    imported.origin = .imported; imported.status = .completed
    imported.transcriptPath = transcripts.appendingPathComponent("\(imported.id).json").path
    let restored = TranscriptDocument(recordingID: imported.id, locale: "en-US")
    let stage = store.root.appendingPathComponent(".import-\(imported.id)")
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
    try DiskFormat.encode(imported).write(to: stage.appendingPathComponent("recording.json"))
    try DiskFormat.encode(restored).write(to: stage.appendingPathComponent("transcript.pending"))
    try restored.save(to: URL(fileURLWithPath: imported.transcriptPath!))
    #expect(try AudioImporter.recover(store: store).count == 1)
    #expect(!FileManager.default.fileExists(atPath: imported.transcriptPath!))
    let published = store.directory(for: imported.id)
    try FileManager.default.createDirectory(at: published, withIntermediateDirectories: false)
    try DiskFormat.encode(imported).write(to: published.appendingPathComponent("recording.json"))
    try DiskFormat.encode(restored).write(to: published.appendingPathComponent("transcript.pending"))
    #expect(try AudioImporter.recover(store: store).isEmpty)
    #expect(try TranscriptDocument.load(from: URL(fileURLWithPath: imported.transcriptPath!), recordingID: imported.id) == restored)
    #expect(try AudioImporter.recover(store: store).isEmpty)
}

@Test func htmlImportReadsCheckedInHistoricalFixture() async throws {
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/legacy-meeting-0.3.0.html")
    let bytes = try Data(contentsOf: fixture)
    let target = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalHTML-\(UUID())"))
    defer { try? FileManager.default.removeItem(at: target.root) }
    let recording = try await MeetingHTMLImporter.run(url: fixture, store: target, transcriptDirectory: target.root.appendingPathComponent("Transcripts"))
    let document = try TranscriptDocument.load(from: URL(fileURLWithPath: recording.transcriptPath!), recordingID: recording.id)
    #expect(recording.title == "合成历史导出" && recording.chunks.isEmpty)
    #expect(document.segments.first?.text == "合成字幕 <示例>。\n保留换行。")
    #expect(document.segments.first?.start == 1.25 && document.segments.first?.end == 2.75)
    #expect(document.currentSummary?.text == "合成结论：周五发布。\n待办：检查 A & B。")
    #expect(document.speakerName(for: try #require(document.segments.first)) == "发言人 1")
    #expect(try Data(contentsOf: fixture) == bytes)
}

@Test func htmlImportEnforcesSizeAndEmbeddedAudioTimelineLimits() async throws {
    let (source, recording, document) = try importHTMLFixture()
    defer { try? FileManager.default.removeItem(at: source.root) }
    let url = source.root.appendingPathComponent("mismatch.html")
    try await MeetingExporter.export(recording, transcript: document, store: source, kind: .transcriptAndAudio, to: url)
    let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "data-end=\"2.9\"", with: "data-end=\"30\"")
    try text.write(to: url, atomically: true, encoding: .utf8)
    await #expect(throws: MeetingError.self) { _ = try await MeetingHTMLImporter.inspect(url) }
    let oversized = source.root.appendingPathComponent("large.html")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: UInt64(MeetingHTMLImporter.maximumHTMLBytes + 1)); try handle.close()
    await #expect(throws: MeetingError.self) { _ = try await MeetingHTMLImporter.inspect(oversized) }
    try Data(repeating: 32, count: 8 * 1024 * 1024 + 1).write(to: oversized)
    await #expect(throws: MeetingError.self) { _ = try await MeetingHTMLImporter.inspect(oversized) }
}

@Test func explicitCloudRunReplacesHTMLSnapshotAcrossOriginalSources() throws {
    let (store, recording, original) = try importHTMLFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    var document = original
    let chunk = AudioChunk(source: .imported, fileName: "merged.wav", offset: 0, duration: 3, sampleRate: 16000, channels: 1, isComplete: true)
    let config = CloudTranscriptionConfiguration(diarizationEnabled: true)
    var cloud = CloudTranscriptionProgress(configuration: config)
    let session = CloudTranscriptionSession(runID: cloud.runID, source: .imported, chunks: [chunk], fingerprint: "synthetic", configuration: config)
    cloud.sessions = [session]; document.cloud = cloud
    let next = TranscriptSegment(chunkID: nil, source: .imported, start: 1, end: 2.9, text: "New explicit result")
    try document.commitSessionResult(ProviderTranscription(segments: [next]), session: session, replacingImportedSnapshot: true)
    #expect(document.segments.map(\.text) == ["New explicit result"])
    #expect(document.speakerOverrides?.isEmpty != false && document.speakers?.isEmpty != false)
    #expect(document.currentSummary == nil && document.recordingID == recording.id)
    var noSpeech = original; noSpeech.cloud = cloud
    try noSpeech.commitSessionResult(ProviderTranscription(segments: [], noSpeechRecognized: true), session: session, replacingImportedSnapshot: true)
    #expect(noSpeech.segments.map(\.text) == original.segments.map(\.text))
    #expect(noSpeech.resolvedSegments.allSatisfy { $0.speakerID == nil })
}

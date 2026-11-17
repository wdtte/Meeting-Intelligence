import Testing
import Foundation
import AVFoundation
@testable import MeetingCore

private func makeBuffer(rate: Double, channels: UInt32, value: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate / 10))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][frame] = value }
    }
    return buffer
}

@Test func dualTrackWriterPreservesSourceFormatOffsetsAndTail() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DualTrack-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    let app = makeBuffer(rate: 48000, channels: 2, value: 0.05)
    let mic = makeBuffer(rate: 24000, channels: 1, value: 0.08)
    let writer = try ChunkWriter(recording: Recording(title: "Dual", applicationName: "Fixture", bundleIdentifier: "fixture"), store: store, format: app.format, segmentDuration: 0.2)
    _ = try writer.append(app, at: 0.1)
    _ = try writer.append(mic, at: 0.15, source: .microphone)
    _ = try writer.append(app, at: 0.2)
    _ = try writer.append(mic, at: 0.25, source: .microphone)
    _ = try writer.append(mic, at: 0.35, source: .microphone)
    let result = try writer.finish()
    #expect(result.chunks.count == 3)
    #expect(abs(result.duration - 0.45) < 0.0001)
    #expect(result.chunks.allSatisfy { $0.isComplete })
    #expect(Set(result.chunks.map(\.fileName)).count == 3)
    for chunk in result.chunks {
        let file = try AVAudioFile(forReading: store.audioURL(recording: result.id, fileName: chunk.fileName))
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
        try file.read(into: buffer)
        #expect(abs(buffer.floatChannelData![0][20] - (chunk.audioSource == .microphone ? 0.08 : 0.05)) < 0.0001)
        #expect(file.processingFormat.sampleRate == (chunk.audioSource == .microphone ? 24000 : 48000))
    }
    #expect(try store.loadAll().first == result)
}

@Test func legacyManifestStillDecodesAndDefaultsToApplicationTrack() throws {
    let json = """
    {"id":"88DA9770-1C48-466B-A40F-87007059D1E5","fileName":"00000.wav","offset":0.2,"duration":1,"sampleRate":48000,"channels":2,"isComplete":true}
    """
    let chunk = try JSONDecoder().decode(AudioChunk.self, from: Data(json.utf8))
    #expect(chunk.audioSource == .application)
    #expect(chunk.source == nil)
}

@Test func recordingKeepsHistoricalCaptureModesAndMissingMetadataReadable() throws {
    var recording = Recording(title: "Compatibility", applicationName: "Fixture", bundleIdentifier: "fixture")
    for mode: MicrophoneCaptureMode? in [nil, .shared, .systemEchoCancellation] {
        recording.microphoneCaptureMode = mode
        let encoded = try JSONEncoder().encode(recording)
        #expect(try JSONDecoder().decode(Recording.self, from: encoded) == recording)
    }
}

@Test func resumingWithWhisperPreservesHistoricalAppleProvenance() throws {
    let old = AudioChunk(fileName: "old.wav", offset: 0, duration: 10, sampleRate: 16000, channels: 1, isComplete: true)
    let next = AudioChunk(source: .microphone, fileName: "next.wav", offset: 10, duration: 2,
                          sampleRate: 16000, channels: 1, isComplete: true)
    let historical = TranscriptSegment(chunkID: old.id, source: .application, start: 1, end: 2, text: "Old text")
    var document = TranscriptDocument(recordingID: UUID(), locale: "en-US")
    try document.commit([historical], for: old)
    var recognized = TranscriptSegment(chunkID: next.id, source: .microphone, start: 10.2, end: 11, text: "New text")
    recognized.engine = "Whisper base (q5_1)"
    try document.commit([recognized], for: next)
    #expect(document.schemaVersion == 1)
    #expect(document.segments.first == historical)
    #expect(document.segments.first?.engine == nil)
    #expect(document.engine == "Apple SpeechTranscriber + Whisper base (q5_1)")
    let restored = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(document))
    #expect(restored == document)
}

@Test func transcriptRolesFollowTracksAcrossChunksAndSimultaneousSpeech() throws {
    var document = TranscriptDocument(recordingID: UUID(), locale: "zh-CN")
    // Identical words during double-talk must not be deleted or merged by text.
    // Acoustic echo belongs in capture processing, not transcript deduplication.
    for offset in [0.0, 10.0] {
        for source in AudioSource.allCases {
            let chunk = AudioChunk(source: source, fileName: "fixture.wav", offset: offset,
                                   duration: 10, sampleRate: 48000, channels: 1, isComplete: true)
            let segment = TranscriptSegment(chunkID: chunk.id, source: source,
                                            start: offset + 1, end: offset + 2, text: "好的")
            try document.commit([segment], for: chunk)
            var wrongRole = segment
            wrongRole.source = source == .application ? .microphone : .application
            #expect(throws: MeetingError.self) { try document.commit([wrongRole], for: chunk) }
        }
    }
    #expect(document.segments.count == 4)
    #expect(Set(document.segments.map(\.source.rawValue)) == ["application", "microphone"])
    let data = try JSONEncoder().encode(document)
    #expect(try JSONDecoder().decode(TranscriptDocument.self, from: data) == document)
    let invalid = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"application\"", with: "\"speaker_3\"")
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(TranscriptDocument.self, from: Data(invalid.utf8))
    }
}

@Test func transcriptRetryIsIdempotentAndKeepsSourceAndMeetingTime() throws {
    let chunk = AudioChunk(source: .microphone, fileName: "00001.wav", offset: 10.5, duration: 2, sampleRate: 24000, channels: 1, isComplete: true)
    var document = TranscriptDocument(recordingID: UUID(), locale: "zh-CN")
    let segment = TranscriptSegment(chunkID: chunk.id, source: .microphone, start: 10.6, end: 11.8, text: "测试字幕")
    try document.commit([segment], for: chunk)
    try document.commit([segment], for: chunk)
    #expect(document.segments == [segment])
    #expect(document.processedChunks == [chunk.id])
    #expect(segment.contains(11)); #expect(!segment.contains(11.8))
    let invalid = TranscriptSegment(chunkID: chunk.id, source: .microphone, start: 0, end: 1, text: "错误时间")
    #expect(throws: MeetingError.self) { try document.commit([invalid], for: chunk) }
    #expect(document.segments == [segment])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Transcript-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("nested/transcript.json")
    try document.save(to: url)
    #expect(try TranscriptDocument.load(from: url, recordingID: document.recordingID) == document)
    #expect(throws: MeetingError.self) { _ = try TranscriptDocument.load(from: url, recordingID: UUID()) }
    try document.commit([], for: chunk)
    #expect(document.segments.isEmpty)
    #expect(document.processedChunks.contains(chunk.id)) // silence is processed, not retried forever
}

@Test func twoTrackPlaybackMixesAndSeeksAtSharedHostTimeline() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DualPlayback-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    let app = makeBuffer(rate: 48000, channels: 2, value: 0.05)
    let mic = makeBuffer(rate: 24000, channels: 1, value: 0.08)
    let writer = try ChunkWriter(recording: Recording(title: "Mix", applicationName: "Fixture", bundleIdentifier: "fixture"), store: store, format: app.format)
    _ = try writer.append(app, at: 0.1)
    _ = try writer.append(mic, at: 0.15, source: .microphone)
    let recording = try writer.finish()
    let engine = AVAudioEngine()
    let players = [AVAudioPlayerNode(), AVAudioPlayerNode()]
    for (index, source) in AudioSource.allCases.enumerated() {
        let files = try recording.chunks.filter { $0.audioSource == source }.map { ($0, try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: $0.fileName))) }
        engine.attach(players[index]); engine.connect(players[index], to: engine.mainMixerNode, format: files[0].1.processingFormat)
        try PlaybackSchedule.enqueue(files, on: players[index], from: 0.12)
    }
    try engine.enableManualRenderingMode(.offline, format: app.format, maximumFrameCount: 1024)
    try engine.start(); players.forEach { $0.play() }
    defer { players.forEach { $0.stop() }; engine.stop() }
    let output = AVAudioPCMBuffer(pcmFormat: app.format, frameCapacity: 1024)!
    var samples: [Float] = []
    for _ in 0..<8 {
        let status = try engine.renderOffline(1024, to: output)
        #expect(status == .success)
        samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
    #expect(abs(samples[600] - 0.05) < 0.01)
    #expect(abs(samples[2500] - 0.13) < 0.01)
    #expect(abs(samples[5000] - 0.08) < 0.01)
    #expect(abs(samples[7500]) < 0.01)
}

/// Opt-in integration test. A synthetic speech fixture avoids accessing personal meetings.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_SPEECH_FIXTURE"] != nil))
func localSpeechRecognizesFixtureWithRealTimestamps() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = URL(fileURLWithPath: try #require(env["MEETING_SPEECH_FIXTURE"]))
    let file = try AVAudioFile(forReading: url)
    let locale = try await LocalTranscriber.prepare(locale: env["MEETING_SPEECH_LOCALE"] ?? "en-US", download: false)
    _ = try await LocalTranscriber.prepare(locale: locale, download: false) // repeated model checks must be idempotent
    let chunk = AudioChunk(fileName: url.lastPathComponent, offset: 12, duration: Double(file.length) / file.processingFormat.sampleRate, sampleRate: file.processingFormat.sampleRate, channels: file.processingFormat.channelCount, isComplete: true)
    let result = try await LocalTranscriber.transcribe(url: url, chunk: chunk, locale: locale)
    #expect(!result.isEmpty)
    #expect(result.allSatisfy { $0.start >= 12 && $0.end <= chunk.end && $0.end > $0.start })
    let text = result.map(\.text).joined(separator: " ")
    print("Speech fixture result:", text)
    if let expected = env["MEETING_SPEECH_EXPECTED"] { #expect(text.localizedCaseInsensitiveContains(expected)) }
    var document = TranscriptDocument(recordingID: UUID(), locale: locale)
    try document.commit(result, for: chunk)
    #expect(document.processedChunks.contains(chunk.id))

    // Exercise the full disk-backed pipeline, including both sources and the
    // short tail at stop, rather than only calling the recognizer directly.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeechPipeline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "Synthetic speech", applicationName: "Fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcripts/meeting.json").path
    recording.transcriptionLocale = locale
    file.framePosition = 0
    let writer = try ChunkWriter(recording: recording, store: store, format: file.processingFormat)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
    var frame: AVAudioFramePosition = 0
    while file.framePosition < file.length {
        try file.read(into: buffer)
        let offset = Double(frame) / file.processingFormat.sampleRate
        _ = try writer.append(buffer, at: offset)
        _ = try writer.append(buffer, at: offset + 0.25, source: .microphone)
        frame += AVAudioFramePosition(buffer.frameLength)
    }
    let finished = try writer.finish()
    let coordinator = await TranscriptionCoordinator()
    await coordinator.submit(finished, store: store)
    await coordinator.wait(for: finished.id)
    let persisted = try TranscriptDocument.load(from: URL(fileURLWithPath: recording.transcriptPath!), recordingID: finished.id)
    #expect(persisted.status == "completed")
    #expect(persisted.processedChunks == Set(finished.chunks.map(\.id)))
    #expect(Set(persisted.segments.map(\.source)) == Set(AudioSource.allCases))
    #expect(!persisted.segments.isEmpty)
}

private actor RecognitionGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func transcriptionDrainsFinalSnapshotArrivingDuringRecognition() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptQueue-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "Queue", applicationName: "Fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcripts/meeting.json").path
    let first = AudioChunk(fileName: "0.wav", offset: 1, duration: 10, sampleRate: 48000, channels: 2, isComplete: true)
    let tail = AudioChunk(source: .microphone, fileName: "1.wav", offset: 11, duration: 0.4, sampleRate: 24000, channels: 1, isComplete: true)
    recording.chunks = [first]
    let gate = RecognitionGate()
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, chunk, _ in
        if chunk.id == first.id { await gate.hold() }
        return [TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource, start: chunk.offset, end: chunk.end, text: chunk.fileName)]
    })
    coordinator.submit(recording, store: store)
    for _ in 0..<1000 {
        if await gate.entered { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await gate.entered)
    recording.chunks.append(tail); recording.status = .completed
    coordinator.submit(recording, store: store)
    await gate.release()
    await coordinator.wait(for: recording.id)
    let doc = try #require(coordinator.documents[recording.id])
    #expect(doc.status == "completed")
    #expect(doc.processedChunks == [first.id, tail.id])
    #expect(doc.segments.count == 2)
    #expect(doc.segments.last?.end == tail.end)
    #expect(!coordinator.running.contains(recording.id))
    let reopened = try TranscriptDocument.load(from: URL(fileURLWithPath: recording.transcriptPath!), recordingID: recording.id)
    #expect(reopened == doc)
}

private actor RecognitionAttempts {
    var counts: [UUID: Int] = [:]
    func next(_ id: UUID) -> Int { counts[id, default: 0] += 1; return counts[id]! }
}

@Test @MainActor func failedTranscriptionResumesWithoutDuplicatingSavedChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptRetry-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "Retry", applicationName: "Fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcripts/meeting.json").path
    let first = AudioChunk(fileName: "0.wav", offset: 0, duration: 10, sampleRate: 48000, channels: 2, isComplete: true)
    let second = AudioChunk(fileName: "1.wav", offset: 10, duration: 1, sampleRate: 48000, channels: 2, isComplete: true)
    recording.chunks = [first, second]; recording.status = .completed
    let attempts = RecognitionAttempts()
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, chunk, _ in
        let count = await attempts.next(chunk.id)
        if chunk.id == second.id && count == 1 { throw MeetingError.message("fixture failure") }
        return [TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource, start: chunk.offset, end: chunk.end, text: "saved")]
    })
    coordinator.submit(recording, store: store)
    await coordinator.wait(for: recording.id)
    #expect(coordinator.documents[recording.id]?.status == "failed")
    #expect(coordinator.documents[recording.id]?.processedChunks == [first.id])
    coordinator.submit(recording, store: store, retry: true)
    await coordinator.wait(for: recording.id)
    #expect(coordinator.documents[recording.id]?.status == "completed")
    #expect(coordinator.documents[recording.id]?.segments.count == 2)
    #expect(await attempts.counts[first.id] == 1)
    #expect(await attempts.counts[second.id] == 2)
}

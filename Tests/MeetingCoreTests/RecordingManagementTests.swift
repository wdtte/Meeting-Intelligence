import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func managedFixture() throws -> (RecordingStore, Recording, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagementTests-\(UUID())")
    let store = try RecordingStore(root: root.appendingPathComponent("audio"))
    var recording = Recording(title: "Before", applicationName: "Test", bundleIdentifier: "test")
    recording.status = .completed
    recording.transcriptPath = root.appendingPathComponent("transcripts/\(recording.id).json").path
    try TranscriptDocument(recordingID: recording.id, locale: "zh-CN").save(to: URL(fileURLWithPath: recording.transcriptPath!))
    try store.save(recording)
    return (store, recording, root)
}

@Test func renamePreservesIdentityAndRejectsEmptyOrRecordingNames() throws {
    let (store, recording, root) = try managedFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let renamed = try store.rename(recording.id, to: "  周会 / 第一阶段  ")
    var expected = recording; expected.title = "周会 / 第一阶段"
    #expect(renamed == expected)
    #expect(try store.loadAll() == [expected])
    #expect(throws: MeetingError.self) { try store.rename(recording.id, to: " \n ") }
    #expect(try store.loadAll() == [expected])
    expected.status = .recording; try store.save(expected)
    #expect(throws: MeetingError.self) { try store.rename(recording.id, to: "No") }
}

@Test func trashGroupsExternalTranscriptAndDoesNotTouchOtherMeetingsOrExports() throws {
    let (store, recording, root) = try managedFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var other = Recording(title: "Other", applicationName: "Test", bundleIdentifier: "test")
    other.status = .completed; try store.save(other)
    let exported = root.appendingPathComponent("export.html")
    try Data("export".utf8).write(to: exported)
    let trash = root.appendingPathComponent("FakeTrash")
    try store.moveToTrash(recording.id) { try FileManager.default.moveItem(at: $0, to: trash) }
    #expect(try store.loadAll() == [other])
    #expect(!FileManager.default.fileExists(atPath: recording.transcriptPath!))
    let files = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
    let transcript = try #require(files.first { $0.lastPathComponent.hasPrefix("transcript-") })
    #expect(try TranscriptDocument.load(from: transcript, recordingID: recording.id).recordingID == recording.id)
    #expect(try String(contentsOf: exported, encoding: .utf8) == "export")
}

@Test func failedTrashRestoresExternalTranscriptAndRejectsUnrelatedTranscript() throws {
    let (store, recording, root) = try managedFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = URL(fileURLWithPath: recording.transcriptPath!)
    let original = try Data(contentsOf: url)
    #expect(throws: MeetingError.self) {
        try store.moveToTrash(recording.id) { _ in throw MeetingError.message("denied") }
    }
    #expect(try Data(contentsOf: url) == original)
    #expect(try store.loadAll() == [recording])
    try TranscriptDocument(recordingID: UUID(), locale: "zh-CN").save(to: url)
    var called = false
    #expect(throws: MeetingError.self) { try store.moveToTrash(recording.id) { _ in called = true } }
    #expect(!called)
    #expect(try store.loadAll() == [recording])
}

@Test func waveformPreservesGapsSeparateTracksAndActualSampleRate() async throws {
    let (store, original, root) = try managedFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var recording = original
    for (index, source) in AudioSource.allCases.enumerated() {
        let rate = index == 0 ? 8000.0 : 16000.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate))!
        buffer.frameLength = buffer.frameCapacity
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][i] = 0
            buffer.floatChannelData![1][i] = index == 0 ? -0.25 : 0.81
        }
        let name = "\(index).wav"
        let file = try AVAudioFile(forWriting: store.audioURL(recording: recording.id, fileName: name), settings: format.settings)
        try file.write(from: buffer)
        recording.chunks.append(AudioChunk(source: source, fileName: name, offset: Double(index * 2 + 1),
            duration: 1, sampleRate: 48000, channels: 2, isComplete: true))
    }
    recording.chunks.append(AudioChunk(fileName: "unfinished.wav", offset: 10, duration: 1, sampleRate: 8000, channels: 1, isComplete: false))
    let peaks = try await AudioWaveform.load(recording, store: store, count: 40)
    let app = try #require(peaks[.application]), mic = try #require(peaks[.microphone])
    #expect(app.count == 40 && mic.count == 40)
    #expect(app[0..<10].allSatisfy { $0 == 0 })
    #expect(app[10..<20].allSatisfy { abs($0 - 0.25) < 0.001 })
    #expect(app[20..<40].allSatisfy { $0 == 0 })
    #expect(mic[0..<30].allSatisfy { $0 == 0 })
    #expect(mic[30..<40].allSatisfy { abs($0 - 0.81) < 0.001 })
    let snapshot = recording
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await AudioWaveform.load(snapshot, store: store)
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

private actor RecognitionGate {
    var started = false
    func recognize() async throws {
        started = true
        try await Task.sleep(for: .seconds(30))
    }
}

@Test @MainActor func deletionWaitsForTranscriptionToStopBeforeRemovingFiles() async throws {
    let (store, original, root) = try managedFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    var recording = original
    recording.chunks = [AudioChunk(fileName: "fixture.wav", offset: 0, duration: 1, sampleRate: 8000, channels: 1, isComplete: true)]
    try store.save(recording)
    let gate = RecognitionGate()
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, _, _ in
        try await gate.recognize()
        return []
    })
    coordinator.submit(recording, store: store)
    for _ in 0..<1000 {
        if await gate.started { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await gate.started)
    await coordinator.stopAndForget(recording.id)
    #expect(!coordinator.running.contains(recording.id))
    #expect(coordinator.documents[recording.id] == nil)
    try store.moveToTrash(recording.id) { try FileManager.default.removeItem(at: $0) }
    await coordinator.wait(for: recording.id)
    #expect(!FileManager.default.fileExists(atPath: recording.transcriptPath!))
    #expect(try store.loadAll().isEmpty)
}

import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func exportFixture() throws -> (RecordingStore, Recording) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingExportTests-\(UUID())")
    return (try RecordingStore(root: root), Recording(title: "Export test", applicationName: "Fixture", bundleIdentifier: "fixture"))
}

private func addTone(_ recording: inout Recording, store: RecordingStore, source: AudioSource,
                     offset: Double, rate: Double, frequency: Double, channels: UInt32 = 1) throws {
    let duration = 0.5
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(rate * duration))!
    buffer.frameLength = buffer.frameCapacity
    for channel in 0..<Int(channels) {
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![channel][frame] = 0.4 * Float(sin(2 * .pi * frequency * Double(frame) / rate))
        }
    }
    try FileManager.default.createDirectory(at: store.directory(for: recording.id), withIntermediateDirectories: true)
    let fileName = "\(recording.chunks.count).wav"
    let file = try AVAudioFile(forWriting: store.audioURL(recording: recording.id, fileName: fileName), settings: format.settings)
    try file.write(from: buffer)
    recording.chunks.append(AudioChunk(source: source, fileName: fileName, offset: offset, duration: duration,
                                      sampleRate: rate, channels: channels, isComplete: true))
}

private func decodedSamples(_ url: URL) throws -> ([Float], Double) {
    let file = try AVAudioFile(forReading: url)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
    try file.read(into: buffer)
    return (Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))), file.processingFormat.sampleRate)
}

private func rms(_ samples: [Float], rate: Double, from start: Double, to end: Double) -> Double {
    let lower = min(samples.count, Int(start * rate)), upper = min(samples.count, Int(end * rate))
    guard upper > lower else { return -1 }
    return sqrt(samples[lower..<upper].reduce(0.0) { $0 + Double($1 * $1) } / Double(upper - lower))
}

@Test func mergedExportAlignsDifferentSampleRatesAndPreservesSilence() async throws {
    var (store, recording) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try addTone(&recording, store: store, source: .application, offset: 0.2, rate: 48000, frequency: 440, channels: 2)
    try addTone(&recording, store: store, source: .microphone, offset: 0.4, rate: 16000, frequency: 880)
    try addTone(&recording, store: store, source: .application, offset: 1.1, rate: 48000, frequency: 440, channels: 2)
    recording.status = .completed
    let destination = store.root.appendingPathComponent("merged.m4a")
    try await MergedAudioExporter.export(recording, store: store, to: destination)
    let duration = try await AVURLAsset(url: destination).load(.duration)
    #expect(abs(duration.seconds - 1.6) < 0.03)
    let (samples, rate) = try decodedSamples(destination)
    #expect(rms(samples, rate: rate, from: 0.05, to: 0.15) < 0.005)
    #expect(rms(samples, rate: rate, from: 0.96, to: 1.04) < 0.005)
    for window in [(0.25, 0.35), (0.75, 0.85), (1.2, 1.3)] {
        let level = rms(samples, rate: rate, from: window.0, to: window.1)
        #expect(level > 0.10 && level < 0.18)
    }
    let overlap = rms(samples, rate: rate, from: 0.45, to: 0.60)
    #expect(overlap > 0.17 && overlap < 0.25)
}

@Test func mergedExportSupportsSingleLegacyTrackAndReplacesExistingFile() async throws {
    var (store, recording) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try addTone(&recording, store: store, source: .application, offset: 0, rate: 44100, frequency: 440)
    recording.chunks[0].source = nil
    // An interrupted recording exports only its completed chunks.
    recording.chunks.append(AudioChunk(fileName: "missing.partial.wav", offset: 0.5, duration: 0.5,
                                      sampleRate: 44100, channels: 1, isComplete: false))
    recording.status = .interrupted
    let destination = store.root.appendingPathComponent("existing.m4a")
    try Data("old export".utf8).write(to: destination)
    try await MergedAudioExporter.export(recording, store: store, to: destination)
    let (samples, rate) = try decodedSamples(destination)
    #expect(rms(samples, rate: rate, from: 0.1, to: 0.3) > 0.24)
    let duration = try await AVURLAsset(url: destination).load(.duration)
    #expect(abs(duration.seconds - 0.5) < 0.03)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
}

@Test func failedOrCancelledExportPreservesExistingDestination() async throws {
    var (store, recording) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    recording.status = .completed
    recording.chunks = [AudioChunk(fileName: "missing.wav", offset: 0, duration: 0.5, sampleRate: 48000, channels: 1, isComplete: true)]
    let destination = store.root.appendingPathComponent("existing.m4a")
    let sentinel = Data("keep this export".utf8)
    try sentinel.write(to: destination)
    await #expect(throws: (any Error).self) { try await MergedAudioExporter.export(recording, store: store, to: destination) }
    #expect(try Data(contentsOf: destination) == sentinel)
    let snapshot = recording
    let cancelled = Task { [store] in
        withUnsafeCurrentTask { $0?.cancel() }
        try await MergedAudioExporter.export(snapshot, store: store, to: destination)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try Data(contentsOf: destination) == sentinel)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
}

@Test func mergedExportRejectsEmptyLiveAndInvalidTimeline() async throws {
    var (store, recording) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let destination = store.root.appendingPathComponent("output.m4a")
    await #expect(throws: MeetingError.self) { try await MergedAudioExporter.export(recording, store: store, to: destination) }
    recording.status = .completed
    await #expect(throws: MeetingError.self) { try await MergedAudioExporter.export(recording, store: store, to: destination) }
    recording.chunks = [AudioChunk(fileName: "missing.wav", offset: .nan, duration: 1, sampleRate: 48000, channels: 1, isComplete: true)]
    await #expect(throws: MeetingError.self) { try await MergedAudioExporter.export(recording, store: store, to: destination) }
    #expect(!FileManager.default.fileExists(atPath: destination.path))
}

@Test func mergedExportDoesNotShiftLaterAudioWhenSourceChunksOverlap() async throws {
    var (store, recording) = try exportFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try addTone(&recording, store: store, source: .application, offset: 0, rate: 48000, frequency: 440)
    try addTone(&recording, store: store, source: .application, offset: 0.25, rate: 48000, frequency: 880)
    try addTone(&recording, store: store, source: .application, offset: 1, rate: 48000, frequency: 440)
    recording.status = .completed
    let destination = store.root.appendingPathComponent("overlap.m4a")
    try await MergedAudioExporter.export(recording, store: store, to: destination)
    let duration = try await AVURLAsset(url: destination).load(.duration)
    #expect(abs(duration.seconds - 1.5) < 0.03)
    let (samples, rate) = try decodedSamples(destination)
    #expect(rms(samples, rate: rate, from: 0.8, to: 0.95) < 0.005)
    #expect(rms(samples, rate: rate, from: 0.3, to: 0.45) > 0.17)
    #expect(rms(samples, rate: rate, from: 1.1, to: 1.3) > 0.10)
}

import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func routeBuffer(rate: Double, channels: AVAudioChannelCount, value: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
    let frames = AVAudioFrameCount(rate / 10)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<Int(channels) {
        buffer.floatChannelData![channel].initialize(repeating: value, count: Int(frames))
    }
    return buffer
}

@Test func deviceSwitchKeepsMeetingTimelineAndEachChunksFormat() throws {
    let store = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let recording = Recording(title: "Switch", applicationName: "Fixture", bundleIdentifier: "fixture")
    let speaker = routeBuffer(rate: 48000, channels: 2, value: 0.05)
    let builtInMic = routeBuffer(rate: 48000, channels: 1, value: 0.06)
    let headset = routeBuffer(rate: 24000, channels: 1, value: 0.07)
    let headphones = routeBuffer(rate: 44100, channels: 2, value: 0.08)
    let writer = try ChunkWriter(recording: recording, store: store, format: speaker.format)
    _ = try writer.append(speaker, at: 0)
    _ = try writer.append(builtInMic, at: 0.02, source: .microphone)
    try writer.checkpoint()
    let checkpoint = try #require(store.loadAll().first)
    #expect(checkpoint.id == recording.id)
    #expect(checkpoint.status == .recording)
    #expect(checkpoint.endedAt == nil)
    #expect(checkpoint.chunks.count == 2)
    #expect(checkpoint.chunks.allSatisfy { $0.isComplete })

    // Bluetooth switches both input/output to a different rate and channel count.
    _ = try writer.append(headset, at: 1.5)
    _ = try writer.append(headset, at: 1.52, source: .microphone)
    try writer.checkpoint()
    // Then switch output back while input keeps the same format.
    _ = try writer.append(headphones, at: 3)
    _ = try writer.append(headset, at: 3.02, source: .microphone)
    let result = try writer.finish()
    #expect(result.id == recording.id)
    #expect(result.status == .completed)
    #expect(result.chunks.count == 6)
    #expect(abs(result.duration - 3.12) < 0.0001)
    #expect(abs(result.audioDuration - 0.6) < 0.0001)
    #expect(result.chunks.map(\.offset) == [0, 0.02, 1.5, 1.52, 3, 3.02])
    #expect(result.chunks.map(\.sampleRate) == [48000, 48000, 24000, 24000, 44100, 24000])
    #expect(result.chunks.map(\.channels) == [2, 1, 1, 1, 2, 1])
    #expect(Set(result.chunks.map(\.fileName)).count == 6)
    for (index, chunk) in result.chunks.enumerated() {
        let file = try AVAudioFile(forReading: store.audioURL(recording: result.id, fileName: chunk.fileName))
        #expect(file.processingFormat.sampleRate == chunk.sampleRate)
        #expect(file.processingFormat.channelCount == chunk.channels)
        #expect(file.length == Int64(chunk.sampleRate / 10))
        let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1)!
        try file.read(into: read, frameCount: 1)
        let expected: [Float] = [0.05, 0.06, 0.07, 0.07, 0.08, 0.07]
        #expect(abs(read.floatChannelData![0][0] - expected[index]) < 0.0001)
    }
}

@Test func deviceSwitchFormatChangeClosesOldSegmentAndStillRejectsClockReset() throws {
    let store = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let old = routeBuffer(rate: 48000, channels: 2, value: 0.05)
    let new = routeBuffer(rate: 16000, channels: 1, value: 0.07)
    let writer = try ChunkWriter(recording: Recording(title: "Switch", applicationName: "Test", bundleIdentifier: "test"),
                                 store: store, format: old.format)
    _ = try writer.append(old, at: 5)
    // Even a contiguous format change needs a fresh file with its own WAV header.
    _ = try writer.append(new, at: 5.1)
    #expect(writer.recording.chunks.first?.isComplete == true)
    try writer.checkpoint()
    #expect(throws: MeetingError.self) { _ = try writer.append(old, at: 0) }
    // Stopping while hardware is reconnecting saves the checkpoint as a normal meeting.
    let result = try writer.finish()
    #expect(result.status == .completed)
    #expect(result.chunks.count == 2)
    #expect(abs(result.duration - 5.2) < 0.0001)
}

@Test func deviceSwitchRetriesWaitForHardwareAndHaveAFixedDeadline() {
    var recovery = CaptureRecoverySchedule(now: 100)
    #expect(recovery.advance(now: 100) == .wait)
    #expect(recovery.advance(now: 100.49) == .wait)
    #expect(recovery.advance(now: 100.5) == .retry)
    #expect(recovery.advance(now: 100.51) == .wait)
    #expect(recovery.advance(now: 101) == .retry)
    #expect(recovery.advance(now: 111.8) == .retry)
    // Failed retries never extend the original deadline, even inside the backoff.
    #expect(recovery.advance(now: 112) == .expired)
}

@Test(arguments: [false, true])
func deviceSwitchPlaybackMixesFormatsPreservesGapsAndSeeks(delayedEnqueue: Bool) throws {
    let store = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    defer { try? FileManager.default.removeItem(at: store.root) }
    let app = routeBuffer(rate: 48000, channels: 2, value: 0.05)
    let mic = routeBuffer(rate: 48000, channels: 1, value: 0.06)
    let changedApp = routeBuffer(rate: 44100, channels: 1, value: 0.07)
    let changedMic = routeBuffer(rate: 24000, channels: 1, value: 0.08)
    let writer = try ChunkWriter(recording: Recording(title: "Switch playback", applicationName: "Fixture", bundleIdentifier: "fixture"),
                                 store: store, format: app.format)
    for (time, application, microphone) in [(0.1, app, mic), (0.4, changedApp, changedMic), (0.7, app, mic)] {
        _ = try writer.append(application, at: time)
        _ = try writer.append(microphone, at: time, source: .microphone)
        try writer.checkpoint()
    }
    let recording = try writer.finish()
    let files = try recording.chunks.map { ($0, try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: $0.fileName))) }
    func render(from position: Double, source: AudioSource?, delayedEnqueue: Bool = false) throws -> [Float] {
        let engine = AVAudioEngine()
        let tracks = PlaybackTracks(engine: engine)
        try tracks.prepare(recording, store: store)
        tracks.select(source)
        try engine.enableManualRenderingMode(.offline, format: app.format, maximumFrameCount: 1024)
        for (chunk, file) in files where !delayedEnqueue || chunk.offset < 0.4 {
            try tracks.enqueue(chunk, file: file, from: position)
        }
        try engine.start(); tracks.play()
        defer { tracks.stop(); engine.stop(); tracks.clear() }
        let output = AVAudioPCMBuffer(pcmFormat: app.format, frameCapacity: 1024)!
        let count = Int(((recording.duration - position) * 48000).rounded())
        var samples: [Float] = []
        var queuedLater = !delayedEnqueue
        while samples.count < count {
            if !queuedLater, samples.count >= 14400 {
                for (chunk, file) in files where chunk.offset >= 0.4 {
                    try tracks.enqueue(chunk, file: file, from: position)
                }
                queuedLater = true
            }
            let status = try engine.renderOffline(UInt32(min(1024, count - samples.count)), to: output)
            guard status == .success else { throw MeetingError.message("Offline playback failed: \(status.rawValue)") }
            samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
        }
        return samples
    }
    let mixed = try render(from: 0, source: nil, delayedEnqueue: delayedEnqueue)
    #expect(abs(mixed[2400]) < 0.001)
    #expect(abs(mixed[7200] - 0.11) < 0.005)
    #expect(abs(mixed[14400]) < 0.001)
    #expect(abs(mixed[21600] - 0.15) < 0.005)
    #expect(abs(mixed[28800]) < 0.001)
    #expect(abs(mixed[36000] - 0.11) < 0.005)
    let seek = try render(from: 0.43, source: nil)
    #expect(abs(seek[960] - 0.15) < 0.005)
    #expect(abs(seek[8160]) < 0.001)
    #expect(abs(seek[15360] - 0.11) < 0.005)
    let microphone = try render(from: 0, source: .microphone)
    #expect(abs(microphone[7200] - 0.06) < 0.005)
    #expect(abs(microphone[21600] - 0.08) < 0.005)
    let application = try render(from: 0, source: .application)
    #expect(abs(application[7200] - 0.05) < 0.005)
    #expect(abs(application[21600] - 0.07) < 0.005)
}

// Explicit local validation only: render an existing recording to memory without
// changing its files, transmitting audio, or playing through the user's speakers.
@Test(.enabled(if: ProcessInfo.processInfo.environment["MEETING_PLAYBACK_RECORDING"] != nil))
func existingDeviceSwitchRecordingRendersOffline() throws {
    let path = try #require(ProcessInfo.processInfo.environment["MEETING_PLAYBACK_RECORDING"])
    let url = URL(fileURLWithPath: path)
    let recording = try JSONDecoder().decode(Recording.self, from: Data(contentsOf: url))
    let store = try RecordingStore(root: url.deletingLastPathComponent().deletingLastPathComponent())
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    for source in [AudioSource?.none, .application, .microphone] {
        let engine = AVAudioEngine()
        let tracks = PlaybackTracks(engine: engine)
        try tracks.prepare(recording, store: store)
        tracks.select(source)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        for chunk in recording.chunks where chunk.isComplete {
            let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
            try tracks.enqueue(chunk, file: file, from: 0)
        }
        try engine.start(); tracks.play()
        defer { tracks.stop(); engine.stop(); tracks.clear() }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        let expected = Int((recording.duration * format.sampleRate).rounded())
        var frames = 0
        var peak: Float = 0
        while frames < expected {
            let status = try engine.renderOffline(UInt32(min(4096, expected - frames)), to: output)
            guard status == .success else { throw MeetingError.message("Offline playback failed: \(status.rawValue)") }
            frames += Int(output.frameLength)
            for index in 0..<Int(output.frameLength) { peak = max(peak, abs(output.floatChannelData![0][index])) }
        }
        #expect(frames == expected)
        #expect(peak > 0.001)
    }
}

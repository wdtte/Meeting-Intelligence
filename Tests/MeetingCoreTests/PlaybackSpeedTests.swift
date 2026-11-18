import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

@Test func sentenceNavigationHandlesBoundariesGapsAndOverlappingTracks() {
    let segments = [10.0, 0, 10, 20].map {
        TranscriptSegment(chunkID: UUID(), source: .application, start: $0, end: $0 + 2, text: "fixture")
    }
    #expect(TranscriptNavigation.destination(in: segments, from: 0, direction: .previous) == 0)
    #expect(TranscriptNavigation.destination(in: segments, from: 0, direction: .next) == 10)
    #expect(TranscriptNavigation.destination(in: segments, from: 10, direction: .previous) == 0)
    #expect(TranscriptNavigation.destination(in: segments, from: 10, direction: .next) == 20)
    #expect(TranscriptNavigation.destination(in: segments, from: 10.3, direction: .previous) == 0)
    #expect(TranscriptNavigation.destination(in: segments, from: 11, direction: .previous) == 0)
    #expect(TranscriptNavigation.destination(in: segments, from: 13, direction: .previous) == 0)
    #expect(TranscriptNavigation.destination(in: segments, from: 20.3, direction: .previous) == 10)
    #expect(TranscriptNavigation.destination(in: segments, from: 30, direction: .previous) == 10)
    #expect(TranscriptNavigation.destination(in: segments, from: 13, direction: .next) == 20)
    #expect(TranscriptNavigation.destination(in: segments, from: 20, direction: .next) == nil)
    #expect(TranscriptNavigation.destination(in: [], from: 10, direction: .next) == nil)
    #expect(TranscriptNavigation.destination(in: segments, from: .nan, direction: .next) == nil)
}

// Render synthetic dual-track audio through the production graph. Assert that
// speed changes audible duration and preserves pitch, source alignment and gaps.
@Test(arguments: PlaybackSpeed.allCases)
func playbackSpeedStretchesSharedTimelineWithoutChangingPitch(speed: PlaybackSpeed) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("PlaybackSpeed-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
    var recording = Recording(title: "Speed fixture", applicationName: "fixture", bundleIdentifier: "fixture")
    try store.save(recording)
    for (index, source) in [AudioSource.application, .microphone].enumerated() {
        let sourceRate: Double = source == .application ? 48000 : 24000
        let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: UInt32(sourceRate * 2))!
        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][frame] = 0.08 * sin(2 * .pi * 440 * Float(frame) / Float(sourceRate))
        }
        let chunk = AudioChunk(source: source, fileName: "\(index).wav", offset: 1, duration: 2,
                               sampleRate: sourceRate, channels: 1, isComplete: true)
        let file = try AVAudioFile(forWriting: store.audioURL(recording: recording.id, fileName: chunk.fileName), settings: sourceFormat.settings)
        try file.write(from: buffer)
        recording.chunks.append(chunk)
    }
    let engine = AVAudioEngine(), tracks = PlaybackTracks(engine: engine)
    try tracks.prepare(recording, store: store)
    tracks.setSpeed(speed)
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    for chunk in recording.chunks {
        let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
        try tracks.enqueue(chunk, file: file, from: 0)
    }
    try engine.start(); tracks.play()
    defer { tracks.stop(); engine.stop(); tracks.clear() }
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
    var samples: [Float] = []
    let frames = Int((3 / speed.rawValue + 0.5) * 48000)
    var attempts = 0
    while samples.count < frames {
        attempts += 1
        guard attempts < 2000 else { throw MeetingError.message("Offline playback made no progress") }
        let status = try engine.renderOffline(UInt32(min(1024, frames - samples.count)), to: buffer)
        if status == .cannotDoInCurrentContext { continue }
        #expect(status == .success)
        guard status == .success else { throw MeetingError.message("Offline render failed") }
        samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
    func rms(_ start: Double, _ end: Double) -> Float {
        let slice = samples[Int(start * 48000)..<Int(end * 48000)]
        return sqrt(slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count))
    }
    #expect(rms(0.1 / speed.rawValue, 0.4 / speed.rawValue) < 0.001)
    let start = Int(1.5 / speed.rawValue * 48000), end = Int(2.5 / speed.rawValue * 48000)
    #expect(rms(1.5 / speed.rawValue, 2.5 / speed.rawValue) > 0.06)
    #expect(rms(3 / speed.rawValue + 0.3, 3 / speed.rawValue + 0.45) < 0.001)
    let crossings = (start + 1..<end).count { samples[$0 - 1] < 0 && samples[$0] >= 0 }
    let frequency = Double(crossings) / (Double(end - start) / 48000)
    #expect(abs(frequency - 440) < 15)
}

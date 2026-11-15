import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MeetingCore

@Test func globalTapIncludesAllProcessesWithoutMutingPlayback() {
    let description = Hardware.globalTapDescription()
    // An exclusive tap with no exclusions also includes apps launched after
    // recording starts. It must not be narrowed by a PID or bundle ID list.
    #expect(description.isExclusive)
    #expect(description.processes.isEmpty)
    #expect(description.bundleIDs.isEmpty)
    #expect(description.isMixdown)
    #expect(!description.isMono)
    #expect(description.isPrivate)
    #expect(description.muteBehavior == .unmuted)
}

@Test func globalRecordingPersistsBothTracksWithoutAppIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    let recording = Recording.systemAudio(title: "Global meeting")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    buffer.frameLength = 480
    let channels = try #require(buffer.floatChannelData)
    for channel in 0..<2 {
        for frame in 0..<480 { channels[channel][frame] = 0.1 }
    }
    let writer = try ChunkWriter(recording: recording, store: store, format: format)
    _ = try writer.append(buffer, at: 0)
    _ = try writer.append(buffer, at: 0.005, source: .microphone)
    let completed = try writer.finish()
    let restored = try #require(store.loadAll().first)
    #expect(restored == completed)
    #expect(restored.applicationName == "系统音频")
    #expect(restored.bundleIdentifier.isEmpty)
    #expect(restored.status == .completed)
    #expect(Set(restored.chunks.map(\.audioSource)) == [.application, .microphone])
    #expect(restored.chunks.allSatisfy { $0.isComplete })
    #expect(abs(restored.duration - 0.015) < 0.000001)
    // Existing CLI filters and stored subtitles retain their wire values.
    #expect(AudioSource.application.rawValue == "application")
    #expect(AudioSource.application.label == "系统音频")
}

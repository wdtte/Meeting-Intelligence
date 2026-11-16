import Testing
import AVFoundation
import Foundation
import RealtimeAudio
import Synchronization
@testable import MeetingCore

private func temporaryStore() throws -> RecordingStore {
    try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("MeetingIntelligenceTests-\(UUID())"))
}
private func sampleBuffer(frames: UInt32 = 4800, amplitude: Float = 0.4) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for channel in 0..<2 {
        for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.1)) * amplitude }
    }
    return buffer
}
private func meeting() -> Recording {
    Recording(title: "Test", applicationName: "Fixture", bundleIdentifier: "local.test.fixture")
}

@Test func chunkRoundTripPreservesOffsetsAndGaps() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let buffer = sampleBuffer(amplitude: 0.10)
    let writer = try ChunkWriter(recording: meeting(), store: store, format: buffer.format, segmentDuration: 0.2)
    _ = try writer.append(buffer, at: 0.3)
    _ = try writer.append(buffer, at: 0.4)
    _ = try writer.append(buffer, at: 1.2)
    let finished = try writer.finish()
    #expect(finished.status == .completed)
    #expect(finished.chunks.count == 2)
    #expect(abs(finished.chunks[0].offset - 0.3) < 0.0001)
    #expect(abs(finished.chunks[1].offset - 1.2) < 0.0001)
    #expect(abs(finished.duration - 1.3) < 0.0001)
    #expect(abs(finished.audioDuration - 0.3) < 0.0001)
    #expect(try writer.finish() == finished)
    #expect(try store.loadAll() == [finished])
    let file = try AVAudioFile(forReading: store.audioURL(recording: finished.id, fileName: finished.chunks[0].fileName))
    #expect(file.length == 9600)
    let read = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 9600)!
    try file.read(into: read)
    #expect(abs(read.floatChannelData![0][300] - buffer.floatChannelData![0][300]) < 0.0001)
}

@Test func recoveryKeepsClosedAudioAndReportsIncompleteTail() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let buffer = sampleBuffer()
    var writer: ChunkWriter? = try ChunkWriter(recording: meeting(), store: store, format: buffer.format, segmentDuration: 0.1)
    _ = try writer!.append(buffer, at: 0)
    let beforeCrash = writer!.recording
    writer = nil
    let recovered = try #require(store.loadAll(recover: true).first)
    #expect(recovered.status == .interrupted)
    #expect(recovered.chunks == beforeCrash.chunks)
    #expect(recovered.note != nil)
    #expect(try store.loadAll(recover: true).first == recovered)
}

@Test func savedAudioBalancesTwoSourcesWhileMeterReportsUnprocessedInput() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let system = levelFixture(peak: 0.8, interleaved: false)
    let microphone = levelFixture(peak: 0.003, interleaved: true)
    let writer = try ChunkWriter(recording: meeting(), store: store, format: system.format)
    #expect(abs(try writer.append(system, at: 0).peak - 0.8) < 0.0001)
    #expect(abs(try writer.append(microphone, at: 0.01, source: .microphone).peak - 0.003) < 0.0001)
    try writer.checkpoint()
    let recording = try writer.finish()
    #expect(recording.chunks.map(\.offset) == [0, 0.01])
    #expect(recording.chunks.map(\.audioSource) == [.application, .microphone])
    let saved = try recording.chunks.map { try readLevel($0, recording: recording, store: store) }
    #expect(saved.allSatisfy { abs($0.rmsDB + 23) < 1 && $0.peak < 0.12 })
}

@Test func levelingDoesNotBoostSteadyNoiseAndLeavesRoomForLoudTracksToOverlap() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let loud = levelFixture(peak: 0.99, interleaved: false, transient: true)
    let noise = levelFixture(peak: 0.002, interleaved: false, burst: false)
    let silence = levelFixture(peak: 0, interleaved: false)
    let writer = try ChunkWriter(recording: meeting(), store: store, format: loud.format)
    _ = try writer.append(loud, at: 0)
    _ = try writer.append(loud, at: 0, source: .microphone)
    try writer.checkpoint()
    _ = try writer.append(noise, at: 1, source: .microphone)
    _ = try writer.append(silence, at: 1)
    let recording = try writer.finish()
    let levels = try recording.chunks.map { try readLevel($0, recording: recording, store: store) }
    #expect((0.43...0.45).contains(levels[0].peak))
    #expect((0.43...0.45).contains(levels[1].peak))
    #expect(levels[0].peak + levels[1].peak < 0.9)
    #expect(abs(levels[2].peak - 0.002) < 0.00005)
    #expect(levels[3].peak == 0)
}

private func levelFixture(peak: Float, interleaved: Bool, burst: Bool = true,
                          transient: Bool = false) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
    buffer.frameLength = 48_000
    let channels = buffer.floatChannelData!
    for frame in 0..<Int(buffer.frameLength) {
        let tone = Float(sin(Double(frame) * .pi / 12))
        let sample = if transient && frame == 100 { peak }
            else if burst && frame >= 7200 { Float(0) }
            else { tone * peak * (transient ? 0.01 : 1) }
        for channel in 0..<2 {
            if interleaved { channels[0][frame * 2 + channel] = sample }
            else { channels[channel][frame] = sample }
        }
    }
    return buffer
}

private func readLevel(_ chunk: AudioChunk, recording: Recording, store: RecordingStore) throws -> (peak: Float, rmsDB: Double) {
    let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
    #expect(file.length == 48_000)
    #expect(chunk.isComplete && abs(chunk.duration - 1) < 0.00001)
    let read = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
    try file.read(into: read)
    let samples = UnsafeBufferPointer(start: read.floatChannelData![0], count: Int(read.frameLength))
    let energy = samples.prefix(7200).reduce(0.0) { $0 + Double($1) * Double($1) }
    return (samples.map(abs).max() ?? 0, 10 * log10(energy / 7200))
}

@Test func recoveryHandlesRenameBeforeManifestCommit() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let buffer = sampleBuffer()
    let writer = try ChunkWriter(recording: meeting(), store: store, format: buffer.format, segmentDuration: 0.1)
    _ = try writer.append(buffer, at: 0.5)
    var interrupted = writer.recording
    interrupted.chunks[0].isComplete = false
    interrupted.chunks[0].duration = 0
    try store.save(interrupted)
    let recovered = try #require(store.loadAll(recover: true).first)
    #expect(recovered.chunks[0].isComplete)
    #expect(abs(recovered.chunks[0].duration - 0.1) < 0.0001)
}

@Test func backwardsClockIsRejectedRatherThanCompressingTime() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let buffer = sampleBuffer()
    let writer = try ChunkWriter(recording: meeting(), store: store, format: buffer.format)
    _ = try writer.append(buffer, at: 1)
    #expect(throws: MeetingError.self) { _ = try writer.append(buffer, at: 0) }
    let result = try writer.finish(status: .interrupted)
    #expect(abs(result.duration - 1.1) < 0.0001)
}

@Test func rejectsUnsafePathsAndCorruptManifests() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let recording = meeting()
    #expect(throws: MeetingError.self) { _ = try store.audioURL(recording: recording.id, fileName: "../outside.wav") }
    try store.save(recording)
    let url = store.directory(for: recording.id).appendingPathComponent("recording.json")
    try Data("corrupt".utf8).write(to: url)
    #expect(throws: (any Error).self) { _ = try store.loadAll(recover: true) }
    #expect(try String(contentsOf: url, encoding: .utf8) == "corrupt")
}

@Test func timelineDoesNotEraseGaps() {
    let chunks = [AudioChunk(fileName: "1.wav", offset: 2, duration: 3, sampleRate: 48000, channels: 2, isComplete: true),
                  AudioChunk(fileName: "2.wav", offset: 8, duration: 2, sampleRate: 48000, channels: 2, isComplete: true)]
    #expect(AudioTimeline.playableChunks(chunks, after: 6) == [chunks[1]])
    #expect(AudioTimeline.playableChunks(chunks, after: 5) == [chunks[1]])
    #expect(AudioTimeline.position(-5, duration: 10) == 0)
    #expect(AudioTimeline.position(20, duration: 10) == 10)
    #expect(AudioTimeline.position(.nan, duration: 10) == 0)
    #expect(AudioTimeline.clock(3661) == "1:01:01")
}

@Test func ringBufferPreservesDataAcrossWrapAndRejectsOverflow() throws {
    let ring = try #require(MIRingCreate(2, 65536)); defer { MIRingDestroy(ring) }
    let buffer = sampleBuffer(frames: 16)
    #expect(MIRingPush(ring, buffer.audioBufferList, 100))
    #expect(MIRingPush(ring, buffer.audioBufferList, 200))
    #expect(!MIRingPush(ring, buffer.audioBufferList, 300))
    #expect(MIRingDropped(ring) == 1)
    var packet = MIPacket()
    #expect(MIRingPeek(ring, &packet)); #expect(packet.hostTime == 100)
    #expect(packet.bufferCount == 2)
    let data = try #require(packet.data.0?.assumingMemoryBound(to: Float.self))
    #expect(data[10] == buffer.floatChannelData![0][10])
    MIRingPop(ring)
    #expect(MIRingPush(ring, buffer.audioBufferList, 400))
    #expect(MIRingPeek(ring, &packet)); #expect(packet.hostTime == 200); MIRingPop(ring)
    #expect(MIRingPeek(ring, &packet)); #expect(packet.hostTime == 400); MIRingPop(ring)
    #expect(!MIRingPeek(ring, &packet))
    #expect(!MIRingPush(ring, buffer.audioBufferList, 0))
    #expect(MIRingDropped(ring) == 2)
}

@Test func startupGateDiscardsWarmupWithoutOverflowOrMovingTheSharedEpoch() throws {
    let ring = try #require(MIRingCreate(2, 65536)); defer { MIRingDestroy(ring) }
    let buffer = sampleBuffer(frames: 16)
    MIRingSetStartTime(ring, UInt64.max)
    for time: UInt64 in 0..<1000 { #expect(MIRingPush(ring, buffer.audioBufferList, time)) }
    var packet = MIPacket()
    #expect(!MIRingPeek(ring, &packet))
    #expect(MIRingDropped(ring) == 0)
    MIRingSetStartTime(ring, 1000)
    #expect(MIRingPush(ring, buffer.audioBufferList, 999))
    #expect(!MIRingPeek(ring, &packet))
    #expect(MIRingPush(ring, buffer.audioBufferList, 1000))
    #expect(MIRingPeek(ring, &packet)); #expect(packet.hostTime == 1000)
    MIRingPop(ring)
    #expect(!MIRingPush(ring, buffer.audioBufferList, 0))
    #expect(MIRingDropped(ring) == 1)
}

private final class SharedRing: @unchecked Sendable {
    let ring: OpaquePointer
    init(_ ring: OpaquePointer) { self.ring = ring }
}
@Test func ringConcurrentProducerConsumerHasNoReorderedOrTornPackets() throws {
    let ring = try #require(MIRingCreate(8, 32)); defer { MIRingDestroy(ring) }
    let shared = SharedRing(ring)
    let received = Mutex<[UInt64]>([])
    let group = DispatchGroup()
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    group.enter()
    DispatchQueue.global().async {
        for value in 1...20000 {
            var data = UInt64(value)
            withUnsafeMutablePointer(to: &data) { pointer in
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: pointer))
                while !MIRingPush(shared.ring, &list, UInt64(value)) {
                    if ProcessInfo.processInfo.systemUptime > deadline { break }
                    Thread.sleep(forTimeInterval: 0.00001)
                }
            }
        }
        group.leave()
    }
    group.enter()
    DispatchQueue.global().async {
        var values: [UInt64] = []
        var packet = MIPacket()
        while values.count < 20000 && ProcessInfo.processInfo.systemUptime <= deadline {
            if MIRingPeek(shared.ring, &packet) {
                let value = packet.data.0!.load(as: UInt64.self)
                values.append(value == packet.hostTime ? value : 0)
                MIRingPop(shared.ring)
            } else { Thread.sleep(forTimeInterval: 0.00001) }
        }
        received.withLock { $0 = values }
        group.leave()
    }
    group.wait()
    #expect(received.withLock { $0 == Array(UInt64(1)...UInt64(20000)) })
}

@Test func playbackRendersSilenceDuringCaptureGapsAndSeeksIntoAudio() throws {
    let store = try temporaryStore(); defer { try? FileManager.default.removeItem(at: store.root) }
    let buffer = sampleBuffer()
    // Constant samples make audible data distinguishable from scheduled silence.
    for channel in 0..<2 { for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![channel][index] = 0.08 } }
    let writer = try ChunkWriter(recording: meeting(), store: store, format: buffer.format, segmentDuration: 0.1)
    _ = try writer.append(buffer, at: 0.1)
    _ = try writer.append(buffer, at: 0.3)
    let recording = try writer.finish()
    let files = try recording.chunks.map { chunk in
        (chunk, try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName)))
    }
    func render(from position: Double, frames: Int) throws -> [Float] {
        let engine = AVAudioEngine(); let player = AVAudioPlayerNode()
        engine.attach(player); engine.connect(player, to: engine.mainMixerNode, format: buffer.format)
        try engine.enableManualRenderingMode(.offline, format: buffer.format, maximumFrameCount: 1024)
        try engine.start(); defer { player.stop(); engine.stop() }
        try PlaybackSchedule.enqueue(files, on: player, from: position)
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: 1024)!
        var samples: [Float] = []
        var attempts = 0
        while samples.count < frames && attempts < 200 {
            attempts += 1
            let status = try engine.renderOffline(UInt32(min(1024, frames - samples.count)), to: output)
            if status == .success { samples.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength))) }
        }
        #expect(samples.count == frames)
        return samples
    }
    let whole = try render(from: 0, frames: 19200)
    guard whole.count == 19200 else { return }
    #expect(abs(whole[2400]) < 0.001) // initial offset
    #expect(abs(whole[7200] - 0.08) < 0.001)
    #expect(abs(whole[12000]) < 0.001) // capture gap
    #expect(abs(whole[16800] - 0.08) < 0.001)
    let seek = try render(from: 0.15, frames: 12000)
    guard seek.count == 12000 else { return }
    #expect(abs(seek[1200] - 0.08) < 0.001)
    #expect(abs(seek[4800]) < 0.001)
    #expect(abs(seek[9600] - 0.08) < 0.001)
}

@Test func storageDirectoriesPersistAndPreserveOldRecordingLocations() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSettingsTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageSettingsStore(base: root)
    let original = try store.load()
    let audio = root.appendingPathComponent("new-audio", isDirectory: true)
    let transcript = root.appendingPathComponent("new-transcripts", isDirectory: true)
    let changed = original.changing(.audio, to: audio).changing(.transcript, to: transcript)
    try store.save(changed, validating: audio)
    let reopened = try StorageSettingsStore(base: root).load()
    #expect(reopened.audioDirectory == audio.standardizedFileURL)
    #expect(reopened.transcriptDirectory == transcript.standardizedFileURL)
    #expect(reopened.audioHistoryDirectories.contains(original.audioDirectory))
    #expect(reopened.audioHistoryDirectories.contains(audio.standardizedFileURL))
    let duplicate = reopened.changing(.audio, to: original.audioDirectory).changing(.audio, to: audio)
    #expect(duplicate.audioHistoryDirectories.count == 2)
}

@Test func failedDirectoryChangeDoesNotReplaceWorkingSettings() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingSettingsTests-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try StorageSettingsStore(base: root)
    let original = try store.load()
    try store.save(original, validating: original.audioDirectory)
    let notDirectory = root.appendingPathComponent("existing-file")
    try Data("preserve me".utf8).write(to: notDirectory)
    #expect(throws: (any Error).self) {
        try store.save(original.changing(.audio, to: notDirectory), validating: notDirectory)
    }
    #expect(try store.load() == original)
    #expect(try String(contentsOf: notDirectory, encoding: .utf8) == "preserve me")
}

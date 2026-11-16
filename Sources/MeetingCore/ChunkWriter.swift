import AVFoundation
import Foundation

public struct AudioMeter: Sendable {
    public var peak: Float
    public var elapsed: Double
    public var savedDuration: Double
}

public final class ChunkWriter {
    public private(set) var recording: Recording
    private let store: RecordingStore
    private let segmentDuration: Double
    private final class Track {
        var format: AVAudioFormat
        var file: AVAudioFile?
        var frames: AVAudioFramePosition = 0
        var lastEnd: Double?
        var index: Int = 0
        var leveler: RecordingLeveler
        var previousGain: Double?
        init(_ format: AVAudioFormat) {
            self.format = format
            leveler = RecordingLeveler(sampleRate: format.sampleRate)
        }
    }
    private var tracks: [AudioSource: Track] = [:]
    private var finished = false

    public init(recording: Recording, store: RecordingStore, format: AVAudioFormat, segmentDuration: Double = 10) throws {
        self.recording = recording; self.store = store; self.segmentDuration = segmentDuration
        tracks[.application] = Track(format)
        try store.save(recording)
    }
    public func append(_ buffer: AVAudioPCMBuffer, at offset: Double, source: AudioSource = .application) throws -> AudioMeter {
        guard !finished, offset.isFinite, offset >= 0 else { throw MeetingError.message("录音时间戳无效。") }
        let track = tracks[source] ?? Track(buffer.format)
        tracks[source] = track
        guard buffer.frameLength > 0 else { return AudioMeter(peak: 0, elapsed: offset, savedDuration: recording.duration) }
        if let lastEnd = track.lastEnd, offset < lastEnd - 0.05 { throw MeetingError.message("音频时钟发生跳变，录音已停止。") }
        if buffer.format != track.format {
            try closeChunk(track)
            track.format = buffer.format
            track.previousGain = nil
        }
        if let lastEnd = track.lastEnd, offset - lastEnd > 0.05 {
            try closeChunk(track)
            track.previousGain = nil
        }
        if track.file == nil { try openChunk(at: offset, source: source, track: track) }
        try track.file?.write(from: buffer)
        track.frames += AVAudioFramePosition(buffer.frameLength)
        let end = recording.chunks[track.index].offset + Double(track.frames) / track.format.sampleRate
        track.lastEnd = end
        let peak = track.leveler.measure(buffer)
        if Double(track.frames) / track.format.sampleRate >= segmentDuration { try closeChunk(track) }
        return AudioMeter(peak: min(1, peak), elapsed: end, savedDuration: recording.duration)
    }
    /// Close partial segments without ending the meeting or resetting either track's clock.
    func checkpoint() throws {
        guard !finished else { return }
        for track in tracks.values {
            try closeChunk(track)
            track.previousGain = nil
        }
    }
    public func finish(status: RecordingStatus = .completed, note: String? = nil) throws -> Recording {
        if finished { return recording }
        for track in tracks.values { try closeChunk(track) }
        recording.status = status; recording.note = note; recording.endedAt = Date()
        try store.save(recording)
        finished = true
        return recording
    }
    private func openChunk(at offset: Double, source: AudioSource, track: Track) throws {
        let format = track.format
        let name = String(format: "%05d.wav", recording.chunks.count)
        let chunk = AudioChunk(source: source, fileName: name, offset: offset, duration: 0, sampleRate: format.sampleRate, channels: format.channelCount, isComplete: false)
        track.index = recording.chunks.count
        recording.chunks.append(chunk)
        // Manifest precedes file creation so a rename/manifest crash is recoverable.
        try store.save(recording)
        let finalURL = try store.audioURL(recording: recording.id, fileName: name)
        track.file = try AVAudioFile(forWriting: finalURL.deletingPathExtension().appendingPathExtension("partial.wav"), settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        track.frames = 0
        track.leveler = RecordingLeveler(sampleRate: format.sampleRate)
    }
    private func closeChunk(_ track: Track) throws {
        guard track.file != nil else { return }
        track.file = nil // AVAudioFile closes/flushed header before the atomic rename.
        let index = track.index
        let finalURL = try store.audioURL(recording: recording.id, fileName: recording.chunks[index].fileName)
        try FileManager.default.moveItem(at: finalURL.deletingPathExtension().appendingPathExtension("partial.wav"), to: finalURL)
        let source = recording.chunks[index].audioSource
        let adjustment = track.leveler.adjustment(for: source)
        let gain = adjustment.decibels
        // Let adjoining audible segments meet without an abrupt volume jump.
        // Do not carry gain into silence or exceed the new segment's headroom.
        let previous = adjustment.hasActivity ? track.previousGain ?? gain : gain
        let start = min(adjustment.headroom, max(gain - 6, min(gain + 6, previous)))
        track.previousGain = adjustment.hasActivity ? gain : nil
        if gain != 0 || start != 0 {
            let fields = ["recording_id": recording.id.uuidString, "chunk_id": recording.chunks[index].id.uuidString,
                          "source": source.rawValue, "gain_db": String(format: "%.1f", gain)]
            do {
                try RecordingLeveler.apply(gain, startingAt: start, to: finalURL)
                DiagnosticLog.shared.record("capture.audio_level.applied", fields: fields)
            } catch {
                track.previousGain = nil
                DiagnosticLog.shared.failure("capture.audio_level.failed", error: error, fields: fields)
            }
        }
        recording.chunks[index].duration = Double(track.frames) / track.format.sampleRate
        recording.chunks[index].isComplete = true
        try store.save(recording)
        track.frames = 0
    }
}

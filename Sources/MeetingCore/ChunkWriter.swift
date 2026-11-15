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
        init(_ format: AVAudioFormat) { self.format = format }
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
        }
        if let lastEnd = track.lastEnd, offset - lastEnd > 0.05 { try closeChunk(track) }
        if track.file == nil { try openChunk(at: offset, source: source, track: track) }
        try track.file?.write(from: buffer)
        track.frames += AVAudioFramePosition(buffer.frameLength)
        let end = recording.chunks[track.index].offset + Double(track.frames) / track.format.sampleRate
        track.lastEnd = end
        var peak: Float = 0
        if let channels = buffer.floatChannelData {
            let count = Int(buffer.frameLength)
            for channel in 0..<Int(track.format.channelCount) {
                for sample in 0..<count {
                    let value = track.format.isInterleaved ? channels[0][sample * Int(track.format.channelCount) + channel] : channels[channel][sample]
                    peak = max(peak, abs(value))
                }
            }
        }
        if Double(track.frames) / track.format.sampleRate >= segmentDuration { try closeChunk(track) }
        return AudioMeter(peak: min(1, peak), elapsed: end, savedDuration: recording.duration)
    }
    /// Close partial segments without ending the meeting or resetting either track's clock.
    func checkpoint() throws {
        guard !finished else { return }
        for track in tracks.values { try closeChunk(track) }
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
    }
    private func closeChunk(_ track: Track) throws {
        guard track.file != nil else { return }
        track.file = nil // AVAudioFile closes/flushed header before the atomic rename.
        let index = track.index
        let finalURL = try store.audioURL(recording: recording.id, fileName: recording.chunks[index].fileName)
        try FileManager.default.moveItem(at: finalURL.deletingPathExtension().appendingPathExtension("partial.wav"), to: finalURL)
        recording.chunks[index].duration = Double(track.frames) / track.format.sampleRate
        recording.chunks[index].isComplete = true
        try store.save(recording)
        track.frames = 0
    }
}

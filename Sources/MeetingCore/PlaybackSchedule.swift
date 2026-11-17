import AVFoundation
import Foundation

/// One streaming player per source/format. The system mixer resamples each lane
/// to the output device, so a microphone can change rate halfway through a meeting.
/// All lanes share the same start time and retain the original segment offsets.
public final class PlaybackTracks {
    private struct Track {
        let source: AudioSource
        let format: AVAudioFormat
        let player: AVAudioPlayerNode
        let timePitch: AVAudioUnitTimePitch
    }
    private let engine: AVAudioEngine
    private var tracks: [Track] = []
    private var speed: PlaybackSpeed = .normal

    public init(engine: AVAudioEngine) {
        self.engine = engine
    }

    /// Each lane stretches by the same rate on the shared player timeline.
    /// Keep its native channel layout so changing speed never changes mix levels.
    public func setSpeed(_ speed: PlaybackSpeed) {
        self.speed = speed
        for track in tracks {
            track.timePitch.rate = Float(speed.rawValue)
            track.timePitch.bypass = speed == .normal
        }
    }

    public func prepare(_ recording: Recording, store: RecordingStore) throws {
        // Inspect headers one at a time; no meeting-length audio buffers or open-file list.
        for chunk in AudioTimeline.playableChunks(recording.chunks, after: -1) {
            let file = try AVAudioFile(forReading: store.audioURL(recording: recording.id, fileName: chunk.fileName))
            let format = file.processingFormat
            if tracks.contains(where: { $0.source == chunk.audioSource && $0.format == format }) { continue }
            let player = AVAudioPlayerNode()
            let timePitch = AVAudioUnitTimePitch()
            timePitch.rate = Float(speed.rawValue); timePitch.bypass = speed == .normal
            engine.attach(player); engine.attach(timePitch)
            engine.connect(player, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
            tracks.append(Track(source: chunk.audioSource, format: format, player: player, timePitch: timePitch))
        }
    }

    public func enqueue(_ chunk: AudioChunk, file: AVAudioFile, from position: Double) throws {
        guard let track = tracks.first(where: { $0.source == chunk.audioSource && $0.format == file.processingFormat }) else {
            throw MeetingError.message("录音文件在加载后发生变化，请重新选择这条记录。")
        }
        try PlaybackSchedule.enqueue([(chunk, file)], on: track.player, from: position)
        // Offline rendering can consume the entire look-ahead window before the
        // file reader gets CPU time, especially when a new format lane is added.
        // Wait for its initial disk data rather than rendering transient silence.
        if engine.isInManualRenderingMode {
            track.player.prepare(withFrameCount: 4096)
        }
    }

    public func select(_ source: AudioSource?) {
        for track in tracks { track.player.volume = source == nil || source == track.source ? 1 : 0 }
    }
    public func play(at time: AVAudioTime? = nil) {
        for track in tracks { track.player.play(at: time) }
    }
    public func stop() {
        for track in tracks { track.player.stop(); track.timePitch.reset() }
    }
    public func clear() {
        stop()
        for track in tracks {
            engine.disconnectNodeOutput(track.player); engine.disconnectNodeOutput(track.timePitch)
            engine.detach(track.player); engine.detach(track.timePitch)
        }
        tracks = []
    }
}

/// Schedules disk-backed segments on one player timeline, including initial silence
/// and capture gaps. Shared by interactive playback and offline audio validation.
public enum PlaybackSchedule {
    public static func enqueue(_ files: [(AudioChunk, AVAudioFile)], on player: AVAudioPlayerNode, from position: Double) throws {
        guard position.isFinite, position >= 0 else { throw MeetingError.message("播放位置无效。") }
        for (chunk, file) in files where chunk.end > position {
            let rate = file.processingFormat.sampleRate
            guard chunk.offset.isFinite, chunk.duration.isFinite, chunk.offset >= 0, chunk.duration > 0,
                  abs(Double(file.length) / rate - chunk.duration) < 0.001 else {
                throw MeetingError.message("音频文件与录音清单不一致，请保留文件并检查录音目录。")
            }
            let skip = max(0, position - chunk.offset)
            let startFrame = min(file.length, AVAudioFramePosition((skip * rate).rounded()))
            let count = file.length - startFrame
            guard count > 0 else { continue }
            guard count <= Int64(UInt32.max) else { throw MeetingError.message("音频片段过长，无法播放。") }
            let delay = max(0, chunk.offset - position)
            player.scheduleSegment(file, startingFrame: startFrame, frameCount: AVAudioFrameCount(count),
                                   at: AVAudioTime(sampleTime: AVAudioFramePosition((delay * rate).rounded()), atRate: rate))
        }
    }
}

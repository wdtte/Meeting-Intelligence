import AVFoundation
import Foundation

public enum MergedAudioExporter {
    private struct Lane {
        let track: AVMutableCompositionTrack
        let source: AudioSource
        var end: CMTime
    }

    /// Compose file-backed segments without loading an entire meeting into memory.
    /// Separate lanes preserve overlapping chunks without shifting subsequent audio.
    @concurrent public static func export(_ recording: Recording, store: RecordingStore, to destination: URL) async throws {
        try Task.checkCancellation()
        guard recording.status != .recording else { throw MeetingError.message("请先结束录音，再导出完整音频。") }
        guard destination.isFileURL, destination.pathExtension.lowercased() == "m4a" else {
            throw MeetingError.message("请选择 M4A 音频文件保存位置。")
        }
        let chunks = recording.chunks.filter(\.isComplete).sorted { $0.offset < $1.offset }
        guard !chunks.isEmpty else { throw MeetingError.message("没有可导出的完整音频片段。") }
        let composition = AVMutableComposition()
        var lanes: [Lane] = []
        for chunk in chunks {
            try Task.checkCancellation()
            guard chunk.offset.isFinite, chunk.offset >= 0, chunk.duration.isFinite, chunk.duration > 0,
                  chunk.end.isFinite, chunk.end < Double(Int64.max) / 600_000 else {
                throw MeetingError.message("音频片段的时间信息无效，无法导出。")
            }
            let sourceURL = try store.audioURL(recording: recording.id, fileName: chunk.fileName)
            guard sourceURL.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath() else {
                throw MeetingError.message("不能覆盖原始录音片段，请选择其它文件名。")
            }
            let asset = AVURLAsset(url: sourceURL)
            guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                throw MeetingError.message("片段 \(chunk.fileName) 没有可读取的音频。")
            }
            let duration = try await asset.load(.duration)
            guard duration.seconds.isFinite, abs(duration.seconds - chunk.duration) < 0.001 else {
                throw MeetingError.message("片段 \(chunk.fileName) 与录音清单不一致，无法导出。")
            }
            let start = CMTime(seconds: chunk.offset, preferredTimescale: 600_000)
            let index: Int
            if let available = lanes.firstIndex(where: { $0.source == chunk.audioSource && CMTimeCompare($0.end, start) <= 0 }) {
                index = available
            } else {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                    throw MeetingError.message("无法创建合并音轨。")
                }
                index = lanes.count
                lanes.append(Lane(track: track, source: chunk.audioSource, end: .zero))
            }
            try lanes[index].track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: audioTrack, at: start)
            lanes[index].end = CMTimeAdd(start, duration)
        }

        let mix = AVMutableAudioMix()
        // Reserve headroom for simultaneous sources, including small capture-clock overlaps.
        mix.inputParameters = lanes.map { lane in
            let parameters = AVMutableAudioMixInputParameters(track: lane.track)
            parameters.setVolume(1 / Float(lanes.count), at: .zero)
            return parameters
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingError.message("系统无法创建 M4A 音频导出任务。")
        }
        session.audioMix = mix
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".meeting-export-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try await session.export(to: temporary, as: .m4a)
        try Task.checkCancellation()
        // Publish only a completed export. A failed conversion never truncates the destination.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }
}

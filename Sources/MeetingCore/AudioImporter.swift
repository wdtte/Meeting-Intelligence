import AVFoundation
import CryptoKit
import Foundation

public enum CloudAudioLimits {
    public static let diarizationDuration: Double = 120 * 60
    // Conservative client guard, independent of the 2-hour diarization product limit.
    public static let maximumDuration: Double = 12 * 60 * 60
    public static let maximumBytes: Int64 = 2_000_000_000
    public static func validate(duration: Double, diarization: Bool) throws {
        guard duration.isFinite, duration > 0, duration <= maximumDuration,
              duration * 32_000 + 44 <= Double(maximumBytes) else { throw MeetingError.message("音频为空或超过本应用文件识别上限（12 小时／2 GB）。") }
        if diarization && duration > diarizationDuration { throw MeetingError.message("区分发言人采用 120 分钟产品上限；请关闭区分后继续，原音频不会被截断。") }
    }
}

public enum CloudSessionAudioBuilder {
    public static func fingerprintAsync(chunks: [AudioChunk], store: RecordingStore, recordingID: UUID) async throws -> String {
        let worker = Task.detached(priority: .utility) { try fingerprint(chunks: chunks, store: store, recordingID: recordingID) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    public static func fingerprint(chunks: [AudioChunk], store: RecordingStore, recordingID: UUID) throws -> String {
        var hash = SHA256()
        hash.update(data: Data("pcm-s16le-16000-mono-timeline-v1".utf8))
        for chunk in chunks.sorted(by: { $0.offset == $1.offset ? $0.id.uuidString < $1.id.uuidString : $0.offset < $1.offset }) {
            try Task.checkCancellation()
            hash.update(data: try DiskFormat.encode(chunk))
            let handle = try FileHandle(forReadingFrom: store.audioURL(recording: recordingID, fileName: chunk.fileName))
            defer { try? handle.close() }
            while let bytes = try handle.read(upToCount: 262144), !bytes.isEmpty { try Task.checkCancellation(); hash.update(data: bytes) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func build(chunks: [AudioChunk], store: RecordingStore, recordingID: UUID) async throws -> URL {
        let task = Task.detached(priority: .utility) { try await buildTrack(chunks: chunks, store: store, recordingID: recordingID) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func buildTrack(chunks: [AudioChunk], store: RecordingStore, recordingID: UUID) async throws -> URL {
        let duration = chunks.map(\.end).max() ?? 0
        try CloudAudioLimits.validate(duration: duration, diarization: false)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting-Track-\(UUID()).wav")
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: url) } }
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let output = try pcmFile(url)
        let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        silence.frameLength = 4096
        silence.floatChannelData![0].initialize(repeating: 0, count: 4096)
        let total = Int64((duration * 16000).rounded())
        var written: Int64 = 0
        for chunk in chunks.sorted(by: { $0.offset == $1.offset ? $0.id.uuidString < $1.id.uuidString : $0.offset < $1.offset }) {
            try Task.checkCancellation()
            let start = Int64((chunk.offset * 16000).rounded()), end = Int64((chunk.end * 16000).rounded())
            while written < start {
                try Task.checkCancellation()
                silence.frameLength = AVAudioFrameCount(min(4096, start - written)); try output.write(from: silence); written += Int64(silence.frameLength)
            }
            let original = try store.audioURL(recording: recordingID, fileName: chunk.fileName)
            let source = try AVAudioFile(forReading: original)
            guard abs(Double(source.length) / source.processingFormat.sampleRate - chunk.duration) < 0.001 else { throw MeetingError.message("音频帧数与清单不一致。") }
            let prepared = try await CloudAudioPreparation.prepare(url: original, skipSilence: false)
            guard let convertedURL = prepared.url else { throw MeetingError.message("音轨转换失败。") }
            defer { try? FileManager.default.removeItem(at: convertedURL) }
            let input = try AVAudioFile(forReading: convertedURL)
            input.framePosition = min(input.length, max(0, written - start))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            // Small same-source overlaps use the already written samples; never shift later audio.
            while written < end && input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, end - written)))
                guard buffer.frameLength > 0 else { break }
                try output.write(from: buffer); written += Int64(buffer.frameLength)
            }
            while written < end { silence.frameLength = AVAudioFrameCount(min(4096, end - written)); try output.write(from: silence); written += Int64(silence.frameLength) }
        }
        guard abs(written - total) <= 1 else { throw MeetingError.message("音轨时间轴校验失败。") }
        success = true
        return url
    }
    static func pcmFile(_ url: URL) throws -> AVAudioFile {
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false], commonFormat: .pcmFormatFloat32, interleaved: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return file
    }
}

public struct AudioImportPreview: Sendable {
    public var fileName: String
    public var duration: Double
    public var format: String
    public var isHTML = false
    public var hasAudio = true
    public var segmentCount = 0
    public var hasSummary = false
    public var title: String? = nil
    public var isComplete = true
}
public enum AudioImporter {
    /// Discard only app-owned, unpublished staging. Published directories finish the pending transcript.
    public static func recover(store: RecordingStore) throws -> [String] {
        var notices: [String] = []
        for folder in try FileManager.default.contentsOfDirectory(at: store.root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
            if folder.lastPathComponent.hasPrefix(".import-"), UUID(uuidString: String(folder.lastPathComponent.dropFirst(8))) != nil {
                let manifest = folder.appendingPathComponent("recording.json")
                if FileManager.default.fileExists(atPath: manifest.path),
                   let recording = try? DiskFormat.read(Recording.self, at: manifest), let path = recording.transcriptPath,
                   let pending = try? Data(contentsOf: folder.appendingPathComponent("transcript.pending")),
                   (try? Data(contentsOf: URL(fileURLWithPath: path))) == pending {
                    try FileManager.default.removeItem(at: URL(fileURLWithPath: path))
                }
                try FileManager.default.removeItem(at: folder)
                notices.append("上次导入在发布前中断，已清理临时音频，请重新导入。")
            } else if UUID(uuidString: folder.lastPathComponent) != nil {
                let pending = folder.appendingPathComponent("transcript.pending")
                guard FileManager.default.fileExists(atPath: pending.path) else { continue }
                let recording = try DiskFormat.read(Recording.self, at: folder.appendingPathComponent("recording.json"))
                guard recording.id.uuidString == folder.lastPathComponent, let path = recording.transcriptPath else { throw MeetingError.message("导入发布日志异常，请保留目录。") }
                let bytes = try Data(contentsOf: pending)
                let document = try JSONDecoder().decode(TranscriptDocument.self, from: bytes)
                guard document.recordingID == recording.id else { throw MeetingError.message("导入转写与会议不匹配。") }
                let target = URL(fileURLWithPath: path)
                if !FileManager.default.fileExists(atPath: path) { try document.save(to: target) }
                try FileManager.default.removeItem(at: pending)
            }
        }
        return notices
    }
    public static func inspect(_ url: URL) throws -> AudioImportPreview {
        guard ["wav", "m4a", "mp3"].contains(url.pathExtension.lowercased()) else { throw MeetingError.message("请选择 WAV、M4A 或 MP3 音频。") }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { throw MeetingError.message("无法解码音频：文件损坏、内容与扩展名不符或没有读取权限。") }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let formatID = (file.fileFormat.settings[AVFormatIDKey] as? NSNumber)?.uint32Value
        let accepted: [String: Set<UInt32>] = ["wav": [kAudioFormatLinearPCM], "m4a": [kAudioFormatMPEG4AAC, kAudioFormatAppleLossless, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2], "mp3": [kAudioFormatMPEGLayer3]]
        guard let formatID, accepted[url.pathExtension.lowercased()]?.contains(formatID) == true else { throw MeetingError.message("文件内容与 WAV／M4A／MP3 格式不符。") }
        try CloudAudioLimits.validate(duration: duration, diarization: false)
        let sourceBytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard sourceBytes > 0, sourceBytes <= CloudAudioLimits.maximumBytes else { throw MeetingError.message("原文件为空或超过 2 GB。") }
        guard file.processingFormat.channelCount > 0 else { throw MeetingError.message("文件没有音频声道。") }
        return AudioImportPreview(fileName: url.lastPathComponent, duration: duration, format: url.pathExtension.lowercased())
    }
    public static func run(url: URL, store: RecordingStore, transcriptDirectory: URL, configuration: CloudTranscriptionConfiguration, locale: String, automaticSummary: Bool, progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> Recording {
        let task = Task.detached(priority: .utility) {
            try await perform(url: url, store: store, transcriptDirectory: transcriptDirectory, configuration: configuration, locale: locale, automaticSummary: automaticSummary, progress: progress)
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func perform(url: URL, store: RecordingStore, transcriptDirectory: URL, configuration: CloudTranscriptionConfiguration, locale: String, automaticSummary: Bool, progress: @escaping @Sendable (Double) async -> Void) async throws -> Recording {
        let preview = try inspect(url)
        try configuration.validate(); try CloudAudioLimits.validate(duration: preview.duration, diarization: configuration.diarizationEnabled == true)
        try validateCapacity(store: store, duration: preview.duration)
        var config = configuration; config.strategy = .sourceSessions
        var recording = Recording(title: url.deletingPathExtension().lastPathComponent, applicationName: "导入音频", bundleIdentifier: "")
        recording.origin = .imported; recording.transcriptionPlan = .cloudOnly; recording.cloudTranscription = config
        recording.transcriptionLocale = locale; recording.automaticSummary = automaticSummary
        recording.transcriptPath = transcriptDirectory.appendingPathComponent("\(recording.id).json").path
        let stage = store.root.appendingPathComponent(".import-\(recording.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        recording.chunks = try await stageAudio(url: url, duration: preview.duration, stage: stage, progress: progress)
        recording.status = .completed; recording.endedAt = Date()
        recording.importMetadata = AudioImportMetadata(originalFileName: preview.fileName, importedAt: recording.startedAt, format: preview.format, duration: recording.duration)
        var document = TranscriptDocument(recordingID: recording.id, locale: locale); document.status = "not_requested"
        document.cloud = CloudTranscriptionProgress(configuration: config)
        try publish(recording: recording, document: document, stage: stage, store: store)
        return recording
    }
    static func validateCapacity(store: RecordingStore, duration: Double) throws {
        let capacity = try store.root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        guard capacity > Int64(duration * 64000) + 16_777_216 else { throw MeetingError.message("导入目录可用空间不足。") }
    }
    static func stageAudio(url: URL, duration: Double, stage: URL, progress: @escaping @Sendable (Double) async -> Void) async throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        await progress(0)
        // One continuous converter is used for the entire source, before splitting its PCM frames.
        let prepared = try await CloudAudioPreparation.prepare(url: url, skipSilence: false) { await progress($0 * 0.8) }
        guard let normalized = prepared.url else { throw MeetingError.message("音频解码失败。") }
        defer { try? FileManager.default.removeItem(at: normalized) }
        let input = try AVAudioFile(forReading: normalized)
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 160_000)!
        var frames: Int64 = 0
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw MeetingError.message("音频解码提前结束。") }
            let name = "import-\(chunks.count).wav"
            do { let output = try CloudSessionAudioBuilder.pcmFile(stage.appendingPathComponent(name)); try output.write(from: buffer) }
            chunks.append(AudioChunk(source: .imported, fileName: name, offset: Double(frames) / 16000, duration: Double(buffer.frameLength) / 16000, sampleRate: 16000, channels: 1, isComplete: true))
            frames += Int64(buffer.frameLength)
            await progress(0.8 + Double(frames) / Double(input.length) * 0.2)
        }
        guard abs(Double(frames) / 16000 - duration) <= 0.02 else { throw MeetingError.message("导入音频时长校验失败。") }
        return chunks
    }
    static func publish(recording: Recording, document: TranscriptDocument, stage: URL, store: RecordingStore) throws {
        // Transcript is committed first; the final same-volume directory rename publishes the meeting.
        // The staging journal allows recovery if publication stops between volumes.
        try DiskFormat.encode(recording).write(to: stage.appendingPathComponent("recording.json"), options: .atomic)
        try DiskFormat.encode(document).write(to: stage.appendingPathComponent("transcript.pending"), options: .atomic)
        try Task.checkCancellation()
        try document.save(to: URL(fileURLWithPath: recording.transcriptPath!))
        do { try FileManager.default.moveItem(at: stage, to: store.directory(for: recording.id)) }
        catch { try? FileManager.default.removeItem(at: URL(fileURLWithPath: recording.transcriptPath!)); throw error }
        try? FileManager.default.removeItem(at: store.directory(for: recording.id).appendingPathComponent("transcript.pending"))
    }
}

import Foundation

public struct TranscriptSegment: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var chunkID: UUID
    public var source: AudioSource
    public var start: Double
    public var end: Double
    public var text: String
    public var engine: String?
    public init(chunkID: UUID, source: AudioSource, start: Double, end: Double, text: String) {
        self.chunkID = chunkID; self.source = source; self.start = start; self.end = end; self.text = text
    }
    public func contains(_ time: Double) -> Bool { start <= time && time < end }
}

public struct TranscriptDocument: Codable, Sendable, Equatable {
    public var schemaVersion = 1
    public var recordingID: UUID
    public var locale: String
    public var engine = "Apple SpeechTranscriber"
    public var segments: [TranscriptSegment] = []
    public var processedChunks: Set<UUID> = []
    public var status = "pending"
    public var error: String?
    public var cloud: CloudTranscriptionProgress?
    public var summary: TranscriptSummary?
    public init(recordingID: UUID, locale: String) { self.recordingID = recordingID; self.locale = locale }
    public mutating func commit(_ results: [TranscriptSegment], for chunk: AudioChunk) throws {
        guard results.allSatisfy({ $0.chunkID == chunk.id && $0.source == chunk.audioSource }) else {
            throw MeetingError.message("转写角色与音频来源不匹配。")
        }
        guard results.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= chunk.offset - 0.001 && $0.end <= chunk.end + 0.001 && $0.end >= $0.start }) else {
            throw MeetingError.message("转写时间戳超出音频片段范围。")
        }
        segments.removeAll { $0.chunkID == chunk.id }
        segments.append(contentsOf: results)
        segments.sort { $0.start == $1.start ? $0.source.rawValue < $1.source.rawValue : $0.start < $1.start }
        processedChunks.insert(chunk.id)
        // A summary describes a specific transcript snapshot. Never export stale text.
        if let summary, summary.inputFingerprint != summaryRequest.fingerprint { self.summary = nil }
    }
    public var summaryRequest: SummaryRequest { SummaryRequest(recordingID: recordingID, locale: locale, segments: segments) }
    public var currentSummary: TranscriptSummary? {
        guard let summary, summary.status == "completed" || summary.generatedAt != nil,
              summary.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              summary.inputFingerprint == summaryRequest.fingerprint else { return nil }
        return summary
    }
    public var summaryState: String? {
        guard let summary else { return nil }
        return summary.inputFingerprint == summaryRequest.fingerprint ? summary.status : "stale"
    }
    public var summaryExportNotice: String? {
        switch summaryState {
        case "stale": "转写已更新，摘要待重新生成。"
        case "running", "pending": "摘要正在生成，本文件仅包含导出时已有的内容。"
        case "failed": currentSummary == nil ? "摘要生成失败，可在应用中独立重试。" : "本次摘要生成失败，以下保留上次成功摘要。"
        case "interrupted": currentSummary == nil ? "摘要生成已中断，可在应用中独立重试。" : "本次摘要生成已中断，以下保留上次成功摘要。"
        default: nil
        }
    }
    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
    public static func load(from url: URL, recordingID: UUID) throws -> Self {
        let document = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        guard document.schemaVersion == 1, document.recordingID == recordingID else {
            throw MeetingError.message("Transcript 与会议不匹配，请保留原文件。")
        }
        return document
    }
}

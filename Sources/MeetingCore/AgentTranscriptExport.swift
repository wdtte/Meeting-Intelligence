import Darwin
import Foundation

/// Deliberate public DTO mapping: internal checkpoints and credentials never enter CLI output.
public enum AgentTranscriptExport {
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
    public static func nullable(_ value: Any?) -> Any { value ?? NSNull() }
    public static func segment(_ value: TranscriptSegment, document: TranscriptDocument? = nil) -> [String: Any] {
        ["segment_id": value.id.uuidString, "chunk_id": nullable(value.chunkID?.uuidString), "source": value.source.rawValue,
         "start": value.start, "end": value.end, "text": value.text, "engine": nullable(value.engine), "session_id": nullable(value.sessionID?.uuidString),
         "speaker_id": nullable(value.speakerID?.uuidString), "speaker_name": nullable(document.map { $0.speakerName(for: value) })]
    }
    public static func metadata(_ snapshot: MeetingReadSnapshot) -> [String: Any] {
        let r = snapshot.recording, t = snapshot.transcript
        return ["meeting_id": snapshot.meetingID.uuidString, "metadata_available": r != nil,
                "title": nullable(r?.title), "application_name": nullable(r?.applicationName),
                "bundle_identifier": nullable(r?.bundleIdentifier), "started_at": nullable(r.map { timestamp($0.startedAt) }),
                "ended_at": nullable(r?.endedAt.map(timestamp)), "duration": nullable(r?.duration),
                "recording_status": nullable(r?.status.rawValue), "local_status": r?.effectivePlan == .cloudOnly ? "not_requested" : nullable(t?.status),
                "cloud_status": snapshot.cloudEnabled ? (t?.cloud?.status ?? "pending") : "disabled",
                "content_state": snapshot.contentState, "revision": snapshot.revision,
                "locale": nullable(t?.locale), "segment_count": t?.segments.count ?? 0,
                "has_transcript": t?.segments.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false,
                "closed_chunk_count": nullable(snapshot.closedChunkCount), "processed_chunk_count": nullable(snapshot.processedChunkCount),
                "transcription_plan": r?.effectivePlan.rawValue ?? "localThenCloud",
                "origin": r?.origin?.rawValue ?? "recorded",
                "cloud_session_count": t?.cloud?.sessions?.count ?? 0,
                "cloud_completed_session_count": t?.cloud?.sessions?.filter { $0.status == "completed" }.count ?? 0,
                "local_completion_ratio": nullable(r?.effectivePlan == .cloudOnly ? nil : snapshot.closedChunkCount.flatMap { total in
                    total == 0 ? nil : Double(snapshot.processedChunkCount ?? 0) / Double(total)
                }),
                "cloud_completed_chunk_count": nullable(t?.cloud?.completedCount),
                "summary_status": nullable(t?.summaryState)]
    }
    public static func warning(_ value: MeetingReadWarning) -> [String: Any] {
        ["code": value.code, "message": value.message, "meeting_id": nullable(value.meetingID?.uuidString), "path": nullable(value.path)]
    }
    public static func envelope(data: Any, warnings: [MeetingReadWarning] = [], page: [String: Any]? = nil, partial: Bool = false) -> [String: Any] {
        var result: [String: Any] = ["schema_version": "2", "data": data, "warnings": warnings.map(warning), "partial_results": partial]
        if let page { result["page"] = page }
        return result
    }
    public static func json(_ value: Any, pretty: Bool = false) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes])
    }
    public static func snapshot(_ value: MeetingReadSnapshot, exportedAt: Date = Date()) -> [String: Any] {
        var data = metadata(value)
        if let summary = value.transcript?.currentSummary {
            data["summary"] = ["text": nullable(summary.text), "model": nullable(summary.model),
                               "provider": summary.provider.rawValue, "generated_at": nullable(summary.generatedAt.map(timestamp))]
        } else { data["summary"] = NSNull() }
        data["segments"] = value.segments.map { segment($0, document: value.transcript) }
        data["exported_at"] = timestamp(exportedAt)
        return envelope(data: data, warnings: value.warnings)
    }
    private static func markdownEscape(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        for character in ["\\", "`", "*", "_", "{", "}", "[", "]", "(", ")", "#", "+", "-", ".", "!", "|"] {
            result = result.replacingOccurrences(of: character, with: "\\" + character)
        }
        return result
    }
    public static func markdown(_ value: MeetingReadSnapshot, exportedAt: Date = Date()) -> String {
        var lines = ["# \(markdownEscape(value.recording?.title ?? "Transcript"))", "",
                     "meeting_id: \(value.meetingID.uuidString)", "revision: \(value.revision)",
                     "exported_at: \(timestamp(exportedAt))", "schema_version: 2",
                     "content_state: \(value.contentState)", "local_status: \(value.transcript?.status ?? "unavailable")",
                     "cloud_status: \(value.cloudEnabled ? (value.transcript?.cloud?.status ?? "pending") : "disabled")",
                     "summary_status: \(value.transcript?.summaryState ?? "not_generated")", ""]
        if let recording = value.recording {
            lines += ["started_at: \(timestamp(recording.startedAt))", "application: \(markdownEscape(recording.applicationName))", ""]
        }
        if let notice = value.transcript?.summaryExportNotice { lines += ["## 摘要状态", "", notice, ""] }
        if let summary = value.transcript?.currentSummary, let text = summary.text {
            lines += ["## 会议摘要", "", text.components(separatedBy: .newlines).map { "> " + markdownEscape($0) }.joined(separator: "\n"), ""]
        }
        for segment in value.segments {
            lines += ["## \(segment.start)–\(segment.end)s · \(segment.source.rawValue)", "",
                      "meeting_id: \(value.meetingID.uuidString)  ", "revision: \(value.revision)  ",
                      "segment_id: \(segment.id.uuidString)  ", "chunk_id: \(segment.chunkID?.uuidString ?? "null")  ",
                      "session_id: \(segment.sessionID?.uuidString ?? "null")  ",
                      "speaker_id: \(segment.speakerID?.uuidString ?? "null")  ",
                      "speaker_name: \(markdownEscape(value.transcript?.speakerName(for: segment) ?? "未区分发言人"))  ",
                      "engine: \(markdownEscape(segment.engine ?? "null"))", "",
                      // Blockquotes retain literal line breaks and keep transcript content separate from citation fields.
                      segment.text.components(separatedBy: .newlines).map { "> " + markdownEscape($0) }.joined(separator: "\n"), ""]
        }
        return lines.joined(separator: "\n") + "\n"
    }
    /// Publish a sibling temporary file atomically. link() provides an exclusive no-clobber publish.
    public static func write(_ bytes: Data, to destination: URL, overwrite: Bool) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".meeting-export-\(UUID())")
        do {
            try bytes.write(to: temp, options: [.withoutOverwriting])
            defer { try? FileManager.default.removeItem(at: temp) }
            let result = temp.withUnsafeFileSystemRepresentation { source in
                destination.withUnsafeFileSystemRepresentation { target in
                    overwrite ? Darwin.rename(source!, target!) : Darwin.link(source!, target!)
                }
            }
            if result != 0 {
                if errno == EEXIST { throw MeetingReadError("OUTPUT_EXISTS", "导出目标已存在；使用 --overwrite 显式替换。", exitCode: 5) }
                throw MeetingReadError("FILE_ACCESS_FAILED", "无法发布导出文件：\(destination.path)", exitCode: 5)
            }
        } catch let error as MeetingReadError { throw error }
        catch { throw MeetingReadError("FILE_ACCESS_FAILED", "无法写入导出文件：\(destination.path)", exitCode: 5) }
    }
}

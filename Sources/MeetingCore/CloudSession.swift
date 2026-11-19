import Foundation

public enum CloudTaskStrategy: String, Codable, Sendable { case legacyChunks, sourceSessions }
public struct CloudTranscriptionSession: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var runID: UUID
    public var source: AudioSource
    public var chunkIDs: [UUID]
    public var timelineOrigin: Double = 0
    public var duration: Double
    public var inputFingerprint: String
    public var configuration: CloudTranscriptionConfiguration
    public var model: String
    public var checkpoint: ProviderCheckpoint?
    public var submittedAt: Date?
    public var lastPolledAt: Date?
    public var status = "pending"
    public var error: String?
    public var noSpeechRecognized = false
    public var usage: TranscriptionUsage?
    public init(runID: UUID, source: AudioSource, chunks: [AudioChunk], fingerprint: String, configuration: CloudTranscriptionConfiguration) {
        self.runID = runID; self.source = source; self.chunkIDs = chunks.map(\.id)
        self.duration = chunks.map(\.end).max() ?? 0; self.inputFingerprint = fingerprint
        self.configuration = configuration; self.model = configuration.model
    }
}
public struct CloudRunHistory: Codable, Sendable, Equatable {
    public var runID: UUID
    public var configuration: CloudTranscriptionConfiguration?
    public var jobs: [String: CloudChunkJob]?
    public var sessions: [CloudTranscriptionSession]
    public var segments: [TranscriptSegment]
    public var speakers: [Speaker]
    public var speakerOverrides: [String: UUID]?
    public var unassignedSegments: Set<UUID>?
}
public struct Speaker: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var sessionID: UUID
    public var providerSpeakerID: String
    public var displayName: String?
    public var createdOrder: Int
    public var name: String {
        let custom = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return custom.isEmpty ? "发言人 \(createdOrder)" : custom
    }
}
public extension TranscriptDocument {
    var resolvedSegments: [TranscriptSegment] {
        segments.map { segment in
            var value = segment
            if unassignedSegments?.contains(value.id) == true { value.speakerID = nil }
            else if let override = speakerOverrides?[value.id.uuidString] { value.speakerID = override }
            return value
        }
    }
    func speakerName(for segment: TranscriptSegment) -> String {
        let resolved = resolvedSegments.first { $0.id == segment.id } ?? segment
        return speakers?.first { $0.id == resolved.speakerID }?.name ?? "未区分发言人"
    }
    mutating func renameSpeaker(_ id: UUID, name: String) throws {
        guard let index = speakers?.firstIndex(where: { $0.id == id }) else { throw MeetingError.message("发言人不存在。") }
        guard name.count <= 100 else { throw MeetingError.message("发言人名称不能超过 100 个字符。") }
        speakers?[index].displayName = name
    }
    mutating func assignSpeaker(segmentID: UUID, speakerID: UUID?) throws {
        guard segments.contains(where: { $0.id == segmentID }), speakerID == nil || speakers?.contains(where: { $0.id == speakerID }) == true else { throw MeetingError.message("字幕或发言人不存在。") }
        if let speakerID {
            if speakerOverrides == nil { speakerOverrides = [:] }
            speakerOverrides?[segmentID.uuidString] = speakerID; unassignedSegments?.remove(segmentID)
        } else {
            speakerOverrides?.removeValue(forKey: segmentID.uuidString)
            if unassignedSegments == nil { unassignedSegments = [] }
            unassignedSegments?.insert(segmentID)
        }
    }
    mutating func commitSessionResult(_ result: ProviderTranscription, session: CloudTranscriptionSession, replacingImportedSnapshot: Bool = false) throws {
        guard schemaVersion == 2, session.timelineOrigin == 0, session.duration.isFinite, session.duration > 0,
              let saved = cloud?.sessions?.first(where: { $0.id == session.id }),
              saved.inputFingerprint == session.inputFingerprint, saved.runID == session.runID, saved.source == session.source,
              result.segments.allSatisfy({ $0.sessionID == nil || $0.sessionID == session.id }) else { throw MeetingError.message("云任务与当前音频不匹配。") }
        var lastStart = -Double.infinity
        for segment in result.segments {
            guard segment.source == session.source, segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.start >= lastStart, segment.end > segment.start,
                  segment.end <= session.duration + 0.02 else { throw MeetingError.message("整轨转写时间或来源无效。") }
            lastStart = segment.start
        }
        guard let index = cloud?.sessions?.firstIndex(where: { $0.id == session.id }) else { return }
        if cloud?.sessions?[index].status == "completed" { return }
        if result.noSpeechRecognized {
            // Kept local fallback must never imply diarization from an earlier cloud run.
            for index in segments.indices where replacingImportedSnapshot || segments[index].source == session.source {
                segments[index].speakerID = nil
                speakerOverrides?.removeValue(forKey: segments[index].id.uuidString)
            }
        } else {
            var people = speakers ?? []
            var replacement: [TranscriptSegment] = []
            for segment in result.segments {
                var value = segment; value.chunkID = nil; value.sessionID = session.id; value.speakerID = nil
                if session.configuration.diarizationEnabled == true, let providerID = value.providerSpeakerID {
                    if !people.contains(where: { $0.sessionID == session.id && $0.providerSpeakerID == providerID }) {
                        people.append(Speaker(sessionID: session.id, providerSpeakerID: providerID, createdOrder: (people.map(\.createdOrder).max() ?? 0) + 1))
                    }
                    value.speakerID = people.first { $0.sessionID == session.id && $0.providerSpeakerID == providerID }?.id
                }
                replacement.append(value)
            }
            let removed = Set(segments.filter { replacingImportedSnapshot || ($0.source == session.source && ($0.sessionID == session.id || $0.start < session.duration)) }.map(\.id))
            segments.removeAll { removed.contains($0.id) }
            speakerOverrides = speakerOverrides?.filter { key, _ in UUID(uuidString: key).map { !removed.contains($0) } ?? false }
            unassignedSegments?.subtract(removed)
            segments.append(contentsOf: replacement); segments.sort(by: MeetingQuery.segmentOrder)
            let retainedIDs = Set(segments.compactMap(\.speakerID))
            speakers = people.filter { $0.sessionID == session.id || retainedIDs.contains($0.id) }
        }
        cloud?.sessions?[index].status = "completed"
        cloud?.sessions?[index].error = nil
        cloud?.sessions?[index].noSpeechRecognized = result.noSpeechRecognized
        cloud?.sessions?[index].usage = result.usage
        if !segments.isEmpty { engine = Set(segments.map { $0.engine ?? "Apple SpeechTranscriber" }).sorted().joined(separator: " + ") }
    }
}

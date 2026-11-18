import CryptoKit
import Foundation

/// Errors in the agent-facing read contract. No reader uses the application's recovery stores.
public struct MeetingReadError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let exitCode: Int32
    public let retryable: Bool
    public var errorDescription: String? { message }
    public init(_ code: String, _ message: String, exitCode: Int32 = 4, retryable: Bool = false) {
        self.code = code; self.message = message; self.exitCode = exitCode; self.retryable = retryable
    }
}

public struct MeetingReadWarning: Sendable, Equatable {
    public let code: String
    public let message: String
    public let meetingID: UUID?
    public let path: String?
    public init(_ code: String, _ message: String, meetingID: UUID? = nil, path: String? = nil) {
        self.code = code; self.message = message; self.meetingID = meetingID; self.path = path
    }
}

public struct MeetingReadEntry: Sendable {
    public let recording: Recording
    public let manifestURL: URL
    public let manifestBytes: Data
}

public struct MeetingReadCatalog: Sendable {
    public let entries: [MeetingReadEntry]
    public let warnings: [MeetingReadWarning]
    public let failures: [UUID: MeetingReadError]
}

public struct MeetingReadSnapshot: Sendable {
    public let recording: Recording?
    public let transcript: TranscriptDocument?
    public let transcriptURL: URL
    public let revision: String
    public var meetingID: UUID { recording?.id ?? transcript!.recordingID }
    public var segments: [TranscriptSegment] { (transcript?.resolvedSegments ?? []).sorted(by: MeetingQuery.segmentOrder) }
    public var closedChunkCount: Int? { recording.map { $0.chunks.filter(\.isComplete).count } }
    public var processedChunkCount: Int? {
        recording.map { recording in recording.chunks.filter { $0.isComplete && (transcript?.processedChunks.contains($0.id) ?? false) }.count }
    }
    public var cloudEnabled: Bool { recording?.cloudTranscription != nil || transcript?.cloud != nil }
    public var contentState: String {
        guard let document = transcript else { return "unavailable" }
        let known = ["pending", "running", "completed", "failed", "interrupted", "not_requested"]
        guard known.contains(document.status), !cloudEnabled || known.contains(document.cloud?.status ?? "pending") else { return "unknown" }
        guard (recording?.effectivePlan == .cloudOnly || document.status == "completed"), recording?.status != .recording,
              recording?.effectivePlan == .cloudOnly || closedChunkCount == nil || closedChunkCount == processedChunkCount,
              recording?.chunks.allSatisfy(\.isComplete) ?? true else { return "partial" }
        if cloudEnabled {
            guard let cloud = document.cloud, cloud.status == "completed" else { return "partial" }
            if cloud.configuration.usesSessions {
                guard let sessions = cloud.sessions, !sessions.isEmpty, sessions.allSatisfy({ $0.status == "completed" }),
                      recording.map({ Set($0.chunks.filter(\.isComplete).map(\.id)) == Set(sessions.flatMap(\.chunkIDs)) }) ?? true else { return "partial" }
                return "complete"
            }
            if let recording, !recording.chunks.filter(\.isComplete).allSatisfy({ cloud.jobs[$0.id.uuidString]?.completed == true }) {
                return "partial"
            }
        }
        return "complete"
    }
    public var warnings: [MeetingReadWarning] {
        if transcript == nil {
            return [.init("TRANSCRIPT_NOT_FOUND", "转写文件不存在。", meetingID: meetingID, path: transcriptURL.path)]
        }
        if contentState == "partial" {
            return [.init("TRANSCRIPT_IN_PROGRESS", "转写尚未全部完成，正文可能更新。", meetingID: meetingID)]
        }
        if contentState == "unknown" {
            return [.init("UNKNOWN_PROCESSING_STATUS", "处理状态未知，不能确认正文完整。", meetingID: meetingID)]
        }
        return []
    }
    public func requireTranscript(complete: Bool = false) throws {
        guard transcript != nil else { throw MeetingReadError("TRANSCRIPT_NOT_FOUND", "转写不存在：\(transcriptURL.path)", exitCode: 3) }
        if complete && contentState != "complete" {
            throw MeetingReadError("TRANSCRIPT_INCOMPLETE", "本地及已启用的云端转写尚未全部完成。", exitCode: 7)
        }
    }
}

public enum MeetingFingerprint {
    /// Length prefixes keep different file boundaries unambiguous. Nil is distinct from an empty file.
    public static func digest(_ parts: [Data?]) -> String {
        var hasher = SHA256()
        for part in parts {
            var length = (part.map { UInt64($0.count) } ?? UInt64.max).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            if let part { hasher.update(data: part) }
        }
        return "sha256:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct MeetingReadRepository: Sendable {
    public let base: URL
    public let settings: StorageSettings
    public let settingsPresent: Bool
    public let audioRoots: [URL]
    private let settingsBytes: Data?

    public init(base: URL) throws {
        self.base = base.standardizedFileURL.resolvingSymlinksInPath()
        try DataMigration.assertReadable(base: self.base)
        let config = self.base.appendingPathComponent("settings.json")
        let bytes = try Self.read(config, optional: true)
        settingsBytes = bytes; settingsPresent = bytes != nil
        if let bytes {
            try StorageSettingsStore.checkVersion(bytes)
            do { settings = try JSONDecoder().decode(StorageSettings.self, from: bytes) }
            catch { throw MeetingReadError("INVALID_SETTINGS", "无法解析配置：\(config.path)") }
            guard settings.audioDirectory.isFileURL, settings.transcriptDirectory.isFileURL,
                  settings.audioHistoryDirectories.allSatisfy(\.isFileURL) else {
                throw MeetingReadError("INVALID_SETTINGS", "保存目录必须是本地文件路径。")
            }
        } else {
            settings = .defaults(base: self.base)
            guard try Self.isDirectory(settings.audioDirectory) else {
                throw MeetingReadError("DATA_ROOT_NOT_FOUND", "未找到数据目录；请指定 --data-dir 或 MEETING_DATA_DIR（包含 settings.json 的目录）。", exitCode: 3)
            }
        }
        var seen = Set<String>()
        audioRoots = ([settings.audioDirectory] + settings.audioHistoryDirectories).compactMap {
            let url = $0.standardizedFileURL.resolvingSymlinksInPath()
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    public static var defaultBase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Meeting Intelligence", isDirectory: true)
    }

    public func catalog() throws -> MeetingReadCatalog {
        var entries: [UUID: MeetingReadEntry] = [:]
        var warnings: [MeetingReadWarning] = []
        var failures: [UUID: MeetingReadError] = [:]
        var accessibleRoots = 0
        for root in audioRoots {
            let folders: [URL]
            do {
                folders = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
                accessibleRoots += 1
            } catch {
                warnings.append(.init("DIRECTORY_UNAVAILABLE", "音频目录不可读：\(root.path)", path: root.path))
                continue
            }
            for folder in folders {
                guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
                let url = folder.appendingPathComponent("recording.json")
                do {
                    let bytes = try Self.stableRead(url)
                    let recording = try Self.decodeRecording(bytes, expectedID: id)
                    if let existing = entries[id] {
                        guard existing.manifestBytes == bytes else {
                            throw MeetingReadError("DUPLICATE_MEETING_ID", "同一会议 ID 存在不同清单：\(id)。请使用更精确的数据目录。")
                        }
                    } else {
                        entries[id] = .init(recording: recording, manifestURL: url, manifestBytes: bytes)
                    }
                } catch let error as MeetingReadError {
                    if error.code == "DUPLICATE_MEETING_ID" { throw error }
                    failures[id] = error
                    warnings.append(.init(error.code, error.message, meetingID: id, path: url.path))
                }
            }
        }
        guard accessibleRoots > 0 else { throw MeetingReadError("DIRECTORY_UNAVAILABLE", "所有音频目录均不可读。", exitCode: 5) }
        // An unreadable duplicate must not make a UUID look unambiguous.
        for id in failures.keys { entries.removeValue(forKey: id) }
        return .init(entries: entries.values.sorted { MeetingQuery.recordingOrder($0.recording, $1.recording) }, warnings: warnings, failures: failures)
    }

    public func snapshot(id: UUID) throws -> MeetingReadSnapshot {
        let catalog = try catalog()
        if let failure = catalog.failures[id] { throw failure }
        guard let entry = catalog.entries.first(where: { $0.recording.id == id }) else {
            if catalog.warnings.contains(where: { $0.code == "DIRECTORY_UNAVAILABLE" }) {
                throw MeetingReadError("DIRECTORY_UNAVAILABLE", "部分历史目录不可读，无法确认目标会议。", exitCode: 5)
            }
            throw MeetingReadError("MEETING_NOT_FOUND", "未找到会议：\(id)", exitCode: 3)
        }
        return try snapshot(entry: entry)
    }

    public func snapshot(entry: MeetingReadEntry) throws -> MeetingReadSnapshot {
        try DataMigration.assertReadable(base: base)
        for _ in 0..<3 {
            let manifest = try Self.read(entry.manifestURL)!
            let recording = try Self.decodeRecording(manifest, expectedID: entry.recording.id)
            let url = transcriptURL(for: recording)
            let transcript = try Self.read(url, optional: true)
            let manifestAfter = try Self.read(entry.manifestURL, optional: true)
            let transcriptAfter = try Self.read(url, optional: true)
            guard manifest == manifestAfter, transcript == transcriptAfter else { continue }
            try DataMigration.assertReadable(base: base)
            let document = try transcript.map { try Self.decodeTranscript($0, expectedID: recording.id) }
            return .init(recording: recording, transcript: document, transcriptURL: url,
                         revision: MeetingFingerprint.digest([manifest, transcript]))
        }
        throw Self.changing
    }

    public static func standalone(file: URL) throws -> MeetingReadSnapshot {
        let bytes = try stableRead(file)
        return try .init(recording: nil, transcript: decodeTranscript(bytes, expectedID: nil), transcriptURL: file,
                         revision: MeetingFingerprint.digest([bytes]))
    }

    public func transcriptURL(for recording: Recording) -> URL {
        if let path = recording.transcriptPath {
            // The app persists absolute file paths. Do not silently substitute another copy.
            return URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
        }
        return settings.transcriptDirectory.appendingPathComponent("\(recording.id.uuidString).json")
    }

    /// Detect changes to configuration, directory membership and manifests across a collection scan.
    public func verify(_ catalog: MeetingReadCatalog, snapshots: [MeetingReadSnapshot]) throws {
        guard try Self.read(base.appendingPathComponent("settings.json"), optional: true) == settingsBytes else { throw Self.changing }
        let after = try self.catalog()
        guard catalog.entries.map(\.manifestURL) == after.entries.map(\.manifestURL),
              catalog.entries.map(\.manifestBytes) == after.entries.map(\.manifestBytes),
              catalog.warnings == after.warnings else { throw Self.changing }
        for snapshot in snapshots {
            guard let entry = after.entries.first(where: { $0.recording.id == snapshot.meetingID }) else { throw Self.changing }
            let current = try self.snapshot(entry: entry)
            guard current.revision == snapshot.revision else { throw Self.changing }
        }
    }

    public static var changing: MeetingReadError {
        .init("DATA_CHANGING", "数据正在更新，请重试。", exitCode: 6, retryable: true)
    }
    public static func isDirectory(_ url: URL) throws -> Bool {
        do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory }
        catch {
            if isMissing(error) { return false }
            throw accessError(url)
        }
    }
    private static func isMissing(_ error: any Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(value.code)) ||
            (value.domain == NSPOSIXErrorDomain && value.code == 2)
    }
    private static func accessError(_ url: URL) -> MeetingReadError {
        .init("FILE_ACCESS_FAILED", "无法读取文件：\(url.path)", exitCode: 5)
    }
    private static func read(_ url: URL, optional: Bool = false) throws -> Data? {
        do { return try Data(contentsOf: url) }
        catch {
            if isMissing(error) {
                if optional { return nil }
                throw MeetingReadError("FILE_NOT_FOUND", "文件不存在：\(url.path)", exitCode: 3)
            }
            throw accessError(url)
        }
    }
    private static func stableRead(_ url: URL) throws -> Data {
        for _ in 0..<3 {
            let bytes = try read(url)!
            if try read(url, optional: true) == bytes { return bytes }
        }
        throw changing
    }
    private static func checkSchema(_ bytes: Data) throws {
        _ = try DiskFormat.version(bytes)
    }
    private static func decodeRecording(_ bytes: Data, expectedID: UUID) throws -> Recording {
        try checkSchema(bytes)
        let value: Recording
        do { value = try JSONDecoder().decode(Recording.self, from: bytes) }
        catch { throw MeetingReadError("DATA_CORRUPT", "录音清单格式损坏：\(expectedID)。") }
        guard value.id == expectedID else { throw MeetingReadError("RECORDING_ID_MISMATCH", "目录与录音 ID 不匹配。") }
        guard value.startedAt.timeIntervalSince1970.isFinite,
              value.endedAt.map({ $0.timeIntervalSince1970.isFinite && $0 >= value.startedAt }) ?? true,
              Set(value.chunks.map(\.id)).count == value.chunks.count,
              value.chunks.allSatisfy({ $0.offset.isFinite && $0.duration.isFinite && $0.end.isFinite && $0.offset >= 0 && $0.duration >= 0 }) else {
            throw MeetingReadError("INVALID_TIMESTAMPS", "录音时间或片段数据无效。")
        }
        return value
    }
    private static func decodeTranscript(_ bytes: Data, expectedID: UUID?) throws -> TranscriptDocument {
        try checkSchema(bytes)
        let value: TranscriptDocument
        do { value = try JSONDecoder().decode(TranscriptDocument.self, from: bytes) }
        catch { throw MeetingReadError("DATA_CORRUPT", "转写文件格式损坏。") }
        guard expectedID == nil || value.recordingID == expectedID else {
            throw MeetingReadError("RECORDING_ID_MISMATCH", "转写与会议 ID 不匹配。")
        }
        guard Set(value.segments.map(\.id)).count == value.segments.count,
              value.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
            throw MeetingReadError("INVALID_TIMESTAMPS", "转写时间戳或段落 ID 无效。")
        }
        return value
    }
}

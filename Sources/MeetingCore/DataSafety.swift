import CoreFoundation
import CryptoKit
import Darwin
import Foundation

public enum DiskFormat {
    public static let current = 2
    public static func version(_ bytes: Data) throws -> Int {
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              let number = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue) else {
            throw MeetingReadError("DATA_CORRUPT", "文件缺少有效 schemaVersion；请保留原文件。")
        }
        let version = number.intValue
        guard (1...current).contains(version) else {
            throw MeetingReadError("UNSUPPORTED_SCHEMA", "数据格式 v\(version) 不受支持，请使用兼容版本打开。")
        }
        return version
    }
    public static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T {
        let bytes = try Data(contentsOf: url)
        _ = try version(bytes)
        do { return try JSONDecoder().decode(type, from: bytes) }
        catch { throw MeetingReadError("DATA_CORRUPT", "文件损坏：\(url.path)。请保留原文件。") }
    }
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
    public static func write<T: Codable>(_ value: T, to url: URL) throws {
        var bytes = try encode(value)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try Data(contentsOf: url)
            let oldVersion = try version(previous), newVersion = try version(bytes)
            guard newVersion >= oldVersion else { throw MeetingReadError("UNSUPPORTED_SCHEMA", "禁止用旧格式覆盖新数据，请重新加载。") }
            guard oldVersion == newVersion else { throw MeetingReadError("MIGRATION_REQUIRED", "修改前需要备份并升级会议数据。") }
            // Preserve unknown fields in known objects; removed array elements stay removed.
            _ = try JSONDecoder().decode(T.self, from: previous)
            let old = try JSONSerialization.jsonObject(with: previous)
            let new = try JSONSerialization.jsonObject(with: bytes)
            let previousIdentity = (old as? [String: Any])?["recordingID"] as? String ?? (old as? [String: Any])?["id"] as? String
            let nextIdentity = (new as? [String: Any])?["recordingID"] as? String ?? (new as? [String: Any])?["id"] as? String
            guard previousIdentity == nextIdentity else { throw MeetingReadError("RECORDING_ID_MISMATCH", "禁止覆盖其他会议的文件。") }
            bytes = try JSONSerialization.data(withJSONObject: preservingUnknown(old: old, new: new), options: [.prettyPrinted, .sortedKeys])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private static func preservingUnknown(old: Any, new: Any) -> Any {
        if let old = old as? [String: Any], let new = new as? [String: Any] {
            var result = old
            for (key, value) in new {
                if ["jobs", "speakerOverrides"].contains(key), let entries = value as? [String: Any] {
                    let previous = old[key] as? [String: Any] ?? [:]
                    result[key] = Dictionary(uniqueKeysWithValues: entries.map { identity, entry in
                        (identity, key == "jobs" ? (previous[identity].map { preservingUnknown(old: $0, new: entry) } ?? entry) : entry)
                    })
                } else { result[key] = old[key].map { preservingUnknown(old: $0, new: value) } ?? value }
            }
            // Known optional fields must be removable; unknown fields remain intact.
            for key in ["error", "summary", "speakerID", "sessionID", "providerSpeakerID", "displayName", "checkpoint", "usage", "note", "cloud", "cloudTranscription", "endedAt", "text", "model", "generatedAt", "requestID", "chunkID", "origin", "importMetadata", "transcriptionPlan", "automaticSummary", "sessions", "history", "speakers", "speakerOverrides", "unassignedSegments", "transcriptionLocale", "transcriptPath", "microphoneCaptureMode", "source", "diarizationEnabled", "strategy", "submittedAt", "lastPolledAt", "noSpeechRecognized", "inputTokens", "outputTokens", "modelName", "keyID", "recordedAt"] where new[key] == nil { result.removeValue(forKey: key) }
            return result
        }
        if let old = old as? [[String: Any]], let new = new as? [[String: Any]] {
            return new.map { value -> Any in
                guard let id = value["id"] as? String, let prior = old.first(where: { $0["id"] as? String == id }) else { return value }
                return preservingUnknown(old: prior, new: value)
            }
        }
        return new
    }

}

/// Original-byte metadata backups; never audio or Keychain secrets.
public struct DataMigration: Sendable {
    public let base: URL
    private let beforeReplace: @Sendable (Int) throws -> Void
    public init(base: URL) { self.base = base; self.beforeReplace = { _ in } }
    init(base: URL, beforeReplace: @escaping @Sendable (Int) throws -> Void) { self.base = base; self.beforeReplace = beforeReplace }
    public struct Item: Codable, Sendable {
        public var path: String
        public var backup: String
        public var prepared: String
        public var originalHash: String
        public var replacementHash: String
        public var size: Int
    }
    public struct Journal: Codable, Sendable {
        public var id: UUID
        public var fromVersion: Int
        public var toVersion: Int
        public var applicationVersion: String
        public var state: String
        public var items: [Item]
    }
    public var backupRoot: URL { base.appendingPathComponent("Backups", isDirectory: true) }
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let descriptor = open(base.appendingPathComponent(".metadata-writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MeetingReadError("FILE_ACCESS_FAILED", "无法锁定数据目录。", exitCode: 5) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw MeetingReadError("MIGRATION_BUSY", "另一实例正在修改数据，请稍后重试。", exitCode: 6, retryable: true) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
    public static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private func validateTarget(_ url: URL) throws {
        guard url.isFileURL, url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw MeetingError.message("迁移不允许通过符号链接写入：\(url.path)") }
    }
    @discardableResult public func upgrade(manifest: URL, transcript: URL?) throws -> URL? {
        try withLock {
            try recoverUnlocked()
            let original = try Data(contentsOf: manifest)
            guard try DiskFormat.version(original) == 1 else { return nil }
            let recording = try JSONDecoder().decode(Recording.self, from: original)
            for chunk in recording.chunks where chunk.isComplete {
                guard chunk.fileName == URL(fileURLWithPath: chunk.fileName).lastPathComponent else { throw MeetingError.message("迁移音频路径无效。") }
                let audio = manifest.deletingLastPathComponent().appendingPathComponent(chunk.fileName)
                let values = try audio.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
                guard values.isReadable == true, (values.fileSize ?? 0) > 0 else { throw MeetingError.message("音频离线或不可读，未开始迁移。") }
            }
            var inputs = [(manifest, original)]
            if let transcript, FileManager.default.fileExists(atPath: transcript.path) {
                let bytes = try Data(contentsOf: transcript)
                _ = try DiskFormat.version(bytes)
                let document = try JSONDecoder().decode(TranscriptDocument.self, from: bytes)
                guard document.recordingID == recording.id else { throw MeetingError.message("迁移时发现会议与转写 ID 不匹配。") }
                inputs.append((transcript, bytes))
            }
            let id = UUID(), folder = backupRoot.appendingPathComponent(id.uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var items: [Item] = []
            for (index, input) in inputs.enumerated() {
                let (url, bytes) = input
                try validateTarget(url)
                var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                object["schemaVersion"] = 2
                let replacement = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                let backup = "\(index).original", prepared = "\(index).v2"
                try bytes.write(to: folder.appendingPathComponent(backup), options: .withoutOverwriting)
                try replacement.write(to: folder.appendingPathComponent(prepared), options: .withoutOverwriting)
                guard try Data(contentsOf: folder.appendingPathComponent(backup)) == bytes else { throw MeetingError.message("迁移备份校验失败，未修改原文件。") }
                items.append(Item(path: url.path, backup: backup, prepared: prepared, originalHash: Self.hash(bytes), replacementHash: Self.hash(replacement), size: bytes.count))
            }
            let journal = Journal(id: id, fromVersion: 1, toVersion: 2, applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development", state: "prepared", items: items)
            try DiskFormat.encode(journal).write(to: folder.appendingPathComponent("journal.json"), options: .atomic)
            try commit(journal, folder: folder)
            return folder
        }
    }
    public static func assertReadable(base: URL) throws {
        let root = base.appendingPathComponent("Backups")
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            if ["prepared", "restoring"].contains(journal.state) { throw MeetingReadError("MIGRATION_BUSY", "数据迁移尚未完成，请先在应用中恢复后重试。", exitCode: 6, retryable: true) }
        }
    }
    public func recover() throws { try withLock { try recoverUnlocked() } }
    private func recoverUnlocked() throws {
        guard FileManager.default.fileExists(atPath: backupRoot.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil) where UUID(uuidString: folder.lastPathComponent) != nil {
            let url = folder.appendingPathComponent("journal.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: url))
            if journal.state == "prepared" { try commit(journal, folder: folder) }
            if journal.state == "restoring" { try finishRestore(journal, folder: folder) }
        }
    }
    private func commit(_ original: Journal, folder: URL) throws {
        for item in original.items {
            let url = URL(fileURLWithPath: item.path)
            try validateTarget(url)
            guard item.backup == URL(fileURLWithPath: item.backup).lastPathComponent,
                  item.prepared == URL(fileURLWithPath: item.prepared).lastPathComponent,
                  Self.hash(try Data(contentsOf: folder.appendingPathComponent(item.backup))) == item.originalHash,
                  Self.hash(try Data(contentsOf: folder.appendingPathComponent(item.prepared))) == item.replacementHash else { throw MeetingError.message("备份校验失败，请保留迁移目录：\(folder.path)") }
            guard FileManager.default.isWritableFile(atPath: url.path), FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path) else { throw MeetingError.message("迁移目标没有写入权限，未提交。") }
            let hash = Self.hash(try Data(contentsOf: url))
            guard hash == item.originalHash || hash == item.replacementHash else { throw MeetingError.message("迁移文件已修改，已停止以保护新数据：\(url.path)") }
        }
        for (index, item) in original.items.enumerated() {
            let url = URL(fileURLWithPath: item.path)
            if Self.hash(try Data(contentsOf: url)) == item.replacementHash { continue }
            try beforeReplace(index)
            try Data(contentsOf: folder.appendingPathComponent(item.prepared)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        var journal = original; journal.state = "completed"
        try DiskFormat.encode(journal).write(to: folder.appendingPathComponent("journal.json"), options: .atomic)
    }
    public func restore(folder: URL) throws {
        try withLock {
            guard folder.deletingLastPathComponent().standardizedFileURL == backupRoot.standardizedFileURL, folder.standardizedFileURL == folder.resolvingSymlinksInPath().standardizedFileURL else { throw MeetingError.message("请选择本应用的备份目录。") }
            var journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: folder.appendingPathComponent("journal.json")))
            for item in journal.items {
                try validateTarget(URL(fileURLWithPath: item.path))
                guard Self.hash(try Data(contentsOf: URL(fileURLWithPath: item.path))) == item.replacementHash else { throw MeetingError.message("恢复冲突：备份之后的数据已修改。请先复制当前资料库，不会覆盖新数据。") }
                guard Self.hash(try Data(contentsOf: folder.appendingPathComponent(item.backup))) == item.originalHash else { throw MeetingError.message("备份损坏。") }
            }
            for (index, item) in journal.items.enumerated() {
                let destination = folder.appendingPathComponent("\(index).before-restore")
                if !FileManager.default.fileExists(atPath: destination.path) { try Data(contentsOf: URL(fileURLWithPath: item.path)).write(to: destination, options: .withoutOverwriting) }
            }
            journal.state = "restoring"
            try DiskFormat.encode(journal).write(to: folder.appendingPathComponent("journal.json"), options: .atomic)
            try finishRestore(journal, folder: folder)
        }
    }
    private func finishRestore(_ original: Journal, folder: URL) throws {
        for item in original.items {
            try validateTarget(URL(fileURLWithPath: item.path))
            let hash = Self.hash(try Data(contentsOf: URL(fileURLWithPath: item.path)))
            guard hash == item.originalHash || hash == item.replacementHash,
                  Self.hash(try Data(contentsOf: folder.appendingPathComponent(item.backup))) == item.originalHash else { throw MeetingError.message("恢复存在冲突或备份损坏，请保留日志。") }
        }
        for (index, item) in original.items.enumerated() {
            let url = URL(fileURLWithPath: item.path)
            if Self.hash(try Data(contentsOf: url)) == item.originalHash { continue }
            try beforeReplace(index)
            try Data(contentsOf: folder.appendingPathComponent(item.backup)).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        var journal = original; journal.state = "restored"
        try DiskFormat.encode(journal).write(to: folder.appendingPathComponent("journal.json"), options: .atomic)
    }
}

/// Lifetime lease prevents a second app instance from starting capture or writers.
public final class LibraryWriterLease {
    private let descriptor: Int32
    public init(base: URL) throws {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        descriptor = open(base.appendingPathComponent(".application-writer.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw MeetingReadError("FILE_ACCESS_FAILED", "无法锁定资料库。", exitCode: 5) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw MeetingReadError("MIGRATION_BUSY", "另一应用实例正在使用资料库。请关闭另一实例后重试。", exitCode: 6, retryable: true)
        }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

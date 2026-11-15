import Foundation

public enum StorageDirectoryKind: Sendable { case audio, transcript }

public struct StorageSettings: Codable, Equatable, Sendable {
    public var audioDirectory: URL
    public var transcriptDirectory: URL
    public var audioHistoryDirectories: [URL]

    public static func defaults(base: URL) -> StorageSettings {
        let audio = base.appendingPathComponent("Recordings", isDirectory: true)
        return StorageSettings(audioDirectory: audio,
                               transcriptDirectory: base.appendingPathComponent("Transcripts", isDirectory: true),
                               audioHistoryDirectories: [audio])
    }
    public func changing(_ kind: StorageDirectoryKind, to directory: URL) -> StorageSettings {
        var result = self
        let normalized = URL(fileURLWithPath: directory.standardizedFileURL.path, isDirectory: true)
        switch kind {
        case .audio:
            result.audioDirectory = normalized
            for root in [audioDirectory, normalized] where !result.audioHistoryDirectories.contains(root) {
                result.audioHistoryDirectories.append(root)
            }
        case .transcript: result.transcriptDirectory = normalized
        }
        return result
    }
}

public struct StorageSettingsStore: Sendable {
    public let base: URL
    public var settingsURL: URL { base.appendingPathComponent("settings.json") }
    public init(base: URL) throws {
        self.base = base
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }
    public static func applicationStore() throws -> StorageSettingsStore {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try StorageSettingsStore(base: support.appendingPathComponent("Meeting Intelligence", isDirectory: true))
    }
    public func load() throws -> StorageSettings {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return .defaults(base: base) }
        let settings = try JSONDecoder().decode(StorageSettings.self, from: Data(contentsOf: settingsURL))
        guard settings.audioDirectory.isFileURL, settings.transcriptDirectory.isFileURL,
              settings.audioHistoryDirectories.allSatisfy(\.isFileURL) else {
            throw MeetingError.message("保存目录配置无效，请检查 settings.json。")
        }
        return settings
    }
    public func save(_ settings: StorageSettings, validating directory: URL) throws {
        guard directory.isFileURL else { throw MeetingError.message("请选择本机文件夹。") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Confirm actual write access before replacing the working configuration.
        let probe = directory.appendingPathComponent(".meeting-intelligence-write-test-\(UUID())")
        try Data("Meeting Intelligence".utf8).write(to: probe, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: probe) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
}

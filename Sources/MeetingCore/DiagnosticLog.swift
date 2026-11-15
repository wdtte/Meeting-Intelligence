import Darwin
import Foundation
import OSLog

/// Local JSON Lines diagnostics. Only explicit metadata fields are accepted;
/// payloads, credentials, URLs and meeting text have no logging field.
public final class DiagnosticLog: @unchecked Sendable {
    public static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Meeting Intelligence", isDirectory: true)
    public static let shared = DiagnosticLog(directory: directory,
        enabled: ProcessInfo.processInfo.processName == "MeetingIntelligence")
    private let directory: URL
    private let queue = DispatchQueue(label: "MeetingIntelligence.diagnostics", qos: .utility)
    private let session = UUID().uuidString
    private let maxBytes: Int
    private let enabled: Bool
    private let systemLog = Logger(subsystem: "local.meeting-intelligence.app", category: "diagnostics")
    private static let fields: Set<String> = ["recording_id", "chunk_id", "task_id", "request_id", "stage", "status", "code",
        "http_status", "error_domain", "error_code", "error_type", "field", "source", "region", "model", "attempt",
        "version", "build", "commit", "build_time", "duration", "sample_rate", "channels", "segments", "no_speech"]

    init(directory: URL, maxBytes: Int = 2 * 1024 * 1024, enabled: Bool = true) {
        self.directory = directory; self.maxBytes = maxBytes; self.enabled = enabled
    }
    public func record(_ event: String, fields: [String: String] = [:]) {
        guard enabled else { return }
        var clean = fields.filter { Self.fields.contains($0.key) }.mapValues(Self.safeToken)
        clean["event"] = Self.safeToken(event)
        clean["session"] = session
        clean["pid"] = String(ProcessInfo.processInfo.processIdentifier)
        let entry = clean
        queue.async { [self] in
            do {
                var entry = entry
                entry["time"] = ISO8601DateFormatter().string(from: Date())
                var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                data.append(0x0a)
                try append(data)
            } catch {
                systemLog.error("Diagnostic file write failed (code: \((error as NSError).code))")
            }
        }
    }
    public func failure(_ event: String, error: Error, fields: [String: String] = [:]) {
        var details = fields
        let nsError = error as NSError
        details["error_domain"] = nsError.domain; details["error_code"] = String(nsError.code)
        details["error_type"] = String(describing: type(of: error))
        if case DecodingError.keyNotFound(let key, _) = error { details["field"] = key.stringValue }
        record(event, fields: details)
    }
    public func flush() { queue.sync {} }
    private static func safeToken(_ value: String) -> String {
        guard value.count <= 256, !value.hasPrefix("sk-"), !value.hasPrefix("glpat-"),
              value.range(of: "^[a-zA-Z0-9_.:+-]+$", options: .regularExpression) != nil else { return "redacted" }
        return value
    }
    private func append(_ data: Data) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let lock = Darwin.open(directory.appendingPathComponent(".writer.lock").path, O_CREAT | O_RDWR, 0o600)
        guard lock >= 0 else { throw POSIXError(.EACCES) }
        defer { Darwin.close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(lock, LOCK_UN) }
        let file = directory.appendingPathComponent("app.jsonl")
        let bytes = (try? manager.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
        if bytes > 0, bytes + data.count > maxBytes {
            let oldest = directory.appendingPathComponent("app.3.jsonl")
            if manager.fileExists(atPath: oldest.path) { try manager.removeItem(at: oldest) }
            for index in stride(from: 2, through: 0, by: -1) {
                let source = index == 0 ? file : directory.appendingPathComponent("app.\(index).jsonl")
                if manager.fileExists(atPath: source.path) {
                    try manager.moveItem(at: source, to: directory.appendingPathComponent("app.\(index + 1).jsonl"))
                }
            }
        }
        if !manager.fileExists(atPath: file.path) {
            guard manager.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw POSIXError(.EACCES)
            }
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
    }
}

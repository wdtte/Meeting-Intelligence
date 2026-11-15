import Foundation
import Testing
@testable import MeetingCore

@Test func diagnosticsRedactPayloadsAndSensitiveValues() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = DiagnosticLog(directory: root)
    log.record("cloud.test", fields: ["body": "private transcript", "api_key": "private-key",
        "code": "sk-secret", "task_id": "https://signed.example/private", "request_id": "request-123"])
    log.failure("cloud.failed", error: NSError(domain: "Fixture", code: 42,
        userInfo: [NSLocalizedDescriptionKey: "private transcript and credential"]))
    log.flush()
    let raw = try String(contentsOf: root.appendingPathComponent("app.jsonl"), encoding: .utf8)
    #expect(!raw.contains("private")); #expect(!raw.contains("secret"))
    let lines = try raw.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
    #expect(lines[0]["code"] == "redacted")
    #expect(lines[0]["task_id"] == "redacted")
    #expect(lines[0]["request_id"] == "request-123")
    #expect(lines[1]["error_code"] == "42")
    #expect(lines[1]["error_domain"] == "Fixture")
    #expect(lines[0]["session"] == lines[1]["session"])
    let mode = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("app.jsonl").path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
}

@Test func diagnosticConcurrentWritersPreserveEveryEntryAndRotate() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let first = DiagnosticLog(directory: root, maxBytes: 1_000_000)
    let second = DiagnosticLog(directory: root, maxBytes: 1_000_000)
    DispatchQueue.concurrentPerform(iterations: 100) { index in
        (index.isMultiple(of: 2) ? first : second).record("test.entry", fields: ["attempt": String(index)])
    }
    first.flush(); second.flush()
    let raw = try String(contentsOf: root.appendingPathComponent("app.jsonl"), encoding: .utf8)
    let entries = try raw.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
    #expect(Set(entries.compactMap { $0["attempt"] }).count == 100)
    let rotating = DiagnosticLog(directory: root, maxBytes: 700)
    for index in 0..<40 { rotating.record("test.rotation", fields: ["attempt": String(index)]) }
    rotating.flush()
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
    #expect(files.count == 4)
    for file in files {
        let data = try Data(contentsOf: file)
        #expect(data.count <= 700)
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
        }
    }
    #expect(try String(contentsOf: root.appendingPathComponent("app.jsonl"), encoding: .utf8).contains("\"attempt\":\"39\""))
}

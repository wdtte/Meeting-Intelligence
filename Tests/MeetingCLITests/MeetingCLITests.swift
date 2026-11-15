import Foundation
import Testing
@testable import MeetingCLI
@testable import MeetingCore

private struct Fixture {
    let root: URL
    let base: URL
    let audio: URL
    let transcripts: URL
    var recording: Recording
    var document: TranscriptDocument
    var manifest: URL { audio.appendingPathComponent(recording.id.uuidString).appendingPathComponent("recording.json") }
    var transcript: URL { transcripts.appendingPathComponent(recording.id.uuidString + ".json") }
    init(count: Int = 6) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingCLI-\(UUID())")
        base = root.appendingPathComponent("Data")
        audio = root.appendingPathComponent("ExternalAudio")
        transcripts = root.appendingPathComponent("ExternalTranscripts")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)
        recording = Recording(title: "产品评审 🧑🏽‍💻", applicationName: "测试会议", bundleIdentifier: "test.meeting")
        recording.startedAt = ISO8601DateFormatter().date(from: "2026-11-14T08:00:00Z")!
        recording.endedAt = recording.startedAt.addingTimeInterval(120)
        recording.status = .completed
        let chunk = AudioChunk(fileName: "never-read.wav", offset: 0, duration: Double(max(count, 1) * 2), sampleRate: 16000, channels: 1, isComplete: true)
        recording.chunks = [chunk]
        recording.transcriptPath = transcripts.appendingPathComponent(recording.id.uuidString + ".json").path
        document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
        document.status = "completed"; document.processedChunks = [chunk.id]
        document.segments = (0..<count).map {
            var segment = TranscriptSegment(chunkID: chunk.id, source: $0.isMultiple(of: 2) ? .application : .microphone,
                                            start: Double($0 * 2), end: Double($0 * 2 + 2), text: "第\($0)段：发布日期 Café 👨‍👩‍👧‍👦")
            if $0.isMultiple(of: 2) { segment.engine = "fixture engine" }
            return segment
        }
        try save()
        try configure()
    }
    func save() throws {
        try FileManager.default.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(recording).write(to: manifest, options: .atomic)
        try document.save(to: transcript)
    }
    func configure(history: [URL] = []) throws {
        let settings = StorageSettings(audioDirectory: audio, transcriptDirectory: transcripts, audioHistoryDirectories: [audio] + history)
        try JSONEncoder().encode(settings).write(to: base.appendingPathComponent("settings.json"), options: .atomic)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func run(_ args: [String], expected: Int32 = 0) throws -> [String: Any] {
        let result = MeetingCLI.run(["--data-dir", base.path] + args, environment: [:])
        #expect(result.exitCode == expected, "\(String(decoding: result.stdout, as: UTF8.self))")
        #expect(result.stderr.isEmpty)
        return try #require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any])
    }
}
private func payload(_ response: [String: Any]) throws -> [String: Any] { try #require(response["data"] as? [String: Any]) }
private func errorCode(_ response: [String: Any]) throws -> String { try #require((response["error"] as? [String: Any])?["code"] as? String) }

@Test func discoveryUsesSettingsHistoryRealPathsAndSavedExternalTranscripts() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let history = fixture.root.appendingPathComponent("History")
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    try FileManager.default.moveItem(at: fixture.manifest.deletingLastPathComponent(), to: history.appendingPathComponent(fixture.recording.id.uuidString))
    let alias = fixture.root.appendingPathComponent("HistoryAlias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: history)
    try fixture.configure(history: [history, alias])
    let repository = try MeetingReadRepository(base: fixture.base)
    #expect(repository.audioRoots.count == 2)
    let data = try payload(fixture.run(["list", "--has-transcript", "--since", "2026-11-14", "--until", "2026-11-15", "--timezone", "Asia/Shanghai"]))
    #expect((data["meetings"] as? [[String: Any]])?.count == 1)
    let snapshot = try repository.snapshot(id: fixture.recording.id)
    #expect(snapshot.transcriptURL == fixture.transcript)
    #expect(snapshot.contentState == "complete")
    #expect(snapshot.processedChunkCount == 1)
}

@Test func noSettingsUsesDefaultsWithoutCreatingAnythingAndBadSettingsNeverFallback() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let empty = fixture.root.appendingPathComponent("Absent")
    let result = MeetingCLI.run(["list", "--data-dir", empty.path], environment: [:])
    #expect(result.exitCode == 3)
    #expect(!FileManager.default.fileExists(atPath: empty.path))
    try Data("bad json".utf8).write(to: fixture.base.appendingPathComponent("settings.json"))
    #expect(try errorCode(fixture.run(["list"], expected: 4)) == "INVALID_SETTINGS")
    try FileManager.default.removeItem(at: fixture.base.appendingPathComponent("settings.json"))
    let defaultAudio = fixture.base.appendingPathComponent("Recordings")
    try FileManager.default.createDirectory(at: defaultAudio, withIntermediateDirectories: true)
    #expect(try (payload(fixture.run(["list"]))["meetings"] as? [[String: Any]])?.isEmpty == true)
}

@Test func missingSavedTranscriptNeverFallsBackAndShowDistinguishesAbsence() throws {
    var fixture = try Fixture(); defer { fixture.clean() }
    fixture.recording.transcriptPath = fixture.root.appendingPathComponent("missing.json").path
    try fixture.save()
    let shown = try payload(fixture.run(["show", fixture.recording.id.uuidString]))
    #expect(shown["content_state"] as? String == "unavailable")
    #expect(shown["has_transcript"] as? Bool == false)
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString], expected: 3)) == "TRANSCRIPT_NOT_FOUND")
    fixture.recording.transcriptPath = nil; try fixture.save()
    #expect(try (payload(fixture.run(["transcript", fixture.recording.id.uuidString]))["segments"] as? [[String: Any]])?.count == 6)
}

@Test func standaloneTranscriptHasExplicitNullMetadataAndNoRepositoryAccess() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let result = MeetingCLI.run(["--data-dir", "/nonexistent", "transcript", "--file", fixture.transcript.path], environment: [:])
    #expect(result.exitCode == 0)
    let data = try payload(#require(JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]))
    #expect(data["metadata_available"] as? Bool == false)
    #expect(data["title"] is NSNull)
    #expect(data["started_at"] is NSNull)
    let segments = try #require(data["segments"] as? [[String: Any]])
    #expect(segments[1]["engine"] is NSNull)
    #expect(segments.allSatisfy { $0["speaker"] == nil })
}

@Test func longTranscriptPaginatesByBothBudgetsWithoutDroppingOrTruncatingUnicode() throws {
    let fixture = try Fixture(count: 257); defer { fixture.clean() }
    var cursor: String?, ids: [String] = [], iterations = 0
    repeat {
        var args = ["transcript", fixture.recording.id.uuidString, "--limit", "17", "--max-chars", "100"]
        if let cursor { args += ["--cursor", cursor] }
        let response = try fixture.run(args)
        let segments = try #require(payload(response)["segments"] as? [[String: Any]])
        #expect(!segments.isEmpty && segments.count <= 17)
        #expect(segments.reduce(0) { $0 + MeetingQuery.characterCount($1["text"] as! String) } <= 100)
        ids += segments.map { $0["segment_id"] as! String }
        let page = try #require(response["page"] as? [String: Any])
        cursor = page["next_cursor"] as? String
        #expect(page["has_more"] as? Bool == (cursor != nil))
        iterations += 1
        #expect(iterations < 258)
    } while cursor != nil && iterations < 258
    #expect(ids == fixture.document.segments.sorted(by: MeetingQuery.segmentOrder).map { $0.id.uuidString })
    #expect(Set(ids).count == 257)
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString, "--max-chars", "1"], expected: 2)) == "OUTPUT_LIMIT_TOO_SMALL")
}

@Test func cursorBindsQueryAndRevisionIncludingMetadataAndCrossMeetingSet() throws {
    var fixture = try Fixture(); defer { fixture.clean() }
    let first = try fixture.run(["transcript", fixture.recording.id.uuidString, "--limit", "2"])
    let cursor = try #require((first["page"] as? [String: Any])?["next_cursor"] as? String)
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString, "--limit", "3", "--cursor", cursor], expected: 2)) == "INVALID_CURSOR")
    fixture.recording.title = "元数据也改变 revision"; try fixture.save()
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString, "--limit", "2", "--cursor", cursor], expected: 6)) == "REVISION_CHANGED")
    let search = try fixture.run(["search", "发布日期", "--context", "0", "--limit", "1"])
    let searchCursor = try #require((search["page"] as? [String: Any])?["next_cursor"] as? String)
    fixture.document.segments[0].text = "新文字"; try fixture.save()
    #expect(try errorCode(fixture.run(["search", "发布日期", "--context", "0", "--limit", "1", "--cursor", searchCursor], expected: 6)) == "REVISION_CHANGED")
}

@Test func filtersUseHalfOpenDatesAndIntervalsAndPreserveWholeSentences() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let id = fixture.recording.id.uuidString
    let data = try payload(fixture.run(["transcript", id, "--from", "1", "--to", "4", "--source", "application"]))
    let segments = try #require(data["segments"] as? [[String: Any]])
    #expect(segments.count == 1)
    #expect(segments[0]["start"] as? Double == 0)
    let noMatch = try payload(fixture.run(["list", "--until", "2026-11-14T08:00:00Z"]))
    #expect((noMatch["meetings"] as? [[String: Any]])?.isEmpty == true)
    let yesMatch = try payload(fixture.run(["list", "--since", "2026-11-14T08:00:00Z", "--title-contains", "产品", "--app", "test.meeting"]))
    #expect((yesMatch["meetings"] as? [[String: Any]])?.count == 1)
}

@Test func searchNormalizesAccentsAndCaseAndMergesOnlyOverlappingContexts() throws {
    var fixture = try Fixture(); defer { fixture.clean() }
    fixture.document.segments[2].text = "没有匹配"; fixture.document.segments[3].text = "没有匹配"
    try fixture.save()
    let response = try payload(fixture.run(["search", "CAFE\u{301}", "--context", "1"]))
    let results = try #require(response["results"] as? [[String: Any]])
    #expect(results.count == 2)
    #expect((results[0]["match_segment_ids"] as? [String])?.count == 2)
    #expect((results[0]["segments"] as? [[String: Any]])?.count == 3)
    let merged = try payload(fixture.run(["search", "CAFE\u{301}", "--context", "2"]))
    #expect((merged["results"] as? [[String: Any]])?.count == 1)
    #expect(try (payload(fixture.run(["search", "不存在", "--context", "0"]))["results"] as? [[String: Any]])?.isEmpty == true)
    #expect(try (payload(fixture.run(["search", "发布日期", "--context", "0"]))["results"] as? [[String: Any]])?.count == 4)
}

@Test func cloudCompletenessAndSilenceUseChunksRatherThanTextOrAudioTrackSum() throws {
    var fixture = try Fixture(count: 0); defer { fixture.clean() }
    var secondChunk = fixture.recording.chunks[0]; secondChunk.id = UUID(); secondChunk.source = .microphone
    fixture.recording.chunks.append(secondChunk)
    fixture.document.processedChunks.insert(secondChunk.id)
    #expect(fixture.recording.duration == secondChunk.duration)
    #expect(fixture.recording.audioDuration == secondChunk.duration * 2)
    try fixture.save()
    let id = fixture.recording.id.uuidString
    #expect(try payload(fixture.run(["transcript", id, "--require-complete"]))["content_state"] as? String == "complete")
    let config = CloudTranscriptionConfiguration()
    fixture.recording.cloudTranscription = config
    fixture.document.cloud = CloudTranscriptionProgress(configuration: config)
    fixture.document.cloud?.status = "completed"
    try fixture.save()
    #expect(try errorCode(fixture.run(["transcript", id, "--require-complete"], expected: 7)) == "TRANSCRIPT_INCOMPLETE")
    for chunk in fixture.recording.chunks { var job = CloudChunkJob(); job.completed = true; fixture.document.cloud?.jobs[chunk.id.uuidString] = job }
    try fixture.save()
    #expect(try payload(fixture.run(["transcript", id, "--require-complete"]))["content_state"] as? String == "complete")
    fixture.document.status = "future_state"; try fixture.save()
    #expect(try payload(fixture.run(["show", id]))["content_state"] as? String == "unknown")
}

@Test func corruptAndOfflineMeetingsProducePartialResultsButExplicitTargetsFail() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let brokenID = UUID()
    let broken = fixture.audio.appendingPathComponent(brokenID.uuidString)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("broken".utf8).write(to: broken.appendingPathComponent("recording.json"))
    try fixture.configure(history: [fixture.root.appendingPathComponent("Offline")])
    let response = try fixture.run(["list"])
    #expect(response["partial_results"] as? Bool == true)
    #expect((response["warnings"] as? [[String: Any]])?.count == 2)
    #expect(try errorCode(fixture.run(["show", brokenID.uuidString], expected: 4)) == "DATA_CORRUPT")
    try FileManager.default.removeItem(at: fixture.manifest.deletingLastPathComponent())
    #expect(try errorCode(fixture.run(["list"], expected: 4)) == "DATA_CORRUPT")
}

@Test func duplicateUUIDMergesIdenticalManifestsAndRejectsConflicts() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let history = fixture.root.appendingPathComponent("History")
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    let copy = history.appendingPathComponent(fixture.recording.id.uuidString)
    try FileManager.default.copyItem(at: fixture.manifest.deletingLastPathComponent(), to: copy)
    try fixture.configure(history: [history])
    #expect(try (payload(fixture.run(["list"]))["meetings"] as? [[String: Any]])?.count == 1)
    var other = fixture.recording; other.title = "different"
    try JSONEncoder().encode(other).write(to: copy.appendingPathComponent("recording.json"))
    #expect(try errorCode(fixture.run(["list"], expected: 4)) == "DUPLICATE_MEETING_ID")
}

@Test(arguments: ["schema", "identity", "timestamp", "corrupt"])
func transcriptValidationRejectsUnsupportedOrMismatchedData(kind: String) throws {
    var fixture = try Fixture(); defer { fixture.clean() }
    let code: String
    switch kind {
    case "schema": fixture.document.schemaVersion = 9; code = "UNSUPPORTED_SCHEMA"
    case "identity": fixture.document.recordingID = UUID(); code = "RECORDING_ID_MISMATCH"
    case "timestamp": fixture.document.segments[0].end = -1; code = "INVALID_TIMESTAMPS"
    default: code = "DATA_CORRUPT"
    }
    try fixture.save()
    if kind == "corrupt" { try Data("bad".utf8).write(to: fixture.transcript) }
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString], expected: 4)) == code)
}

@Test func exportIsFullAndNoClobberAndCannotOverwriteSource() throws {
    let fixture = try Fixture(count: 201); defer { fixture.clean() }
    let target = fixture.root.appendingPathComponent("export.json"), id = fixture.recording.id.uuidString
    _ = try fixture.run(["export", id, "--format", "json", "--output", target.path])
    let bytes = try Data(contentsOf: target)
    let export = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect((try payload(export)["segments"] as? [[String: Any]])?.count == 201)
    #expect(try errorCode(fixture.run(["export", id, "--output", target.path], expected: 5)) == "OUTPUT_EXISTS")
    #expect(try Data(contentsOf: target) == bytes)
    _ = try fixture.run(["export", id, "--format", "markdown", "--output", target.path, "--overwrite"])
    let markdown = try String(contentsOf: target, encoding: .utf8)
    #expect(markdown.contains("segment_id: \(fixture.document.segments[200].id.uuidString)"))
    #expect(markdown.contains("revision: sha256:"))
    #expect(try errorCode(fixture.run(["export", id, "--output", fixture.transcript.path, "--overwrite"], expected: 5)) == "SOURCE_OVERWRITE_FORBIDDEN")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
}

@Test func argumentErrorsAreStructuredBeforeAnyDataAccess() throws {
    let invalid: [[String]] = [
        ["list", "--limit", "0"], ["transcript", "bad-id"], ["list", "--timezone", "Moon/Sea"],
        ["list", "--since", "2026-02-30"], ["list", "--since", "2026-11-15T12:00:00"],
        ["list", "--since", "2026-02-30T00:00:00Z"],
        ["list", "--since", "2026-11-15", "--until", "2026-11-14"], ["transcript", "--file", "x", "--from", "nan"],
        ["transcript", "--file", "x", "--to", "0"], ["search", ""], ["search", "q", "--context", "-1"],
        ["list", "--unknown"], ["list", "--pretty=true"], ["list", "--limit", "2", "--limit", "3"],
        ["show", UUID().uuidString, "--source", "application"], ["export", UUID().uuidString], ["schema", "unknown"]
    ]
    for args in invalid {
        let result = MeetingCLI.run(args, environment: ["MEETING_DATA_DIR": "/nonexistent"])
        #expect(result.exitCode == 2, "\(args): \(String(decoding: result.stdout, as: UTF8.self))")
        #expect(try JSONSerialization.jsonObject(with: result.stdout) is [String: Any])
    }
}

@Test func environmentPrecedenceHelpSchemaAndDoctorNeedNoModelOrGUI() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let env = MeetingCLI.run(["list"], environment: ["MEETING_DATA_DIR": fixture.base.path])
    #expect(env.exitCode == 0)
    let precedence = MeetingCLI.run(["list", "--data-dir", fixture.base.path], environment: ["MEETING_DATA_DIR": "/nonexistent"])
    #expect(precedence.exitCode == 0)
    #expect(MeetingCLI.run(["--help"], environment: [:]).exitCode == 0)
    let schema = MeetingCLI.run(["schema", "transcript"], environment: [:])
    #expect(schema.exitCode == 0)
    #expect(String(decoding: schema.stdout, as: UTF8.self).contains("matching_segment_count"))
    let doctor = try fixture.run(["doctor"])
    #expect(try payload(doctor)["healthy"] as? Bool == true)
    #expect(!String(decoding: try AgentTranscriptExport.json(doctor), as: UTF8.self).contains("发布日期"))
}

private func tree(_ root: URL) throws -> [String: Data] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
    var result: [String: Data] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        result[url.path.replacingOccurrences(of: root.path, with: "")] = values.isRegularFile == true ? try Data(contentsOf: url) : Data()
    }
    return result
}

@Test func subprocessStdoutExitCodesAndAllReadCommandsLeaveSourceTreeUnchanged() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let before = try tree(fixture.root)
    // SwiftPM's two build systems place products in different directories. Search alongside the running test binary first.
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let candidates = [URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("meeting"),
                      repo.appendingPathComponent(".build/debug/meeting"), repo.appendingPathComponent(".build/out/Products/Debug/meeting")]
    let executable = try #require(candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) })
    let commands: [([String], Int32)] = [(["list"], 0), (["show", fixture.recording.id.uuidString], 0),
        (["transcript", fixture.recording.id.uuidString], 0), (["search", "发布日期"], 0), (["doctor"], 0),
        (["schema", "export"], 0), (["show", UUID().uuidString], 3), (["list", "--limit", "0"], 2)]
    for (args, status) in commands {
        let process = Process(), stdout = Pipe(), stderr = Pipe()
        process.executableURL = executable; process.arguments = ["--data-dir", fixture.base.path] + args
        process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        let bytes = stdout.fileHandleForReading.readDataToEndOfFile()
        let diagnostics = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == status)
        #expect(diagnostics.isEmpty)
        #expect(try JSONSerialization.jsonObject(with: bytes) is [String: Any])
    }
    #expect(try tree(fixture.root) == before)
}

@Test func collectionVerificationDetectsObservedManifestTranscriptAndMembershipChanges() throws {
    var fixture = try Fixture(); defer { fixture.clean() }
    let repository = try MeetingReadRepository(base: fixture.base)
    let catalog = try repository.catalog()
    let snapshot = try repository.snapshot(id: fixture.recording.id)
    fixture.document.segments[0].text = "云端替换后的文字"
    try fixture.save()
    do { try repository.verify(catalog, snapshots: [snapshot]); Issue.record("Expected DATA_CHANGING") }
    catch let error as MeetingReadError { #expect(error.code == "DATA_CHANGING") }
    let fresh = try repository.catalog()
    fixture.recording.title = "changed metadata"; try fixture.save()
    do { try repository.verify(fresh, snapshots: []); Issue.record("Expected DATA_CHANGING") }
    catch let error as MeetingReadError { #expect(error.code == "DATA_CHANGING") }
    let beforeRemoval = try repository.catalog()
    try FileManager.default.removeItem(at: fixture.manifest.deletingLastPathComponent())
    do { try repository.verify(beforeRemoval, snapshots: []); Issue.record("Expected DATA_CHANGING") }
    catch let error as MeetingReadError { #expect(error.code == "DATA_CHANGING") }
}

@Test func stableOrderingAndMalformedCursorsHaveExplicitContracts() throws {
    var fixture = try Fixture(count: 4); defer { fixture.clean() }
    for index in fixture.document.segments.indices {
        fixture.document.segments[index].start = 0; fixture.document.segments[index].end = 2
    }
    fixture.document.segments.reverse(); try fixture.save()
    let snapshot = try MeetingReadRepository(base: fixture.base).snapshot(id: fixture.recording.id)
    #expect(snapshot.segments.map(\.source.rawValue) == ["application", "application", "microphone", "microphone"])
    #expect(snapshot.segments[0].id.uuidString < snapshot.segments[1].id.uuidString)
    #expect(try errorCode(fixture.run(["transcript", fixture.recording.id.uuidString, "--cursor", "garbage"], expected: 2)) == "INVALID_CURSOR")
    #expect(MeetingFingerprint.digest([Data("ab".utf8), Data("c".utf8)]) != MeetingFingerprint.digest([Data("a".utf8), Data("bc".utf8)]))
}

@Test func oldSegmentWithoutEngineRemainsReadableAndUnknownRecordingVersionFails() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.transcript)) as? [String: Any])
    var segments = try #require(document["segments"] as? [[String: Any]])
    for index in segments.indices { segments[index].removeValue(forKey: "engine") }
    document["segments"] = segments
    try JSONSerialization.data(withJSONObject: document).write(to: fixture.transcript)
    let data = try payload(fixture.run(["transcript", fixture.recording.id.uuidString]))
    #expect((data["segments"] as? [[String: Any]])?.allSatisfy { $0["engine"] is NSNull } == true)
    var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.manifest)) as? [String: Any])
    manifest["schemaVersion"] = 100
    try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.manifest)
    #expect(try errorCode(fixture.run(["show", fixture.recording.id.uuidString], expected: 4)) == "UNSUPPORTED_SCHEMA")
}

// Validate the schema vocabulary emitted by this CLI. No refs, coercion, or undeclared fields.
private func matchesSchema(_ value: Any, _ schema: [String: Any]) -> Bool {
    if let alternatives = schema["oneOf"] as? [[String: Any]], alternatives.filter({ matchesSchema(value, $0) }).count != 1 { return false }
    if let excluded = schema["not"] as? [String: Any], matchesSchema(value, excluded) { return false }
    if let constant = schema["const"], !NSDictionary(dictionary: ["value": constant]).isEqual(to: ["value": value]) { return false }
    if let options = schema["enum"] as? [Any], !options.contains(where: { NSDictionary(dictionary: ["value": $0]).isEqual(to: ["value": value]) }) { return false }
    if let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map({ [$0] }) {
        let valid = types.contains { type in
            switch type {
            case "null": return value is NSNull
            case "object": return value is [String: Any]
            case "array": return value is [Any]
            case "string": return value is String
            case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            case "integer": return (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.rounded() == $0.doubleValue } ?? false
            case "number": return (value as? NSNumber).map { CFGetTypeID($0) != CFBooleanGetTypeID() } ?? false
            default: return false
            }
        }
        if !valid { return false }
    }
    if let dictionary = value as? [String: Any] {
        if let required = schema["required"] as? [String], !required.allSatisfy({ dictionary[$0] != nil }) { return false }
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        if schema["additionalProperties"] as? Bool == false, !Set(dictionary.keys).isSubset(of: Set(properties.keys)) { return false }
        for (key, property) in properties {
            if let item = dictionary[key], !matchesSchema(item, property) { return false }
        }
    }
    if let values = value as? [Any], let items = schema["items"] as? [String: Any], !values.allSatisfy({ matchesSchema($0, items) }) { return false }
    if let text = value as? String {
        if let pattern = schema["pattern"] as? String, text.range(of: pattern, options: .regularExpression) == nil { return false }
        if let format = schema["format"] as? String {
            if format == "uuid", UUID(uuidString: text) == nil { return false }
            if format == "date-time", (try? MeetingQuery.parseDate(text, timezone: TimeZone(secondsFromGMT: 0)!)) == nil { return false }
        }
    }
    return true
}

@Test func actualSuccessErrorAndExportResponsesConformToAdvertisedSchemas() throws {
    let fixture = try Fixture(); defer { fixture.clean() }
    let id = fixture.recording.id.uuidString, output = fixture.root.appendingPathComponent("snapshot.json")
    let examples: [(String, [String])] = [
        ("list", ["list"]), ("show", ["show", id]), ("transcript", ["transcript", id]),
        ("search", ["search", "发布日期"]), ("export", ["export", id, "--output", output.path]),
        ("doctor", ["doctor"]), ("schema", ["schema"])
    ]
    for (command, args) in examples {
        let schemaResponse = try fixture.run(["schema", command])
        let descriptor = try #require((payload(schemaResponse)["commands"] as? [[String: Any]])?.first)
        let schema = try #require(descriptor["response_schema"] as? [String: Any])
        #expect(matchesSchema(try fixture.run(args), schema), "\(command) response does not conform")
        let error = MeetingCLI.run([command, "--unknown"], environment: [:])
        #expect(matchesSchema(try JSONSerialization.jsonObject(with: error.stdout), schema))
        if command == "export" {
            let exportSchema = try #require(descriptor["json_export_schema"] as? [String: Any])
            #expect(matchesSchema(try JSONSerialization.jsonObject(with: Data(contentsOf: output)), exportSchema))
        }
    }
}

import Foundation
import MeetingCore

struct CLIExecution {
    let stdout: Data
    let stderr: String
    let exitCode: Int32
}

enum MeetingCLI {
    static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> CLIExecution {
        do {
            let args = try CLIArguments(arguments)
            if args.flags.contains("version") { return .init(stdout: Data("meeting 1.0.0\n".utf8), stderr: "", exitCode: 0) }
            if args.flags.contains("help") || args.command == nil {
                return .init(stdout: Data(CLIArguments.help(args.command).utf8), stderr: "", exitCode: 0)
            }
            let result: [String: Any]
            if args.command == "schema" {
                guard args.positionals.count <= 1 else { throw MeetingQuery.argumentError("schema 只接受一个可选命令名。") }
                result = try CLISchema.response(command: args.positionals.first)
            } else {
                // Each retry starts with fresh settings and a fresh catalog. No hidden session or cache.
                var response: [String: Any]?
                for attempt in 0..<3 {
                    do { response = try execute(args, environment: environment); break }
                    catch let error as MeetingReadError where error.code == "DATA_CHANGING" && attempt < 2 { continue }
                }
                result = response!
            }
            let bytes = args.format == "text" && args.command != "export"
                ? Data((text(result) + "\n").utf8)
                : try AgentTranscriptExport.json(result, pretty: args.flags.contains("pretty")) + Data([10])
            return .init(stdout: bytes, stderr: "", exitCode: 0)
        } catch {
            let problem = (error as? MeetingReadError) ?? MeetingReadError("INTERNAL_ERROR", "命令执行失败。", exitCode: 1)
            let object: [String: Any] = ["schema_version": "1", "error": ["code": problem.code, "message": problem.message, "retryable": problem.retryable]]
            let bytes = (try? AgentTranscriptExport.json(object)) ?? Data("{\"schema_version\":\"1\",\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"Encoding failed\",\"retryable\":false}}".utf8)
            return .init(stdout: bytes + Data([10]), stderr: "", exitCode: problem.exitCode)
        }
    }

    private static func execute(_ args: CLIArguments, environment: [String: String]) throws -> [String: Any] {
        let command = args.command!
        // Validate parameters before touching disk; a typo is always an argument error.
        switch command {
        case "list", "doctor":
            guard args.positionals.isEmpty else { throw MeetingQuery.argumentError("\(command) 不接受位置参数。") }
        case "show", "export": _ = try args.targetID()
        case "search":
            guard args.positionals.count == 1, !args.positionals[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MeetingQuery.argumentError("search 需要一个非空查询字符串。")
            }
            if let meeting = args.values["meeting"] { _ = try args.uuid(meeting) }
            _ = try args.integer("context", default: 2, range: 0...100)
        case "transcript":
            if args.values["file"] != nil {
                guard args.positionals.isEmpty else { throw MeetingQuery.argumentError("--file 与会议 ID 互斥。") }
            } else { _ = try args.targetID() }
            let from = try args.seconds("from"), to = try args.seconds("to")
            if let to, to <= (from ?? 0) { throw MeetingQuery.argumentError("--to 必须大于 --from（默认 0）。") }
        default: break
        }
        if ["list", "search", "transcript"].contains(command) { _ = try args.limit }
        if ["search", "transcript"].contains(command) { _ = try args.maxChars }
        if ["list", "search"].contains(command) { _ = try args.filter() }
        if command == "export", args.values["output"] == nil { throw MeetingQuery.argumentError("export 需要 --output <path>。") }
        if command == "transcript", let file = args.values["file"] {
            let snapshot = try MeetingReadRepository.standalone(file: URL(fileURLWithPath: file))
            return try transcript(snapshot, args: args)
        }
        let path = args.values["data-dir"] ?? environment["MEETING_DATA_DIR"]
        let repository = try MeetingReadRepository(base: path.map { URL(fileURLWithPath: $0) } ?? MeetingReadRepository.defaultBase)
        switch command {
        case "list", "search": return try collection(repository, args: args)
        case "show":
            let snapshot = try repository.snapshot(id: args.targetID())
            return AgentTranscriptExport.envelope(data: AgentTranscriptExport.metadata(snapshot), warnings: snapshot.warnings)
        case "transcript": return try transcript(repository.snapshot(id: args.targetID()), args: args)
        case "export":
            let snapshot = try repository.snapshot(id: args.targetID())
            try snapshot.requireTranscript(complete: args.flags.contains("require-complete"))
            let output = URL(fileURLWithPath: args.values["output"]!).standardizedFileURL
            try protectSources(output, repository: repository)
            let exportedAt = Date()
            let bytes = args.format == "markdown"
                ? Data(AgentTranscriptExport.markdown(snapshot, exportedAt: exportedAt).utf8)
                : try AgentTranscriptExport.json(AgentTranscriptExport.snapshot(snapshot, exportedAt: exportedAt), pretty: true) + Data([10])
            try AgentTranscriptExport.write(bytes, to: output, overwrite: args.flags.contains("overwrite"))
            return AgentTranscriptExport.envelope(data: ["meeting_id": snapshot.meetingID.uuidString, "revision": snapshot.revision,
                                                        "output": output.path, "format": args.format, "bytes": bytes.count,
                                                        "exported_at": AgentTranscriptExport.timestamp(exportedAt)], warnings: snapshot.warnings)
        case "doctor": return try doctor(repository)
        default: throw MeetingQuery.argumentError("未知命令。")
        }
    }

    private static func pageInfo<Item>(_ page: MeetingPage<Item>) -> [String: Any] {
        ["next_cursor": AgentTranscriptExport.nullable(page.nextCursor), "has_more": page.hasMore]
    }
    private static func transcript(_ snapshot: MeetingReadSnapshot, args: CLIArguments) throws -> [String: Any] {
        try snapshot.requireTranscript(complete: args.flags.contains("require-complete"))
        let from = try args.seconds("from"), to = try args.seconds("to")
        let source = args.values["source"].flatMap(AudioSource.init(rawValue:))
        let segments = MeetingQuery.transcript(snapshot, from: from, to: to, source: source)
        let page = try MeetingQuery.page(items: segments, command: "transcript", query: args.queryFingerprint(), revision: snapshot.revision,
                                         cursor: args.values["cursor"], limit: args.limit, maxChars: args.maxChars,
                                         cost: { MeetingQuery.characterCount($0.text) })
        var data = AgentTranscriptExport.metadata(snapshot)
        data["segments"] = page.items.map(AgentTranscriptExport.segment)
        data["matching_segment_count"] = segments.count
        return AgentTranscriptExport.envelope(data: data, warnings: snapshot.warnings, page: pageInfo(page))
    }

    private static func collection(_ repository: MeetingReadRepository, args: CLIArguments) throws -> [String: Any] {
        let catalog = try repository.catalog()
        let (filter, timezone) = try args.filter()
        let target = try args.values["meeting"].map(args.uuid)
        if let target, let failure = catalog.failures[target] { throw failure }
        if let target, !catalog.entries.contains(where: { $0.recording.id == target }) {
            _ = try repository.snapshot(id: target) // supplies a precise missing/offline error
        }
        let entries = catalog.entries.filter { (target == nil || $0.recording.id == target) && filter.matches($0.recording) }
        var warnings = catalog.warnings, snapshots: [MeetingReadSnapshot] = [], firstFailure: MeetingReadError?
        var partial = !warnings.isEmpty
        for entry in entries {
            do {
                let snapshot = try repository.snapshot(entry: entry)
                if target != nil { try snapshot.requireTranscript() }
                snapshots.append(snapshot)
                warnings += snapshot.warnings
                if args.command == "search", snapshot.transcript == nil { partial = true }
            } catch let error as MeetingReadError {
                if target != nil || error.code == "DATA_CHANGING" { throw error }
                firstFailure = firstFailure ?? error; partial = true
                warnings.append(.init(error.code, error.message, meetingID: entry.recording.id, path: entry.manifestURL.path))
            }
        }
        if snapshots.isEmpty {
            if let firstFailure { throw firstFailure }
            if catalog.entries.isEmpty, let failure = catalog.failures.values.sorted(by: { $0.code < $1.code }).first { throw failure }
        }
        try repository.verify(catalog, snapshots: snapshots)
        let collectionRevision = MeetingFingerprint.digest(catalog.entries.map { Optional($0.manifestBytes) } + snapshots.map { Data($0.revision.utf8) } +
                                                           [try AgentTranscriptExport.json(warnings.map(AgentTranscriptExport.warning))])
        let query = try args.queryFingerprint(extra: ["timezone_resolved": timezone.identifier, "data_dir": repository.base.path])
        var data: [String: Any] = ["timezone": timezone.identifier, "since": AgentTranscriptExport.nullable(filter.since.map(AgentTranscriptExport.timestamp)),
                                   "until": AgentTranscriptExport.nullable(filter.until.map(AgentTranscriptExport.timestamp)), "revision": collectionRevision]
        if args.command == "list" {
            let rows = snapshots.filter { !filter.hasTranscript || $0.transcript?.segments.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true }
            let page = try MeetingQuery.page(items: rows, command: "list", query: query, revision: collectionRevision,
                                             cursor: args.values["cursor"], limit: args.limit, maxChars: nil, cost: { _ in 0 })
            data["meetings"] = page.items.map(AgentTranscriptExport.metadata); data["total_count"] = rows.count
            return AgentTranscriptExport.envelope(data: data, warnings: warnings, page: pageInfo(page), partial: partial)
        }
        let context = try args.integer("context", default: 2, range: 0...100)
        let results = snapshots.flatMap { MeetingQuery.search($0, query: args.positionals[0], context: context) }
        let page = try MeetingQuery.page(items: results, command: "search", query: query, revision: collectionRevision,
                                         cursor: args.values["cursor"], limit: args.limit, maxChars: args.maxChars,
                                         cost: { $0.segments.reduce(0) { $0 + MeetingQuery.characterCount($1.text) } })
        data["query"] = args.positionals[0]; data["total_count"] = results.count
        data["results"] = page.items.map { result -> [String: Any] in
            var row = AgentTranscriptExport.metadata(result.snapshot)
            row["segments"] = result.segments.map(AgentTranscriptExport.segment)
            row["match_segment_ids"] = result.matchIDs.map(\.uuidString)
            return row
        }
        return AgentTranscriptExport.envelope(data: data, warnings: warnings, page: pageInfo(page), partial: partial)
    }

    private static func protectSources(_ output: URL, repository: MeetingReadRepository) throws {
        let path = output.resolvingSymlinksInPath().path
        let catalog = try repository.catalog()
        let protectedFiles = catalog.entries.flatMap { [$0.manifestURL, repository.transcriptURL(for: $0.recording)] } +
            [repository.base.appendingPathComponent("settings.json")]
        let protectedDirectories = repository.audioRoots + [repository.settings.transcriptDirectory]
        guard !protectedFiles.contains(where: { $0.resolvingSymlinksInPath().path == path }),
              !protectedDirectories.contains(where: {
                  let root = $0.standardizedFileURL.resolvingSymlinksInPath().path
                  return path == root || path.hasPrefix(root + "/")
              }) else {
            throw MeetingReadError("SOURCE_OVERWRITE_FORBIDDEN", "导出目标不能位于原始音频/转写目录或覆盖源文件。", exitCode: 5)
        }
    }
    private static func doctor(_ repository: MeetingReadRepository) throws -> [String: Any] {
        let catalog = try repository.catalog()
        var warnings = catalog.warnings
        let roots = repository.audioRoots + [repository.settings.transcriptDirectory]
        let directories: [[String: Any]] = roots.map { url in
            let readable = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) != nil
            if !readable, !warnings.contains(where: { $0.path == url.path }) {
                warnings.append(.init("DIRECTORY_UNAVAILABLE", "目录不可读：\(url.path)", path: url.path))
            }
            return ["path": url.path, "readable": readable, "kind": repository.audioRoots.contains(url) ? "audio" : "transcript"]
        }
        return AgentTranscriptExport.envelope(data: ["data_dir": repository.base.path, "settings_present": repository.settingsPresent,
                                                    "directories": directories, "meeting_count": catalog.entries.count,
                                                    "healthy": warnings.isEmpty, "read_only": true], warnings: warnings, partial: !warnings.isEmpty)
    }
    private static func text(_ value: Any, depth: Int = 0) -> String {
        let indent = String(repeating: "  ", count: depth)
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { key in
                let item = dictionary[key]!
                if item is [String: Any] || item is [Any] { return "\(indent)\(key):\n" + text(item, depth: depth + 1) }
                return "\(indent)\(key): \(item is NSNull ? "null" : String(describing: item))"
            }.joined(separator: "\n")
        }
        if let array = value as? [Any] { return array.map { "\(indent)-\n" + text($0, depth: depth + 1) }.joined(separator: "\n") }
        return indent + String(describing: value)
    }
}

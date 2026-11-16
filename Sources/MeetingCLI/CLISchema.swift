import Foundation
import MeetingCore

/// Draft 2020-12 schemas describe the wire DTOs, independently of on-disk Codable models.
enum CLISchema {
    static func object(_ properties: [String: Any], required: [String]? = nil) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required ?? properties.keys.sorted(), "additionalProperties": false]
    }
    static func array(_ item: [String: Any]) -> [String: Any] { ["type": "array", "items": item] }
    static func string(nullable: Bool = false, format: String? = nil) -> [String: Any] {
        var result: [String: Any] = ["type": nullable ? ["string", "null"] : "string"]
        if let format { result["format"] = format }
        return result
    }
    static var boolean: [String: Any] { ["type": "boolean"] }
    static var integer: [String: Any] { ["type": "integer", "minimum": 0] }
    static var nullableInteger: [String: Any] { ["type": ["integer", "null"], "minimum": 0] }
    static var number: [String: Any] { ["type": "number", "minimum": 0] }
    static var nullableNumber: [String: Any] { ["type": ["number", "null"], "minimum": 0] }
    static var segment: [String: Any] {
        object(["segment_id": string(format: "uuid"), "chunk_id": string(format: "uuid"),
                "source": ["type": "string", "enum": ["application", "microphone"]], "start": number, "end": number,
                "text": string(), "engine": string(nullable: true)])
    }
    static var metadata: [String: Any] {
        ["meeting_id": string(format: "uuid"), "metadata_available": boolean, "title": string(nullable: true),
         "application_name": string(nullable: true), "bundle_identifier": string(nullable: true),
         "started_at": string(nullable: true, format: "date-time"), "ended_at": string(nullable: true, format: "date-time"),
         "duration": nullableNumber, "recording_status": string(nullable: true), "local_status": string(nullable: true),
         "cloud_status": string(), "content_state": ["type": "string", "enum": ["unavailable", "partial", "complete", "unknown"]],
         "revision": ["type": "string", "pattern": "^sha256:[0-9a-f]{64}$"], "locale": string(nullable: true),
         "segment_count": integer, "has_transcript": boolean, "closed_chunk_count": nullableInteger,
         "processed_chunk_count": nullableInteger, "local_completion_ratio": nullableNumber, "cloud_completed_chunk_count": nullableInteger, "summary_status": string(nullable: true)]
    }
    static var page: [String: Any] { object(["next_cursor": string(nullable: true), "has_more": boolean]) }
    static var warning: [String: Any] {
        object(["code": string(), "message": string(), "meeting_id": string(nullable: true, format: "uuid"), "path": string(nullable: true)])
    }
    static var error: [String: Any] {
        object(["schema_version": ["const": "1"], "error": object(["code": string(), "message": string(), "retryable": boolean])])
    }
    static func success(data: [String: Any], paged: Bool = false) -> [String: Any] {
        var properties: [String: Any] = ["schema_version": ["const": "1"], "data": data,
                                         "warnings": array(warning), "partial_results": boolean]
        if paged { properties["page"] = page }
        return object(properties)
    }
    static func output(_ command: String) -> [String: Any] {
        let collection: [String: Any] = ["timezone": string(), "since": string(nullable: true, format: "date-time"),
                                         "until": string(nullable: true, format: "date-time"), "revision": string(), "total_count": integer]
        var properties = metadata
        let data: [String: Any]
        switch command {
        case "list": data = object(collection.merging(["meetings": array(object(metadata))]) { _, rhs in rhs })
        case "show": data = object(properties)
        case "transcript":
            properties["segments"] = array(segment); properties["matching_segment_count"] = integer
            data = object(properties)
        case "search":
            properties["segments"] = array(segment); properties["match_segment_ids"] = array(string(format: "uuid"))
            data = object(collection.merging(["query": string(), "results": array(object(properties))]) { _, rhs in rhs })
        case "export":
            data = object(["meeting_id": string(format: "uuid"), "revision": string(), "output": string(),
                           "format": ["enum": ["json", "markdown"]], "bytes": integer, "exported_at": string(format: "date-time")])
        case "doctor":
            data = object(["data_dir": string(), "settings_present": boolean,
                           "directories": array(object(["path": string(), "readable": boolean, "kind": ["enum": ["audio", "transcript"]]])),
                           "meeting_count": integer, "healthy": boolean, "read_only": ["const": true]])
        case "schema": data = object(["commands": array(descriptor)], required: ["commands"])
        default: data = [:]
        }
        return ["$schema": "https://json-schema.org/draft/2020-12/schema", "oneOf": [success(data: data, paged: ["list", "transcript", "search"].contains(command)), error]]
    }
    static var descriptor: [String: Any] {
        object(["command": string(), "description": string(), "usage": string(), "parameters": ["type": "object"],
                "response_schema": ["type": "object"], "json_export_schema": ["type": "object"]],
               required: ["command", "description", "usage", "parameters", "response_schema"])
    }
    static func describe(_ command: CLICommand) -> [String: Any] {
        var properties: [String: Any] = [:], required: [String] = []
        for option in command.effectiveOptions {
            var schema: [String: Any] = ["type": option.type, "description": option.description]
            if let choices = option.choices { schema["enum"] = choices }
            if let value = option.defaultValue { schema["default"] = value }
            if ["limit", "max-chars"].contains(option.name) { schema["minimum"] = 1 }
            if option.name == "limit" { schema["maximum"] = 10000 }
            if option.name == "context" { schema["minimum"] = 0; schema["maximum"] = 100 }
            if ["from", "to"].contains(option.name) { schema["minimum"] = 0 }
            properties[option.name] = schema
        }
        if ["show", "transcript", "export"].contains(command.name) {
            properties["id"] = string(format: "uuid")
            if command.name != "transcript" { required.append("id") }
        }
        if command.name == "search" { properties["query"] = ["type": "string", "minLength": 1]; required.append("query") }
        if command.name == "schema" { properties["command"] = ["type": "string", "enum": CLICommand.all.map(\.name)] }
        if command.name == "export" { required.append("output") }
        var parameters = object(properties, required: required)
        if command.name == "transcript" {
            parameters["oneOf"] = [["required": ["id"], "not": ["required": ["file"]]], ["required": ["file"], "not": ["required": ["id"]]]]
        }
        var value: [String: Any] = ["command": command.name, "description": command.summary,
                                   "usage": "meeting \(command.name) \(command.positional ?? "")", "parameters": parameters,
                                   "response_schema": output(command.name)]
        if command.name == "export" {
            var snapshotProperties = metadata
            snapshotProperties["summary"] = ["oneOf": [["type": "null"], object([
                "text": string(nullable: true), "model": string(nullable: true), "provider": string(),
                "generated_at": string(nullable: true, format: "date-time")])]]
            snapshotProperties["segments"] = array(segment); snapshotProperties["exported_at"] = string(format: "date-time")
            value["json_export_schema"] = success(data: object(snapshotProperties))
        }
        return value
    }
    static func response(command: String?) throws -> [String: Any] {
        let commands: [CLICommand]
        if let command {
            guard let spec = CLICommand.find(command) else { throw MeetingQuery.argumentError("未知 schema 命令：\(command)") }
            commands = [spec]
        } else { commands = CLICommand.all }
        return AgentTranscriptExport.envelope(data: ["commands": commands.map(describe)])
    }
}

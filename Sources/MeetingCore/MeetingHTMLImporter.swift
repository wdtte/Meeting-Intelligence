import Foundation
@preconcurrency import libxml2

/// Reads the offline export as inert data. No browser, script, URL fetch or file reference is used.
public enum MeetingHTMLImporter {
    public static let maximumHTMLBytes = 512 * 1024 * 1024
    private static let maximumMarkupBytes = 8 * 1024 * 1024
    private static let audioMarker = "meeting-import-embedded-audio"

    public static func accepts(_ url: URL) -> Bool { ["html", "htm"].contains(url.pathExtension.lowercased()) }

    public static func inspect(_ url: URL) async throws -> AudioImportPreview {
        let worker = Task.detached(priority: .utility) {
            let content = try read(url)
            return try withAudio(content) { audio in
                let duration = try audio.map { try AudioImporter.inspect($0).duration } ?? content.lastEnd
                try content.validate(duration: audio == nil ? nil : duration)
                return AudioImportPreview(fileName: url.lastPathComponent, duration: duration, format: "html",
                    isHTML: true, hasAudio: audio != nil, segmentCount: content.segments.count,
                    hasSummary: content.summary != nil, title: content.title, isComplete: content.complete)
            }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public static func run(url: URL, store: RecordingStore, transcriptDirectory: URL,
                           progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws -> Recording {
        let worker = Task.detached(priority: .utility) {
            let content = try read(url)
            let temporary = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: temporary) }
            let audio = try extractAudio(content, to: temporary)
            let duration = try audio.map { try AudioImporter.inspect($0).duration } ?? content.lastEnd
            try content.validate(duration: audio == nil ? nil : duration)
            var recording = Recording(title: content.title, applicationName: "导入 HTML", bundleIdentifier: "")
            recording.origin = .imported
            recording.transcriptionPlan = .localThenCloud
            recording.automaticSummary = false
            recording.transcriptionLocale = content.locale
            recording.transcriptPath = transcriptDirectory.appendingPathComponent("\(recording.id).json").path
            recording.note = content.complete ? nil : "HTML 导出时转写尚未完成；仅导入文件中已有的内容。"
            let stage = store.root.appendingPathComponent(".import-\(recording.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: stage) }
            if let audio {
                try AudioImporter.validateCapacity(store: store, duration: duration)
                recording.chunks = try await AudioImporter.stageAudio(url: audio, duration: duration, stage: stage, progress: progress)
            }
            var document = content.document(recordingID: recording.id)
            document.processedChunks = Set(recording.chunks.map(\.id))
            recording.status = .completed
            recording.endedAt = Date()
            recording.importMetadata = AudioImportMetadata(originalFileName: url.lastPathComponent, importedAt: recording.startedAt,
                format: "html", duration: duration)
            try Task.checkCancellation()
            try AudioImporter.publish(recording: recording, document: document, stage: stage, store: store)
            await progress(1)
            return recording
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private struct Content: Sendable {
        var bytes: Data
        var audioRange: Range<Int>?
        var audioExtension: String?
        var title: String
        var locale: String
        var complete: Bool
        var segments: [TranscriptSegment]
        var speakers: [Speaker]
        var summary: String?
        var summaryModel: String?
        var lastEnd: Double { segments.map(\.end).max() ?? 0 }
        func validate(duration: Double?) throws {
            guard !segments.isEmpty || summary != nil || duration != nil else { throw invalid("没有可导入的音频、字幕或摘要。") }
            if let duration, lastEnd > duration + 0.1 { throw invalid("字幕时间戳超出内嵌音频范围。") }
        }
        func document(recordingID: UUID) -> TranscriptDocument {
            var document = TranscriptDocument(recordingID: recordingID, locale: locale)
            document.engine = "HTML 导入"
            document.status = complete ? "completed" : "interrupted"
            document.error = complete ? nil : "原 HTML 仅包含导出时已有的转写内容。"
            document.segments = segments
            document.speakers = speakers.isEmpty ? nil : speakers
            if let summary {
                var imported = TranscriptSummary(inputFingerprint: document.summaryRequest.fingerprint)
                imported.status = "completed"; imported.text = summary; imported.model = summaryModel
                document.summary = imported
            }
            return document
        }
    }

    private static func invalid(_ reason: String) -> MeetingError { .message("无法导入 HTML：\(reason)") }

    private static func read(_ url: URL) throws -> Content {
        try Task.checkCancellation()
        guard accepts(url), url.isFileURL else { throw invalid("请选择本应用导出的 HTML 文件。") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumHTMLBytes else { throw invalid("文件为空或超过 512 MiB 上限。") }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= maximumHTMLBytes else { throw invalid("文件超过 512 MiB 上限。") }
        var markup = Data(), cursor = bytes.startIndex, searchCursor = bytes.startIndex
        var audioRange: Range<Int>?, audioExtension: String?
        let prefix = Data("data:audio/".utf8)
        // Remove the large base64 attribute before HTML parsing. Its bytes are decoded in bounded blocks.
        while let marker = bytes.range(of: prefix, in: searchCursor..<bytes.endIndex) {
            try Task.checkCancellation()
            searchCursor = marker.upperBound
            // Literal transcript text can mention data:audio/; exported quotes are entity-escaped.
            guard marker.lowerBound > 0, [UInt8(34), 39].contains(bytes[marker.lowerBound - 1]) else { continue }
            guard audioRange == nil,
                  let end = bytes[marker.upperBound...].firstIndex(of: bytes[marker.lowerBound - 1]),
                  let comma = bytes[marker.upperBound..<min(end, marker.upperBound + 80)].firstIndex(of: 44),
                  let header = String(data: bytes[marker.lowerBound..<comma], encoding: .utf8) else {
                throw invalid("内嵌音频格式无效或包含多条音频。")
            }
            let formats = ["data:audio/mp4;base64": "m4a", "data:audio/x-m4a;base64": "m4a",
                           "data:audio/wav;base64": "wav", "data:audio/x-wav;base64": "wav",
                           "data:audio/mpeg;base64": "mp3", "data:audio/mp3;base64": "mp3"]
            guard let ext = formats[header.lowercased()] else { throw invalid("仅支持内嵌 M4A、WAV 或 MP3 音频。") }
            guard markup.count + marker.lowerBound - cursor <= maximumMarkupBytes else { throw invalid("文字内容超过 8 MiB 上限。") }
            markup.append(bytes[cursor..<marker.lowerBound]); markup.append(Data(audioMarker.utf8))
            audioRange = (comma + 1)..<end; audioExtension = ext; cursor = end
        }
        guard markup.count + bytes.endIndex - cursor <= maximumMarkupBytes else { throw invalid("文字内容超过 8 MiB 上限。") }
        markup.append(bytes[cursor...])
        guard let text = String(data: markup, encoding: .utf8) else { throw invalid("文件不是有效的 UTF-8。") }
        let declarations = try NSRegularExpression(pattern: #"<!ENTITY|<!DOCTYPE\s+(?!html\s*>)|<!\[CDATA\["#, options: [.caseInsensitive])
        guard declarations.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) == nil else {
            throw invalid("不支持外部实体或自定义文档声明。")
        }
        // libxml's HTML parser retains HTML5 element names and exact UTF-8 text/newlines.
        // Foundation's legacy HTML tidy drops audio/article/header and reflows paragraphs.
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue | HTML_PARSE_NODEFDTD.rawValue
        let html = markup.withUnsafeBytes { raw in
            htmlReadMemory(raw.bindMemory(to: CChar.self).baseAddress, Int32(raw.count), nil, "UTF-8", Int32(options))
        }
        guard let html else { throw invalid("页面结构损坏。") }
        defer { xmlFreeDoc(html) }
        guard let context = xmlXPathNewContext(html) else { throw invalid("无法读取页面结构。") }
        defer { xmlXPathFreeContext(context) }
        func nodes(_ path: String, in node: xmlNodePtr? = nil) throws -> [xmlNodePtr] {
            context.pointee.node = node ?? xmlDocGetRootElement(html)
            let result = path.utf8CString.withUnsafeBytes { raw in
                xmlXPathEvalExpression(raw.bindMemory(to: UInt8.self).baseAddress, context)
            }
            guard let result else { throw invalid("无法读取页面结构。") }
            defer { xmlXPathFreeObject(result) }
            guard let set = result.pointee.nodesetval, let table = set.pointee.nodeTab else { return [] }
            return (0..<Int(set.pointee.nodeNr)).compactMap { table[$0] }
        }
        func value(_ path: String, in node: xmlNodePtr? = nil) throws -> String? {
            guard let element = try nodes(path, in: node).first, let contents = xmlNodeGetContent(element) else { return nil }
            defer { xmlFree?(contents) }
            return String(cString: contents)
        }
        func classPath(_ name: String) -> String { "contains(concat(' ', normalize-space(@class), ' '), ' \(name) ')" }
        guard let header = try nodes("//header[\(classPath("meeting-header"))]").first,
              let title = try value(".//h1", in: header), !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              try nodes("//div[@id='segments']").count == 1 else { throw invalid("请选择 Meeting Intelligence 导出的会议页面。") }
        let version = try value("//meta[@name='meeting-intelligence-export-version']/@content")
        guard version == nil || version == "1" else { throw invalid("导出格式版本较新，请升级应用。") }
        let audioNodes = try nodes("//audio")
        guard audioNodes.count == (audioRange == nil ? 0 : 1),
              try audioNodes.isEmpty || value("./@src", in: audioNodes[0]) == audioMarker else {
            throw invalid("音频必须内嵌在 HTML 中；不读取网络或外部文件。")
        }
        let completeValue = try value("//meta[@name='meeting-intelligence-complete']/@content")
        guard completeValue == nil || ["true", "false"].contains(completeValue!) else { throw invalid("完成状态无效。") }
        let notice = try value(".//p[\(classPath("notice"))]", in: header) ?? ""
        let complete = completeValue.map { $0 == "true" } ?? notice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let locale = try value("//meta[@name='meeting-intelligence-locale']/@content") ?? "zh-CN"
        var segments: [TranscriptSegment] = [], speakers: [Speaker] = [], identities: [String: UUID] = [:]
        let sessionID = UUID()
        for row in try nodes("//div[@id='segments']/article[\(classPath("segment"))]") {
            try Task.checkCancellation()
            guard segments.count < 100_000, let startText = try value("./@data-start", in: row), let start = Double(startText),
                  let endText = try value("./@data-end", in: row), let end = Double(endText),
                  start.isFinite, end.isFinite, start >= 0, end >= start, end <= CloudAudioLimits.maximumDuration,
                  let words = try value(".//p[\(classPath("segment-text"))]", in: row) else { throw invalid("字幕内容或时间戳无效。") }
            let sourceText = try value("./@data-source", in: row)
            let sourceLabel = try value(".//span[\(classPath("source"))]", in: row)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let source: AudioSource
            if let sourceText {
                guard let parsed = AudioSource(rawValue: sourceText) else { throw invalid("字幕来源无效。") }
                source = parsed
            } else { source = AudioSource.allCases.first { $0.label == sourceLabel } ?? .application }
            var segment = TranscriptSegment(chunkID: nil, source: source, start: start, end: end, text: words)
            segment.engine = try value(".//span[\(classPath("engine"))]", in: row) ?? "HTML 导入"
            if let name = try value(".//span[\(classPath("speaker"))]", in: row), !name.isEmpty, name != "未区分发言人" {
                guard name.count <= 100 else { throw invalid("发言人名称超过 100 个字符。") }
                let identity = try value("./@data-speaker-id", in: row) ?? source.rawValue + ":" + name
                if identities[identity] == nil {
                    let person = Speaker(sessionID: sessionID, providerSpeakerID: "html-\(speakers.count + 1)",
                                         displayName: name, createdOrder: speakers.count + 1)
                    speakers.append(person); identities[identity] = person.id
                }
                segment.sessionID = sessionID; segment.speakerID = identities[identity]
            }
            segments.append(segment)
        }
        let summary = try value("//section[\(classPath("summary"))]//p[\(classPath("summary-text"))]")
        let summaryModel = try value("//section[\(classPath("summary"))]//p[\(classPath("summary-model"))]")
        return Content(bytes: bytes, audioRange: audioRange, audioExtension: audioExtension, title: title, locale: locale,
            complete: complete, segments: segments, speakers: speakers,
            summary: summary?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? summary : nil, summaryModel: summaryModel)
    }

    private static func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting-HTML-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
    private static func withAudio<T>(_ content: Content, body: (URL?) throws -> T) throws -> T {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        return try body(extractAudio(content, to: directory))
    }
    private static func extractAudio(_ content: Content, to directory: URL) throws -> URL? {
        guard let range = content.audioRange, let ext = content.audioExtension else { return nil }
        let url = directory.appendingPathComponent("audio.\(ext)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw invalid("无法创建临时音频。") }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        var encoded = Data(), position = range.lowerBound, finished = false, count = 0
        while position < range.upperBound {
            try Task.checkCancellation()
            let end = min(range.upperBound, position + 65536)
            let block = content.bytes[position..<end].filter { ![UInt8(9), 10, 13, 32].contains($0) }
            guard !finished || block.isEmpty else { throw invalid("音频 Base64 数据损坏。") }
            encoded.append(contentsOf: block)
            let length = encoded.count / 4 * 4
            if length > 0 {
                let groups = encoded.prefix(length)
                if let padding = groups.firstIndex(of: 61) {
                    guard padding >= length - 2, encoded.count == length else { throw invalid("音频 Base64 数据损坏。") }
                    finished = true
                }
                guard let decoded = Data(base64Encoded: groups) else { throw invalid("音频 Base64 数据损坏。") }
                try file.write(contentsOf: decoded); count += decoded.count
                encoded = Data(encoded.dropFirst(length))
            }
            position = end
        }
        guard encoded.isEmpty, count > 0 else { throw invalid("音频 Base64 数据不完整。") }
        return url
    }
}

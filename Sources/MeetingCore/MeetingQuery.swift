import Foundation

public struct MeetingFilter: Sendable {
    public var since: Date?
    public var until: Date?
    public var titleContains: String?
    public var app: String?
    public var hasTranscript = false
    public init() {}
    public func matches(_ recording: Recording) -> Bool {
        (since.map { recording.startedAt >= $0 } ?? true) &&
        (until.map { recording.startedAt < $0 } ?? true) &&
        (titleContains.map { MeetingQuery.contains(recording.title, query: $0) } ?? true) &&
        (app.map { recording.bundleIdentifier == $0 } ?? true)
    }
}

public struct MeetingSearchGroup: Sendable {
    public let snapshot: MeetingReadSnapshot
    public let segments: [TranscriptSegment]
    public let matchIDs: [UUID]
}

public struct MeetingPage<Item> {
    public let items: [Item]
    public let nextCursor: String?
    public var hasMore: Bool { nextCursor != nil }
}

public enum MeetingQuery {
    public static func recordingOrder(_ a: Recording, _ b: Recording) -> Bool {
        a.startedAt == b.startedAt ? a.id.uuidString < b.id.uuidString : a.startedAt > b.startedAt
    }
    public static func segmentOrder(_ a: TranscriptSegment, _ b: TranscriptSegment) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end < b.end }
        if a.source != b.source { return a.source.rawValue < b.source.rawValue }
        return a.id.uuidString < b.id.uuidString
    }
    public static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    public static func contains(_ text: String, query: String) -> Bool { folded(text).contains(folded(query)) }
    /// Count Unicode scalars rather than UTF-8 bytes or grapheme clusters (emoji can contain multiple scalars).
    public static func characterCount(_ text: String) -> Int { text.unicodeScalars.count }
    public static func transcript(_ snapshot: MeetingReadSnapshot, from: Double?, to: Double?, source: AudioSource?) -> [TranscriptSegment] {
        snapshot.segments.filter { segment in
            (source == nil || segment.source == source) &&
            (from.map { segment.end > $0 } ?? true) && (to.map { segment.start < $0 } ?? true)
        }
    }
    public static func search(_ snapshot: MeetingReadSnapshot, query: String, context: Int) -> [MeetingSearchGroup] {
        let segments = snapshot.segments
        let hits = segments.indices.filter { contains(segments[$0].text, query: query) }
        var ranges: [(start: Int, end: Int, hits: [UUID])] = []
        for index in hits {
            let start = max(0, index - context), end = min(segments.count, index + context + 1)
            if let last = ranges.last, start < last.end {
                ranges[ranges.count - 1] = (last.start, max(end, last.end), last.hits + [segments[index].id])
            } else { ranges.append((start, end, [segments[index].id])) }
        }
        return ranges.map { .init(snapshot: snapshot, segments: Array(segments[$0.start..<$0.end]), matchIDs: $0.hits) }
    }
    private struct Cursor: Codable {
        let version: Int
        let command: String
        let query: String
        let revision: String
        let next: Int
    }
    public static func page<Item>(items: [Item], command: String, query: String, revision: String,
                                 cursor: String?, limit: Int, maxChars: Int?, cost: (Item) -> Int) throws -> MeetingPage<Item> {
        guard limit > 0, maxChars.map({ $0 > 0 }) ?? true else { throw argumentError("分页预算必须为正整数。") }
        var offset = 0
        if let cursor {
            let normalized = cursor.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padded = normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4)
            guard cursor.count <= 16_384, let bytes = Data(base64Encoded: padded),
                  let token = try? JSONDecoder().decode(Cursor.self, from: bytes), token.version == 1,
                  token.command == command, token.query == query, token.next >= 0 else {
                throw MeetingReadError("INVALID_CURSOR", "Cursor 无效或不属于当前查询；请保持相同筛选和预算。", exitCode: 2)
            }
            guard token.revision == revision else {
                throw MeetingReadError("REVISION_CHANGED", "转写或会议集合已更新，请从首页重新读取或导出。", exitCode: 6, retryable: true)
            }
            guard token.next <= items.count else { throw MeetingReadError("INVALID_CURSOR", "Cursor 位置越界。", exitCode: 2) }
            offset = token.next
        }
        var end = offset, used = 0
        while end < items.count, end - offset < limit {
            let size = cost(items[end])
            if let maxChars, size > maxChars - used {
                if end == offset {
                    throw MeetingReadError("OUTPUT_LIMIT_TOO_SMALL", "一个完整结果超过 --max-chars；请增加预算或导出全文。", exitCode: 2)
                }
                break
            }
            used += size; end += 1
        }
        var next: String?
        if end < items.count {
            let token = Cursor(version: 1, command: command, query: query, revision: revision, next: end)
            next = try JSONEncoder().encode(token).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return .init(items: Array(items[offset..<end]), nextCursor: next)
    }
    public static func parseDate(_ text: String, timezone: TimeZone) throws -> Date {
        if text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = timezone; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            if let value = formatter.date(from: text), formatter.string(from: value) == text { return value }
        } else if text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$", options: .regularExpression) != nil {
            // ISO8601DateFormatter normalizes impossible dates (e.g. February 30).
            // Strictly validate the wall-clock components before parsing the instant.
            let wallClock = String(text.prefix(19))
            let strict = DateFormatter()
            strict.locale = Locale(identifier: "en_US_POSIX"); strict.calendar = Calendar(identifier: .gregorian)
            strict.timeZone = TimeZone(secondsFromGMT: 0); strict.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"; strict.isLenient = false
            guard let wallDate = strict.date(from: wallClock), strict.string(from: wallDate) == wallClock else {
                throw argumentError("无效日期：\(text)。")
            }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let value = formatter.date(from: text) { return value }
            formatter.formatOptions = [.withInternetDateTime]
            if let value = formatter.date(from: text) { return value }
        }
        throw argumentError("无效日期：\(text)。请使用 YYYY-MM-DD 或带时区 RFC 3339。")
    }
    public static func argumentError(_ message: String) -> MeetingReadError { .init("INVALID_ARGUMENT", message, exitCode: 2) }
}

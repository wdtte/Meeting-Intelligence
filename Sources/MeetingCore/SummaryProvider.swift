import CryptoKit
import Foundation

public enum SummaryProviderID: String, Codable, Sendable, CaseIterable {
    case openAICompatible
    public var label: String { "OpenAI 兼容服务" }
}

/// Secrets belong in Keychain, never in the transcript or configuration.
public struct SummaryConfiguration: Sendable, Equatable {
    public static let defaultBaseURL = "https://api.openai.com/v1"
    public static let baseURLPreference = "summaryBaseURL"
    public static let modelPreference = "summaryModel"
    public static let defaultModel = "gpt-4o-mini"
    public var baseURL: String
    public var model: String
    public init(baseURL: String = Self.defaultBaseURL, model: String = Self.defaultModel) {
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    public func validate() throws {
        guard !model.isEmpty, model.count <= 256, !model.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MeetingError.message("请输入有效的模型名称，例如 deepseek-chat 或 gpt-4o-mini。")
        }
        guard let url = URLComponents(string: baseURL),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else {
            throw MeetingError.message("请输入有效的 Base URL，例如 https://api.openai.com/v1。")
        }
        guard url.scheme?.lowercased() == "https" || ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()) else {
            throw MeetingError.message("远程摘要服务须使用 HTTPS；本机服务可使用 HTTP。")
        }
    }
}

public struct SummaryRequest: Sendable {
    public var id = UUID()
    public var recordingID: UUID
    public var locale: String
    public var segments: [TranscriptSegment]
    public init(recordingID: UUID, locale: String, segments: [TranscriptSegment]) { self.recordingID = recordingID; self.locale = locale; self.segments = segments }
    public var text: String {
        segments.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { "[\(AudioTimeline.clock($0.start)) · \($0.source.label)] \($0.text)" }.joined(separator: "\n")
    }
    /// Includes source, timestamps and language so edits invalidate an old summary.
    public var fingerprint: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(Fingerprint(recordingID: recordingID, locale: locale, segments: segments))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private struct Fingerprint: Encodable { var recordingID: UUID; var locale: String; var segments: [TranscriptSegment] }
}

public struct ProviderSummary: Sendable {
    public var text: String
    public var model: String
    public var usage: TranscriptionUsage?
    public init(text: String, model: String, usage: TranscriptionUsage? = nil) { self.text = text; self.model = model; self.usage = usage }
}

public protocol SummaryProvider: Sendable {
    var id: SummaryProviderID { get }
    func summarize(_ request: SummaryRequest) async throws -> ProviderSummary
    func summarize(_ request: SummaryRequest, progress: @escaping SummaryProgressHandler) async throws -> ProviderSummary
}
public extension SummaryProvider {
    func summarize(_ request: SummaryRequest, progress: @escaping SummaryProgressHandler) async throws -> ProviderSummary {
        try await summarize(request)
    }
}
public struct SummaryProgress: Codable, Sendable, Equatable {
    public var stage: String
    public var completed: Int
    public var total: Int
    /// Current part's cumulative text, kept in memory until a final result succeeds.
    public var draft: String? = nil
}
public typealias SummaryProgressHandler = @Sendable (SummaryProgress) async -> Void

public struct TranscriptSummary: Codable, Sendable, Equatable {
    public var requestID: UUID?
    public var usage: TranscriptionUsage?
    public var provider: SummaryProviderID = .openAICompatible
    public var status = "pending"
    public var text: String?
    public var model: String?
    public var generatedAt: Date?
    public var inputFingerprint: String
    public var error: String?
    public init(inputFingerprint: String) { self.inputFingerprint = inputFingerprint }
}

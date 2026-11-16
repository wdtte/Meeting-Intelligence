import Foundation

/// Swift facade for the bundled Rust OpenAI-compatible provider.
/// Credentials travel over anonymous pipes, never command-line arguments or files.
public struct OpenAISummaryProvider: SummaryProvider {
    public let id = SummaryProviderID.openAICompatible
    private let configuration: SummaryConfiguration
    private let apiKey: String
    public init(configuration: SummaryConfiguration, apiKey: String) {
        self.configuration = configuration; self.apiKey = apiKey
    }
    public static func configured() throws -> (any SummaryProvider)? {
        guard let baseURL = UserDefaults.standard.string(forKey: SummaryConfiguration.baseURLPreference), !baseURL.isEmpty else { return nil }
        guard let key = try SummaryCredentials.load() else { return nil }
        let model = UserDefaults.standard.string(forKey: SummaryConfiguration.modelPreference) ?? SummaryConfiguration.defaultModel
        return OpenAISummaryProvider(configuration: SummaryConfiguration(baseURL: baseURL, model: model), apiKey: key)
    }
    public func summarize(_ request: SummaryRequest) async throws -> ProviderSummary {
        try await summarize(request, progress: { _ in })
    }
    public func summarize(_ request: SummaryRequest, progress: @escaping SummaryProgressHandler) async throws -> ProviderSummary {
        try configuration.validate()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\r"), !key.contains("\n") else { throw MeetingError.message("请在设置中保存有效的摘要 API Key。") }
        guard !request.text.isEmpty else { throw MeetingError.message("暂无可总结的转写内容。") }
        let params: [String: Any] = ["baseURL": configuration.baseURL, "model": configuration.model, "apiKey": key, "text": request.text,
            "locale": request.locale, "meetingID": request.recordingID.uuidString, "inputFingerprint": request.fingerprint]
        let client = SummaryRPCClient()
        let data = try await client.generate(id: request.id.uuidString, params: params, progress: progress)
        let result = try JSONDecoder().decode(Result.self, from: data)
        guard result.meetingID == request.recordingID.uuidString, result.inputFingerprint == request.fingerprint else {
            throw SummaryRPCError.invalidResponse
        }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingError.message("摘要服务未返回有效文本。") }
        let usage = (result.usage ?? TranscriptionUsage()).attributed(modelName: result.model, apiKey: key)
        return ProviderSummary(text: result.text, model: result.model, usage: usage)
    }
    private struct Result: Decodable {
        var text: String; var model: String; var meetingID: String; var inputFingerprint: String
        var usage: TranscriptionUsage?
    }
}

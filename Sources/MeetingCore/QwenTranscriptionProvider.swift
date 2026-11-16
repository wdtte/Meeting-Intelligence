import Foundation

protocol TranscriptionHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// No disk cache, cookies or redirects (in particular, no forwarding Bearer keys).
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
struct TranscriptionURLTransport: TranscriptionHTTPTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MeetingError.message("云端响应无效。") }
        return (data, response)
    }
}

public struct QwenTranscriptionProvider: TranscriptionProvider {
    public let id = TranscriptionProviderID.qwen
    public let engine = "Qwen-Audio 3.1"
    private let configuration: CloudTranscriptionConfiguration
    private let diagnostics: DiagnosticLog
    private let apiKey: String
    private let transport: any TranscriptionHTTPTransport
    private let pollWait: @Sendable (Int) async throws -> Void
    public init(configuration: CloudTranscriptionConfiguration, apiKey: String) {
        self.init(configuration: configuration, apiKey: apiKey, transport: TranscriptionURLTransport())
    }
    init(configuration: CloudTranscriptionConfiguration, apiKey: String,
         transport: any TranscriptionHTTPTransport, diagnostics: DiagnosticLog = .shared,
         pollWait: @escaping @Sendable (Int) async throws -> Void = { attempt in
             try await Task.sleep(for: .seconds(min(10, 2 + attempt)))
         }) {
        self.diagnostics = diagnostics
        self.configuration = configuration; self.apiKey = apiKey; self.transport = transport; self.pollWait = pollWait
    }
    public func prepare(locale: String) async throws -> String {
        try configuration.validate()
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !apiKey.contains("\r"), !apiKey.contains("\n") else { throw MeetingError.message("请先在设置中保存对应地域的百炼 API Key。") }
        return locale
    }
    public func transcribe(_ request: TranscriptionRequest,
                           checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        var context = ["chunk_id": request.chunk.id.uuidString, "source": request.chunk.audioSource.rawValue,
                       "region": configuration.region.rawValue, "model": configuration.model]
        if let id = request.recordingID { context["recording_id"] = id.uuidString }
        diagnostics.record("cloud.chunk.begin", fields: context)
        do {
            var result = try await transcribeChunk(request, context: context, checkpoint: checkpoint)
            result.usage = (result.usage ?? TranscriptionUsage()).attributed(modelName: configuration.model, apiKey: apiKey)
            if request.checkpoint?.taskID != nil {
                // Polling can use a different credential from the original submission.
                result.usage?.keyID = request.checkpoint?.keyID
            }
            context["segments"] = String(result.segments.count)
            context["no_speech"] = String(result.noSpeechRecognized)
            diagnostics.record("cloud.chunk.completed", fields: context)
            return result
        } catch {
            diagnostics.failure("cloud.chunk.failed", error: error, fields: context)
            throw error
        }
    }
    private func transcribeChunk(_ request: TranscriptionRequest, context: [String: String],
                                checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        _ = try await prepare(locale: request.locale)
        var taskID = request.checkpoint?.taskID
        if taskID == nil {
            guard request.checkpoint?.phase != .submitting else {
                throw MeetingError.message("上次提交结果不确定，已停止自动重发以避免重复计费。请先在百炼控制台核对任务，再选择重新提交。")
            }
            let fileURL = try await upload(request.audioURL, context: context)
            try Task.checkCancellation()
            var submission = authorized(configuration.apiBase.appendingPathComponent("services/audio/asr/transcription"))
            submission.httpMethod = "POST"
            submission.setValue("enable", forHTTPHeaderField: "X-DashScope-Async")
            submission.setValue("enable", forHTTPHeaderField: "X-DashScope-OssResourceResolve")
            submission.httpBody = try JSONSerialization.data(withJSONObject: [
                "model": configuration.model, "input": ["file_urls": [fileURL]],
                "parameters": ["channel_id": [0], "diarization_enabled": false]
            ])
            // Persist before the non-idempotent request. A timeout cannot prove rejection.
            try await checkpoint(ProviderCheckpoint(phase: .submitting))
            let (data, response) = try await send(submission, stage: "submit", context: context)
            if (400..<500).contains(response.statusCode), response.statusCode != 408 {
                try await checkpoint(ProviderCheckpoint(phase: .rejected))
            }
            try check(response, data: data)
            let envelope = try JSONDecoder().decode(TaskEnvelope.self, from: data)
            guard let accepted = envelope.output?.task_id, !accepted.isEmpty else {
                throw MeetingError.message("云端未返回 task ID；请核对控制台后再重新提交。")
            }
            taskID = accepted
            try await checkpoint(ProviderCheckpoint(phase: .submitted, taskID: accepted, keyID: APIUsageIdentity.keyID(for: apiKey)))
        }
        guard let taskID, taskID.range(of: "^[a-zA-Z0-9_-]{1,256}$", options: .regularExpression) != nil else {
            throw MeetingError.message("云端 task ID 无效，请保留任务记录。")
        }
        var transientFailures = 0
        for attempt in 0..<180 {
            try Task.checkCancellation()
            let data: Data
            do {
                let (body, response) = try await send(authorized(configuration.apiBase.appendingPathComponent("tasks/\(taskID)")), stage: "poll", context: context.merging(["task_id": taskID, "attempt": String(attempt)]) { _, new in new })
                if response.statusCode == 429 || response.statusCode >= 500 {
                    transientFailures += 1
                    guard transientFailures <= 5 else { throw MeetingError.message("查询云端任务暂不可用，稍后继续会复用已有 task ID。") }
                    try await pollWait(attempt); continue
                }
                try check(response, data: body); data = body
            } catch let error as URLError where error.code != .cancelled {
                transientFailures += 1
                guard transientFailures <= 5 else { throw MeetingError.message("网络暂不可用，稍后继续会查询已有 task ID。") }
                try await pollWait(attempt); continue
            }
            let envelope = try JSONDecoder().decode(TaskEnvelope.self, from: data)
            guard let output = envelope.output else { throw MeetingError.message("云端任务响应缺少状态。") }
            switch output.task_status {
            case "PENDING", "RUNNING": try await pollWait(attempt)
            case "SUCCEEDED":
                guard let results = output.results, results.count == 1, let result = results.first else {
                    throw MeetingError.message("云端结果的文件数量与提交不匹配，已保留本地字幕。")
                }
                if result.subtask_status == "FAILED", Self.isNoSpeech(result.code) {
                    return ProviderTranscription(segments: [], usage: envelope.usage?.value, noSpeechRecognized: true)
                }
                guard result.subtask_status == "SUCCEEDED" else {
                    throw Self.taskFailure(status: result.subtask_status, code: result.code)
                }
                guard let address = result.transcription_url,
                      let url = URL(string: address), Self.isStorageURL(url) else {
                    throw MeetingError.message("云端文件子任务未成功或结果链接无效；保留本地字幕，可核对控制台。")
                }
                // Signed result URL does not receive the API key.
                let (body, response) = try await send(URLRequest(url: url), stage: "result", context: context.merging(["task_id": taskID]) { _, new in new })
                try check(response, data: body)
                var transcription = try Self.parse(body, chunk: request.chunk)
                transcription.usage = transcription.usage ?? envelope.usage?.value
                return transcription
            case "FAILED", "CANCELED", "UNKNOWN":
                let resultCode = output.results?.count == 1 ? output.results?.first?.code : nil
                let code = output.code ?? envelope.code ?? resultCode
                if output.task_status == "FAILED", Self.isNoSpeech(code) {
                    return ProviderTranscription(segments: [], usage: envelope.usage?.value, noSpeechRecognized: true)
                }
                throw Self.taskFailure(status: output.task_status, code: code)
            default: throw MeetingError.message("云端返回未知任务状态，已保留 task ID。")
            }
        }
        throw MeetingError.message("云端任务仍未完成，稍后继续会查询已有 task ID。")
    }
    private static func isNoSpeech(_ code: String?) -> Bool {
        code == "ASR_RESPONSE_HAVE_NO_WORDS" || code == "SUCCESS_WITH_NO_VALID_FRAGMENT"
    }
    private func send(_ request: URLRequest, stage: String, context: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var fields = context
        fields["stage"] = stage
        diagnostics.record("cloud.http.begin", fields: fields)
        do {
            let (data, response) = try await transport.send(request)
            fields["http_status"] = String(response.statusCode)
            // Select metadata only. Never record request/response bodies or signed URLs.
            if stage != "result", let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let output = body["output"] as? [String: Any]
                fields["request_id"] = body["request_id"] as? String
                fields["task_id"] = output?["task_id"] as? String ?? fields["task_id"]
                fields["status"] = output?["task_status"] as? String
                fields["code"] = output?["code"] as? String ?? body["code"] as? String
                if let results = output?["results"] as? [[String: Any]] {
                    for result in results where result["subtask_status"] as? String != "SUCCEEDED" {
                        var subtask = fields
                        subtask["status"] = result["subtask_status"] as? String
                        subtask["code"] = result["code"] as? String
                        diagnostics.record("cloud.subtask.result", fields: subtask)
                    }
                }
            }
            diagnostics.record("cloud.http.response", fields: fields)
            return (data, response)
        } catch {
            diagnostics.failure("cloud.http.failed", error: error, fields: fields)
            throw error
        }
    }
    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    private static func taskFailure(status: String?, code: String?) -> MeetingError {
        // Surface only machine codes, never provider messages containing URLs or credentials.
        let safeCode = code.flatMap { $0.range(of: "^[a-zA-Z0-9_.-]{1,100}$", options: .regularExpression) != nil ? $0 : nil }
        let state = ["FAILED", "CANCELED", "UNKNOWN"].contains(status ?? "") ? status! : "UNKNOWN"
        return .message("云端任务未完成（\(safeCode ?? state)），已保留本地字幕。请核对后重新提交。")
    }
    private func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            // Never surface raw response bodies: they may echo signed URLs or secrets.
            let code = (try? JSONDecoder().decode(APIError.self, from: data).code) ?? ""
            let safeCode = code.range(of: "^[a-zA-Z0-9_.-]{1,100}$", options: .regularExpression) != nil ? code : ""
            throw MeetingError.message("百炼请求失败（HTTP \(response.statusCode)\(safeCode.isEmpty ? "" : " · " + safeCode)）。请检查地域、模型权限、余额和网络。")
        }
    }
    private func upload(_ url: URL, context: [String: String]) async throws -> String {
        // The documented upload-policy endpoint uses the regional DashScope host.
        var components = URLComponents(string: "https://\(configuration.region.legacyHost)/api/v1/uploads")!
        components.queryItems = [URLQueryItem(name: "action", value: "getPolicy"), URLQueryItem(name: "model", value: configuration.model)]
        let (data, response) = try await send(authorized(components.url!), stage: "upload_policy", context: context)
        try check(response, data: data)
        let policy = try JSONDecoder().decode(UploadEnvelope.self, from: data).data
        guard let host = URL(string: policy.upload_host), Self.isStorageURL(host),
              !policy.upload_dir.contains("\r"), !policy.upload_dir.contains("\n") else {
            throw MeetingError.message("文件上传凭证中的地址无效。")
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 16 * 1024 * 1024 else { throw MeetingError.message("音频片段超过当前上传上限（16 MB）。") }
        let key = policy.upload_dir + "/" + UUID().uuidString + ".wav"
        let boundary = "Meeting-\(UUID())"
        var body = Data()
        func append(_ value: String) { body.append(Data(value.utf8)) }
        let fields = ["OSSAccessKeyId": policy.oss_access_key_id, "policy": policy.policy,
                      "Signature": policy.signature, "key": key,
                      "x-oss-object-acl": policy.x_oss_object_acl,
                      "x-oss-forbid-overwrite": policy.x_oss_forbid_overwrite, "success_action_status": "200"]
        for (name, value) in fields {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(bytes); append("\r\n--\(boundary)--\r\n")
        var upload = URLRequest(url: host); upload.httpMethod = "POST"; upload.httpBody = body
        upload.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (result, uploaded) = try await send(upload, stage: "upload", context: context)
        try check(uploaded, data: result)
        return "oss://" + key
    }
    static func isStorageURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.user == nil && url.password == nil &&
            (url.port == nil || url.port == 443) && (url.host?.hasSuffix(".aliyuncs.com") == true)
    }
    static func parse(_ data: Data, chunk: AudioChunk) throws -> ProviderTranscription {
        let result = try JSONDecoder().decode(ResultFile.self, from: data)
        var segments: [TranscriptSegment] = []
        guard result.transcripts.count == 1, let transcript = result.transcripts.first, transcript.channel_id == 0 else {
            throw MeetingError.message("云端结果音轨与上传音频不匹配。")
        }
        for sentence in transcript.sentences ?? [] {
            guard !sentence.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = sentence.begin_time / 1000, end = sentence.end_time / 1000
            guard start.isFinite, end.isFinite, start >= 0, start < chunk.duration, end > start,
                  end <= chunk.duration + 0.1 else { throw MeetingError.message("云端时间戳无效，保留原字幕。") }
            var segment = TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource,
                                            start: chunk.offset + min(start, chunk.duration),
                                            end: chunk.offset + min(end, chunk.duration), text: sentence.text)
            segment.engine = "Qwen-Audio 3.1"; segments.append(segment)
        }
        guard !segments.isEmpty || (transcript.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else {
            throw MeetingError.message("云端文字缺少句级时间戳，保留原字幕以确保回听位置准确。")
        }
        return ProviderTranscription(segments: segments, usage: result.usage?.value)
    }
}
private struct APIError: Decodable { var code: String? }
private struct UploadEnvelope: Decodable { var data: UploadPolicy }
private struct UploadPolicy: Decodable {
    var upload_host: String; var upload_dir: String; var oss_access_key_id: String
    var policy: String; var signature: String; var x_oss_object_acl: String; var x_oss_forbid_overwrite: String
}
private struct TokenUsage: Decodable {
    var input_tokens: Int?; var output_tokens: Int?
    var value: TranscriptionUsage? {
        guard input_tokens != nil || output_tokens != nil else { return nil }
        return TranscriptionUsage(inputTokens: input_tokens, outputTokens: output_tokens)
    }
}
private struct TaskEnvelope: Decodable {
    var output: Output?; var usage: TokenUsage?; var code: String?
    struct Output: Decodable { var task_id: String?; var task_status: String?; var results: [Result]?; var code: String? }
    struct Result: Decodable { var subtask_status: String?; var transcription_url: String?; var code: String? }
}
private struct ResultFile: Decodable {
    var transcripts: [Transcript]; var usage: TokenUsage?
    struct Transcript: Decodable { var channel_id: Int; var text: String?; var sentences: [Sentence]? }
    struct Sentence: Decodable { var begin_time: Double; var end_time: Double; var text: String }
}

import Foundation

public enum TranscriptionProviderID: String, Codable, Sendable, CaseIterable {
    case apple, qwen
    public var label: String { self == .apple ? "本地转写" : "Qwen-Audio 3.1" }
    public static var cloudProviders: [Self] { [.qwen] }
}

public enum QwenRegion: String, Codable, Sendable, CaseIterable {
    case beijing, singapore
    public var label: String { self == .beijing ? "北京" : "新加坡" }
    var legacyHost: String { self == .beijing ? "dashscope.aliyuncs.com" : "dashscope-intl.aliyuncs.com" }
    var workspaceSuffix: String { self == .beijing ? "cn-beijing.maas.aliyuncs.com" : "ap-southeast-1.maas.aliyuncs.com" }
}

/// A recording snapshots these settings. Credentials are never part of its manifest.
public struct CloudTranscriptionConfiguration: Codable, Sendable, Equatable {
    public var provider: TranscriptionProviderID = .qwen
    public var region: QwenRegion = .beijing
    public var workspaceID = ""
    public var skipSilence = true
    public var diarizationEnabled: Bool?
    public var strategy: CloudTaskStrategy?
    public var usesSessions: Bool { strategy == .sourceSessions || diarizationEnabled == true }
    public var model: String { "qwen-audio-3.1-asr-flash-filetrans" }
    public init(region: QwenRegion = .beijing, workspaceID: String = "", skipSilence: Bool = true, diarizationEnabled: Bool = false, strategy: CloudTaskStrategy = .legacyChunks) {
        self.region = region; self.workspaceID = workspaceID; self.skipSilence = skipSilence
        self.diarizationEnabled = diarizationEnabled; self.strategy = strategy
    }
    public func validate() throws {
        guard provider == .qwen else { throw MeetingError.message("尚未实现所选云端服务。") }
        guard workspaceID.isEmpty || workspaceID.range(of: "^[a-zA-Z0-9][a-zA-Z0-9-]{0,62}$", options: .regularExpression) != nil else {
            throw MeetingError.message("Workspace ID 格式无效。")
        }
    }
    var apiBase: URL {
        let host = workspaceID.isEmpty ? region.legacyHost : "\(workspaceID).\(region.workspaceSuffix)"
        return URL(string: "https://\(host)/api/v1")!
    }
}

public struct ProviderCheckpoint: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable { case submitting, submitted, rejected }
    public var phase: Phase
    public var taskID: String?
    public var keyID: String?
    public init(phase: Phase, taskID: String? = nil, keyID: String? = nil) {
        self.phase = phase; self.taskID = taskID; self.keyID = keyID
    }
}

public struct TranscriptionUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var modelName: String?
    public var keyID: String?
    public var recordedAt: Date?
    public init(inputTokens: Int? = nil, outputTokens: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}

public struct CloudChunkJob: Codable, Sendable, Equatable {
    public var checkpoint: ProviderCheckpoint?
    public var completed = false
    public var skippedSilence = false
    public var audioDuration: Double = 0
    public var usage: TranscriptionUsage?
    // Optional for compatibility with previously saved jobs.
    public var noSpeechRecognized: Bool?
    public init() {}
}

public struct CloudTranscriptionProgress: Codable, Sendable, Equatable {
    public var runID = UUID()
    public var configuration: CloudTranscriptionConfiguration
    public var jobs: [String: CloudChunkJob] = [:]
    public var sessions: [CloudTranscriptionSession]?
    public var history: [CloudRunHistory]?
    public var status = "pending"
    public var error: String?
    public init(configuration: CloudTranscriptionConfiguration) { self.configuration = configuration }
    public var skippedSeconds: Double { jobs.values.filter(\.skippedSilence).reduce(0) { $0 + $1.audioDuration } }
    public var completedCount: Int { jobs.values.filter(\.completed).count }
    public var noSpeechCount: Int { jobs.values.filter { $0.noSpeechRecognized == true }.count + (sessions ?? []).filter(\.noSpeechRecognized).count }
    public var inputTokens: Int { jobs.values.reduce(0) { $0 + ($1.usage?.inputTokens ?? 0) } }
    public var outputTokens: Int { jobs.values.reduce(0) { $0 + ($1.usage?.outputTokens ?? 0) } }
}

public struct TranscriptionAudioInput: Sendable {
    public var id: UUID
    public var audioSource: AudioSource
    public var offset: Double
    public var duration: Double
    public var fileName: String
    public var end: Double { offset + duration }
    public init(chunk: AudioChunk) { fileName = chunk.fileName; id = chunk.id; audioSource = chunk.audioSource; offset = chunk.offset; duration = chunk.duration }
    public init(session: CloudTranscriptionSession) { fileName = "session-input.wav"; id = session.id; audioSource = session.source; offset = 0; duration = session.duration }
}
public struct TranscriptionRequest: Sendable {
    public var recordingID: UUID?
    public var audioURL: URL
    public var input: TranscriptionAudioInput
    public var chunk: TranscriptionAudioInput { input }
    public var locale: String
    public var checkpoint: ProviderCheckpoint?
    public var sessionID: UUID?
    public var storageChunk: AudioChunk?
    public init(audioURL: URL, chunk: AudioChunk, locale: String, checkpoint: ProviderCheckpoint? = nil, recordingID: UUID? = nil) {
        self.recordingID = recordingID; self.storageChunk = chunk
        self.audioURL = audioURL; self.input = TranscriptionAudioInput(chunk: chunk); self.locale = locale; self.checkpoint = checkpoint
    }
    public init(audioURL: URL, session: CloudTranscriptionSession, locale: String, recordingID: UUID) {
        self.audioURL = audioURL; self.input = TranscriptionAudioInput(session: session); self.locale = locale
        self.recordingID = recordingID; self.sessionID = session.id; self.checkpoint = session.checkpoint
    }
}

public struct ProviderTranscription: Sendable {
    public var segments: [TranscriptSegment]
    public var usage: TranscriptionUsage?
    public var noSpeechRecognized: Bool
    public init(segments: [TranscriptSegment], usage: TranscriptionUsage? = nil, noSpeechRecognized: Bool = false) {
        self.segments = segments; self.usage = usage; self.noSpeechRecognized = noSpeechRecognized
    }
}

public typealias TranscriptionCheckpointHandler = @Sendable (ProviderCheckpoint) async throws -> Void

/// Providers own their wire protocol; the coordinator owns durable jobs and replacement.
public protocol TranscriptionProvider: Sendable {
    var id: TranscriptionProviderID { get }
    var engine: String { get }
    func prepare(locale: String) async throws -> String
    func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription
}

public struct LocalTranscriptionProvider: TranscriptionProvider {
    public let id = TranscriptionProviderID.apple
    public let engine = LocalTranscriber.engine
    public init() {}
    public func prepare(locale: String) async throws -> String { try await LocalTranscriber.prepare(locale: locale, download: true) }
    public func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        guard let chunk = request.storageChunk else { throw MeetingError.message("本地识别仅接受存储片段。") }
        return try await ProviderTranscription(segments: LocalTranscriber.transcribe(url: request.audioURL, chunk: chunk, locale: request.locale))
    }
}

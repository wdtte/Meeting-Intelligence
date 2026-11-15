import Foundation
import Observation

@MainActor @Observable
public final class TranscriptionCoordinator {
    public private(set) var documents: [UUID: TranscriptDocument] = [:]
    public private(set) var running: Set<UUID> = []
    public private(set) var cloudRunning: Set<UUID> = []
    @ObservationIgnored private var cloudTasks: [UUID: Task<Void, Never>] = [:]
    typealias CloudFactory = @Sendable (CloudTranscriptionConfiguration) throws -> any TranscriptionProvider
    @ObservationIgnored private let cloudFactory: CloudFactory
    @ObservationIgnored private var paused: Set<UUID> = []
    @ObservationIgnored private var pending: [UUID: Recording] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    typealias Recognize = @Sendable (URL, AudioChunk, String) async throws -> [TranscriptSegment]
    @ObservationIgnored private let prepare: @Sendable (String) async throws -> String
    @ObservationIgnored private let recognize: Recognize
    public convenience init() {
        let apple = AppleTranscriptionProvider()
        self.init(prepare: { try await apple.prepare(locale: $0) },
                  recognize: { url, chunk, locale in
                      try await apple.transcribe(TranscriptionRequest(audioURL: url, chunk: chunk, locale: locale), checkpoint: { _ in }).segments
                  })
    }
    init(prepare: @escaping @Sendable (String) async throws -> String, recognize: @escaping Recognize,
         cloudFactory: @escaping CloudFactory = { configuration in
             guard configuration.provider == .qwen else { throw MeetingError.message("尚未实现该云端服务。") }
             guard let key = try TranscriptionCredentials.load(region: configuration.region) else {
                 throw MeetingError.message("请在设置中保存\(configuration.region.label)地域的百炼 API Key。")
             }
             return QwenTranscriptionProvider(configuration: configuration, apiKey: key)
         }) {
        self.prepare = prepare; self.recognize = recognize; self.cloudFactory = cloudFactory
    }
    public func wait(for id: UUID) async { await tasks[id]?.value; await cloudTasks[id]?.value }

    public func load(_ recording: Recording) {
        guard !running.contains(recording.id), let path = recording.transcriptPath else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return }
        do {
            var document = try TranscriptDocument.load(from: url, recordingID: recording.id)
            if let cloud = document.cloud {
                DiagnosticLog.shared.record("cloud.saved_state", fields: ["recording_id": recording.id.uuidString, "status": cloud.status])
            }
            if document.status == "running" || document.status == "pending" {
                document.status = "interrupted"; document.error = "上次转写未完成，可继续转写。"
            }
            if document.cloud?.status == "running" || document.cloud?.status == "pending" {
                document.cloud?.status = "interrupted"
                document.cloud?.error = "上次云端精校未完成，可继续查询已有任务。"
            }
            documents[recording.id] = document
        } catch {
            var document = TranscriptDocument(recordingID: recording.id, locale: recording.transcriptionLocale ?? "zh-CN")
            document.status = "failed"; document.error = error.localizedDescription
            documents[recording.id] = document
        }
    }
    public func submit(_ recording: Recording, store: RecordingStore, retry: Bool = false) {
        guard let path = recording.transcriptPath else { return }
        pending[recording.id] = recording
        if retry { paused.remove(recording.id) }
        guard !paused.contains(recording.id) else { return }
        guard tasks[recording.id] == nil, cloudTasks[recording.id] == nil else { return }
        if documents[recording.id]?.status == "failed", !retry {
            startCloud(recording, store: store, retry: false); return
        }
        running.insert(recording.id)
        tasks[recording.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.running.remove(recording.id); self.tasks[recording.id] = nil
                if let latest = self.pending[recording.id], !Task.isCancelled {
                    self.startCloud(latest, store: store, retry: retry)
                }
            }
            let url = URL(fileURLWithPath: path)
            do {
                var document: TranscriptDocument
                if FileManager.default.fileExists(atPath: path) {
                    document = try TranscriptDocument.load(from: url, recordingID: recording.id)
                } else {
                    document = TranscriptDocument(recordingID: recording.id, locale: recording.transcriptionLocale ?? "zh-CN")
                }
                document.status = "running"; document.error = nil
                try document.save(to: url); self.documents[recording.id] = document
                var locale: String?
                while let latest = self.pending[recording.id] {
                    try Task.checkCancellation()
                    guard let chunk = latest.chunks.filter({ $0.isComplete && !document.processedChunks.contains($0.id) }).sorted(by: { $0.offset < $1.offset }).first else {
                        document.status = latest.status == .recording ? "pending" : "completed"
                        try document.save(to: url); self.documents[recording.id] = document
                        break
                    }
                    if locale == nil { locale = try await self.prepare(document.locale) }
                    let audioURL = try store.audioURL(recording: latest.id, fileName: chunk.fileName)
                    let segments = try await self.recognize(audioURL, chunk, locale ?? document.locale)
                    try Task.checkCancellation()
                    try document.commit(segments, for: chunk)
                    try document.save(to: url)
                    self.documents[recording.id] = document
                }
            } catch {
                var document = self.documents[recording.id] ?? TranscriptDocument(recordingID: recording.id, locale: recording.transcriptionLocale ?? "zh-CN")
                document.status = error is CancellationError ? "interrupted" : "failed"
                document.error = error is CancellationError ? "转写已暂停，可继续转写。" : error.localizedDescription
                // Do not replace a corrupt existing transcript with an empty document.
                if (try? TranscriptDocument.load(from: url, recordingID: recording.id)) != nil {
                    do { try document.save(to: url) }
                    catch { document.error = "转写保存失败：\(error.localizedDescription)" }
                }
                self.documents[recording.id] = document
            }
        }
    }
    public func pause(_ id: UUID) { paused.insert(id); tasks[id]?.cancel(); cloudTasks[id]?.cancel() }
    public func stopAndForget(_ id: UUID) async {
        pause(id)
        pending.removeValue(forKey: id)
        await wait(for: id)
        documents.removeValue(forKey: id)
    }
    public func cancelAll() {
        for task in tasks.values { task.cancel() }
        for task in cloudTasks.values { task.cancel() }
    }

    /// Explicit, user-confirmed retry for failed/expired or ambiguous submissions only.
    public func resetUnfinishedCloudJobs(_ recording: Recording, store: RecordingStore) throws {
        guard !running.contains(recording.id), var document = documents[recording.id], var cloud = document.cloud else { return }
        cloud.jobs = cloud.jobs.filter { $0.value.completed }
        cloud.error = nil; cloud.status = "interrupted"
        document.cloud = cloud
        guard let path = recording.transcriptPath else { return }
        try document.save(to: URL(fileURLWithPath: path)); documents[recording.id] = document
        submit(recording, store: store, retry: true)
    }

    private func startCloud(_ recording: Recording, store: RecordingStore, retry: Bool) {
        guard recording.status != .recording, let configuration = recording.cloudTranscription,
              let path = recording.transcriptPath, cloudTasks[recording.id] == nil,
              !paused.contains(recording.id), var document = documents[recording.id] else { return }
        // A corrupt existing transcript must never be replaced by an empty fallback.
        guard (try? TranscriptDocument.load(from: URL(fileURLWithPath: path), recordingID: recording.id)) != nil else { return }
        if let cloud = document.cloud {
            if cloud.status == "completed" || (cloud.status == "failed" && !retry) { return }
        } else { document.cloud = CloudTranscriptionProgress(configuration: configuration) }
        documents[recording.id] = document
        DiagnosticLog.shared.record("cloud.meeting.begin", fields: ["recording_id": recording.id.uuidString])
        running.insert(recording.id); cloudRunning.insert(recording.id)
        cloudTasks[recording.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.running.remove(recording.id); self.cloudRunning.remove(recording.id)
                self.cloudTasks[recording.id] = nil
            }
            let url = URL(fileURLWithPath: path)
            var diagnosticContext = ["recording_id": recording.id.uuidString, "stage": "save_progress"]
            do {
                try self.updateCloud(recording.id, url: url) { $0.status = "running"; $0.error = nil }
                guard let cloud = self.documents[recording.id]?.cloud else { return }
                diagnosticContext["stage"] = "provider_credentials"
                let provider = try self.cloudFactory(cloud.configuration)
                diagnosticContext["stage"] = "provider_prepare"
                _ = try await provider.prepare(locale: document.locale)
                for chunk in recording.chunks.filter(\.isComplete).sorted(by: { $0.offset < $1.offset }) {
                    try Task.checkCancellation()
                    let jobKey = chunk.id.uuidString
                    if self.documents[recording.id]?.cloud?.jobs[jobKey]?.completed == true { continue }
                    diagnosticContext["chunk_id"] = jobKey
                    diagnosticContext["source"] = chunk.audioSource.rawValue
                    diagnosticContext["stage"] = "audio_prepare"
                    DiagnosticLog.shared.record("cloud.audio.begin", fields: diagnosticContext)
                    let original = try store.audioURL(recording: recording.id, fileName: chunk.fileName)
                    let saved = self.documents[recording.id]?.cloud?.jobs[jobKey]?.checkpoint
                    // A submitted job only needs polling; never upload its audio a second time.
                    let prepared = saved == nil || saved?.phase == .rejected
                        ? try await CloudAudioPreparation.prepare(url: original, skipSilence: cloud.configuration.skipSilence)
                        : PreparedCloudAudio(url: original)
                    defer {
                        if let temporary = prepared.url, temporary != original { try? FileManager.default.removeItem(at: temporary) }
                    }
                    var job = self.documents[recording.id]?.cloud?.jobs[jobKey] ?? CloudChunkJob()
                    job.audioDuration = chunk.duration
                    diagnosticContext["stage"] = "save_progress"
                    try self.updateCloud(recording.id, url: url) { $0.jobs[jobKey] = job }
                    let result: ProviderTranscription
                    diagnosticContext["stage"] = "transcribe"
                    if let audioURL = prepared.url {
                        result = try await provider.transcribe(TranscriptionRequest(audioURL: audioURL, chunk: chunk,
                            locale: document.locale, checkpoint: saved, recordingID: recording.id)) { [weak self] checkpoint in
                                try await self?.saveCheckpoint(checkpoint, recordingID: recording.id, jobKey: jobKey, url: url)
                            }
                    } else {
                        DiagnosticLog.shared.record("cloud.audio.silence_skipped", fields: diagnosticContext)
                        result = ProviderTranscription(segments: [])
                    }
                    try Task.checkCancellation()
                    diagnosticContext["stage"] = "save_result"
                    // Read the latest document: checkpoint writes may have changed it while awaiting.
                    guard var latest = self.documents[recording.id] else { throw CancellationError() }
                    // No words is a terminal result for this chunk, not a failed meeting.
                    // Keep any local fallback rather than replacing it with an empty result.
                    if !result.noSpeechRecognized { try latest.commit(result.segments, for: chunk) }
                    latest.cloud?.jobs[jobKey]?.completed = true
                    latest.cloud?.jobs[jobKey]?.noSpeechRecognized = result.noSpeechRecognized
                    latest.cloud?.jobs[jobKey]?.skippedSilence = prepared.isSilent
                    latest.cloud?.jobs[jobKey]?.usage = result.usage
                    latest.engine = "Apple + \(provider.engine)"
                    try latest.save(to: url); self.documents[recording.id] = latest
                }
                diagnosticContext["stage"] = "save_completed"
                try self.updateCloud(recording.id, url: url) { $0.status = "completed"; $0.error = nil }
                DiagnosticLog.shared.record("cloud.meeting.completed", fields: ["recording_id": recording.id.uuidString])
            } catch {
                DiagnosticLog.shared.failure("cloud.meeting.failed", error: error, fields: diagnosticContext)
                do {
                    try self.updateCloud(recording.id, url: url) {
                        $0.status = Task.isCancelled || error is CancellationError ? "interrupted" : "failed"
                        $0.error = Task.isCancelled || error is CancellationError ? "云端精校已暂停，可继续查询已有任务。" : error.localizedDescription
                    }
                } catch {
                    DiagnosticLog.shared.failure("cloud.progress.save_failed", error: error, fields: diagnosticContext)
                    self.documents[recording.id]?.cloud?.error = "云端进度保存失败：\(error.localizedDescription)"
                }
            }
        }
    }
    private func saveCheckpoint(_ checkpoint: ProviderCheckpoint, recordingID: UUID, jobKey: String, url: URL) throws {
        try updateCloud(recordingID, url: url) { $0.jobs[jobKey]?.checkpoint = checkpoint }
    }
    private func updateCloud(_ id: UUID, url: URL, _ update: (inout CloudTranscriptionProgress) -> Void) throws {
        guard var document = documents[id], var cloud = document.cloud else { throw CancellationError() }
        update(&cloud); document.cloud = cloud
        try document.save(to: url); documents[id] = document
    }
}

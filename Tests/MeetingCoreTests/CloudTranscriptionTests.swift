import Testing
import Foundation
import AVFoundation
@testable import MeetingCore

private actor ScriptedHTTP: TranscriptionHTTPTransport {
    struct Reply: Sendable {
        var status: Int = 200
        var body: String = ""
        var networkFailure = false
    }
    var replies: [Reply]
    var requests: [URLRequest] = []
    init(_ replies: [Reply]) { self.replies = replies }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw MeetingError.message("unexpected HTTP request") }
        let reply = replies.removeFirst()
        if reply.networkFailure { throw URLError(.timedOut) }
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!)
    }
}
private actor Checkpoints {
    var values: [ProviderCheckpoint] = []
    func add(_ checkpoint: ProviderCheckpoint) { values.append(checkpoint) }
}

@Test func cloudDiagnosticsCorrelateFailureWithoutPayloadOrCredentials() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let log = DiagnosticLog(directory: root)
    let http = ScriptedHTTP([.init(body: #"{"request_id":"request-fixture","output":{"task_status":"FAILED","code":"FILE_DOWNLOAD_FAILED","message":"private-body https://secret.example/signed"}}"#)])
    let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "private-key", transport: http, diagnostics: log)
    let recordingID = UUID(), chunk = fixtureChunk()
    do {
        _ = try await provider.transcribe(.init(audioURL: root.appendingPathComponent("private-audio.wav"),
            chunk: chunk, locale: "zh-CN", checkpoint: .init(phase: .submitted, taskID: "task-fixture"),
            recordingID: recordingID), checkpoint: { _ in Issue.record("must reuse saved task") })
        Issue.record("expected failure")
    } catch {}
    log.flush()
    let raw = try String(contentsOf: root.appendingPathComponent("app.jsonl"), encoding: .utf8)
    #expect(!raw.contains("private")); #expect(!raw.contains("secret.example"))
    let entries = try raw.split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: String] }
    let response = try #require(entries.first { $0["event"] == "cloud.http.response" })
    #expect(response["recording_id"] == recordingID.uuidString)
    #expect(response["chunk_id"] == chunk.id.uuidString)
    #expect(response["task_id"] == "task-fixture")
    #expect(response["request_id"] == "request-fixture")
    #expect(response["code"] == "FILE_DOWNLOAD_FAILED")
    #expect(response["stage"] == "poll")
    #expect(response["http_status"] == "200")
    #expect(entries.last?["event"] == "cloud.chunk.failed")
}
private let uploadPolicy = #"{"data":{"upload_host":"https://dashscope-file-fixture.oss-cn-beijing.aliyuncs.com","upload_dir":"fixture","oss_access_key_id":"test-access","policy":"test-policy","signature":"test-signature","x_oss_object_acl":"private","x_oss_forbid_overwrite":"true"}}"#
private let cloudText = #"{"transcripts":[{"channel_id":0,"text":"云端文字","sentences":[{"begin_time":100,"end_time":600,"text":"云端文字"}]}],"usage":{"input_tokens":50,"output_tokens":4}}"#
private func fixtureChunk(source: AudioSource = .application, offset: Double = 30) -> AudioChunk {
    AudioChunk(source: source, fileName: "fixture.wav", offset: offset, duration: 1, sampleRate: 48000, channels: 2, isComplete: true)
}
private func writeCloudFixture(_ url: URL, values: [Float]) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: UInt32(values.count))!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    buffer.frameLength = buffer.frameCapacity
    for channel in values.indices {
        for frame in 0..<48000 { buffer.floatChannelData![channel][frame] = values[channel] * sin(Float(frame) * 0.06) }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

@Test func qwenAsyncUploadsPollsAndMapsSentenceTimestampsWithoutLeakingKey() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("QwenFixture-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeCloudFixture(url, values: [0.01, -0.01])
    let http = ScriptedHTTP([
        .init(body: uploadPolicy), .init(),
        .init(body: #"{"output":{"task_id":"fixture-task","task_status":"PENDING"}}"#),
        .init(status: 429),
        .init(body: #"{"output":{"task_status":"RUNNING"}}"#),
        .init(body: #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://dashscope-result-bj.oss-cn-beijing.aliyuncs.com/fixture.json"}]}}"#),
        .init(body: cloudText)
    ])
    let provider = QwenTranscriptionProvider(configuration: .init(workspaceID: "workspace-test"), apiKey: "test-api-key", transport: http, pollWait: { _ in })
    let saved = Checkpoints()
    let chunk = fixtureChunk(source: .microphone)
    let result = try await provider.transcribe(.init(audioURL: url, chunk: chunk, locale: "zh-CN")) { await saved.add($0) }
    #expect(result.segments.count == 1)
    #expect(result.segments.first?.start == 30.1)
    #expect(result.segments.first?.end == 30.6)
    #expect(result.segments.first?.source == .microphone)
    #expect(result.segments.first?.chunkID == chunk.id)
    #expect(result.usage?.inputTokens == 50)
    #expect(result.usage?.modelName == "qwen-audio-3.1-asr-flash-filetrans")
    #expect(result.usage?.keyID == APIUsageIdentity.keyID(for: "test-api-key"))
    #expect(result.usage?.recordedAt != nil)
    #expect(await saved.values.map(\.phase) == [.submitting, .submitted])
    #expect(await saved.values.last?.keyID == result.usage?.keyID)
    let requests = await http.requests
    #expect(requests.count == 7)
    #expect(requests[0].url?.host == "dashscope.aliyuncs.com")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == nil)
    #expect(requests[2].url?.host == "workspace-test.cn-beijing.maas.aliyuncs.com")
    #expect(requests[2].value(forHTTPHeaderField: "X-DashScope-Async") == "enable")
    #expect(requests[2].value(forHTTPHeaderField: "X-DashScope-OssResourceResolve") == "enable")
    let submitted = try #require(try JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
    #expect(submitted["model"] as? String == "qwen-audio-3.1-asr-flash-filetrans")
    #expect(submitted["parameters"] != nil)
    #expect(requests.last?.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test func qwenSubmittedTaskResumesWithoutReadingOrReuploadingAudio() async throws {
    let http = ScriptedHTTP([
        .init(body: #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://result.oss-cn-beijing.aliyuncs.com/result.json"}]}}"#),
        .init(body: cloudText)
    ])
    let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "fixture", transport: http, pollWait: { _ in })
    let result = try await provider.transcribe(.init(audioURL: URL(fileURLWithPath: "/does-not-exist.wav"), chunk: fixtureChunk(), locale: "zh-CN",
        checkpoint: .init(phase: .submitted, taskID: "already-paid")), checkpoint: { _ in Issue.record("must not submit again") })
    #expect(result.usage?.keyID == nil)
    #expect(await http.requests.first?.url?.path == "/api/v1/tasks/already-paid")
    #expect(await http.requests.count == 2)
}

@Test func resumedCloudUsageKeepsOriginalKeyIdentityAfterKeyRotation() async throws {
    let http = ScriptedHTTP([
        .init(body: #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://result.oss-cn-beijing.aliyuncs.com/result.json"}]}}"#),
        .init(body: cloudText)
    ])
    let originalKeyID = APIUsageIdentity.keyID(for: "original-key")
    let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "replacement-key", transport: http)
    let result = try await provider.transcribe(.init(audioURL: URL(fileURLWithPath: "/unused.wav"), chunk: fixtureChunk(), locale: "zh-CN",
        checkpoint: .init(phase: .submitted, taskID: "already-paid", keyID: originalKeyID)), checkpoint: { _ in Issue.record("must not resubmit") })
    #expect(result.usage?.keyID == originalKeyID)
    #expect(result.usage?.keyID != APIUsageIdentity.keyID(for: "replacement-key"))
}

@Test func ambiguousSubmissionAndFailedSubtasksNeverAutomaticallyResubmit() async throws {
    let http = ScriptedHTTP([])
    let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "fixture", transport: http, pollWait: { _ in })
    await #expect(throws: MeetingError.self) {
        _ = try await provider.transcribe(.init(audioURL: URL(fileURLWithPath: "/missing.wav"), chunk: fixtureChunk(), locale: "zh-CN",
            checkpoint: .init(phase: .submitting)), checkpoint: { _ in })
    }
    #expect(await http.requests.isEmpty)
    let failed = ScriptedHTTP([.init(body: #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"FAILED","code":"FILE_DOWNLOAD_FAILED"}]}}"#)])
    let other = QwenTranscriptionProvider(configuration: .init(), apiKey: "fixture", transport: failed, pollWait: { _ in })
    await #expect(throws: MeetingError.self) {
        _ = try await other.transcribe(.init(audioURL: URL(fileURLWithPath: "/missing.wav"), chunk: fixtureChunk(), locale: "zh-CN",
            checkpoint: .init(phase: .submitted, taskID: "failed-task")), checkpoint: { _ in })
    }
    #expect(await failed.requests.count == 1)
}

@Test func invalidCloudTimestampsAreRejectedBeforeLocalReplacement() throws {
    let chunk = fixtureChunk()
    for body in [
        #"{"transcripts":[{"channel_id":0,"text":"bad","sentences":[{"begin_time":0,"end_time":9000,"text":"bad"}]}]}"#,
        #"{"transcripts":[{"channel_id":0,"text":"no timestamps"}]}"#,
        #"{"transcripts":[{"channel_id":1,"text":"wrong track","sentences":[]}]}"#
    ] {
        #expect(throws: MeetingError.self) { _ = try QwenTranscriptionProvider.parse(Data(body.utf8), chunk: chunk) }
    }
    #expect(!QwenTranscriptionProvider.isStorageURL(URL(string: "https://localhost/test")!))
    #expect(!QwenTranscriptionProvider.isStorageURL(URL(string: "https://aliyuncs.com.attacker.example/test")!))
}

@Test func silenceGateKeepsQuietSpeechAndAvoidsStereoCancellation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Silence-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for (name, values, expectSilent) in [("silent", [Float(0), 0], true), ("quiet", [Float(0.001), 0], false), ("phase", [Float(0.1), -0.1], false)] {
        let original = root.appendingPathComponent(name + ".wav")
        try writeCloudFixture(original, values: values)
        let prepared = try await CloudAudioPreparation.prepare(url: original, skipSilence: true)
        #expect(prepared.isSilent == expectSilent)
        if let url = prepared.url {
            defer { try? FileManager.default.removeItem(at: url) }
            let file = try AVAudioFile(forReading: url)
            #expect(file.processingFormat.sampleRate == 16000)
            #expect(file.processingFormat.channelCount == 1)
            #expect(abs(Double(file.length) / 16000 - 1) < 0.01)
            let samples = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
            try file.read(into: samples)
            #expect((0..<Int(samples.frameLength)).contains { abs(samples.floatChannelData![0][$0]) > 0.0002 })
        }
    }
    let silent = root.appendingPathComponent("silent.wav")
    let forced = try await CloudAudioPreparation.prepare(url: silent, skipSilence: false)
    #expect(!forced.isSilent)
    if let url = forced.url { try FileManager.default.removeItem(at: url) }
}

private actor CloudAttempts {
    var requests: [TranscriptionRequest] = []
    func record(_ request: TranscriptionRequest) -> Int { requests.append(request); return requests.filter { $0.chunk.id == request.chunk.id }.count }
}
private struct FixtureCloud: TranscriptionProvider {
    let id = TranscriptionProviderID.qwen
    let engine = "Fixture cloud"
    let attempts: CloudAttempts
    var failChunk: UUID?
    func prepare(locale: String) async throws -> String { locale }
    func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        let attempt = await attempts.record(request)
        if request.checkpoint == nil { try await checkpoint(.init(phase: .submitted, taskID: request.chunk.id.uuidString)) }
        if request.chunk.id == failChunk && attempt == 1 { throw URLError(.timedOut) }
        var segment = TranscriptSegment(chunkID: request.chunk.id, source: request.chunk.audioSource,
            start: request.chunk.offset + 0.1, end: request.chunk.offset + 0.6, text: "cloud")
        segment.engine = engine
        return ProviderTranscription(segments: [segment], usage: .init(inputTokens: 10, outputTokens: 2))
    }
}

@Test @MainActor func cloudReplacesPerChunkKeepsFallbackAndResumesSavedJobsAcrossRestart() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPipeline-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "fixture", applicationName: "fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcript.json").path
    recording.cloudTranscription = .init()
    recording.status = .completed
    var first = fixtureChunk(offset: 5); first.fileName = "first.wav"
    var second = fixtureChunk(source: .microphone, offset: 6); second.fileName = "second.wav"
    var silent = fixtureChunk(offset: 8); silent.fileName = "silent.wav"
    recording.chunks = [first, second, silent]
    try store.save(recording)
    for chunk in recording.chunks {
        try writeCloudFixture(store.audioURL(recording: recording.id, fileName: chunk.fileName), values: [chunk.id == silent.id ? 0 : 0.01])
    }
    let attempts = CloudAttempts()
    let failedID = second.id
    let factory: TranscriptionCoordinator.CloudFactory = { _ in FixtureCloud(attempts: attempts, failChunk: failedID) }
    let local: TranscriptionCoordinator.Recognize = { _, chunk, _ in
        [TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource, start: chunk.offset, end: chunk.end, text: "local")]
    }
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: local, cloudFactory: factory)
    coordinator.submit(recording, store: store)
    await coordinator.wait(for: recording.id)
    let partial = try #require(coordinator.documents[recording.id])
    #expect(partial.cloud?.status == "failed")
    #expect(partial.segments.first { $0.chunkID == first.id }?.text == "cloud")
    #expect(partial.segments.first { $0.chunkID == second.id }?.text == "local")
    #expect(partial.cloud?.jobs[second.id.uuidString]?.checkpoint?.taskID == second.id.uuidString)
    let reopened = TranscriptionCoordinator(prepare: { _ in throw MeetingError.message("must not redo local work") },
        recognize: local, cloudFactory: factory)
    reopened.load(recording)
    reopened.submit(recording, store: store, retry: true)
    await reopened.wait(for: recording.id)
    let finished = try #require(reopened.documents[recording.id])
    #expect(finished.cloud?.status == "completed")
    #expect(finished.cloud?.completedCount == 3)
    #expect(finished.cloud?.skippedSeconds == 1)
    #expect(finished.segments.count == 2)
    #expect(finished.segments.allSatisfy { $0.text == "cloud" })
    #expect(finished.segments.first?.start == 5.1)
    #expect(finished.segments.last?.source == .microphone)
    let requests = await attempts.requests
    #expect(requests.filter { $0.chunk.id == first.id }.count == 1)
    #expect(requests.last?.checkpoint?.taskID == second.id.uuidString)
    #expect(!requests.contains { $0.chunk.id == silent.id })
    #expect(try TranscriptDocument.load(from: URL(fileURLWithPath: recording.transcriptPath!), recordingID: recording.id) == finished)
}

@Test @MainActor func corruptTranscriptCannotBeOverwrittenByCloudFallback() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CorruptCloud-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "fixture", applicationName: "fixture", bundleIdentifier: "fixture")
    let url = root.appendingPathComponent("corrupt.json")
    let original = Data("corrupt document: preserve me".utf8)
    try original.write(to: url)
    recording.transcriptPath = url.path; recording.cloudTranscription = .init(); recording.status = .completed
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, _, _ in [] }, cloudFactory: { _ in
        throw MeetingError.message("must not start cloud")
    })
    coordinator.load(recording)
    coordinator.submit(recording, store: store, retry: true)
    await coordinator.wait(for: recording.id)
    #expect(try Data(contentsOf: url) == original)
    #expect(coordinator.documents[recording.id]?.status == "failed")
    #expect(coordinator.documents[recording.id]?.cloud == nil)
}

private actor CloudPauseGate {
    var entered = false
    func hold() async throws {
        entered = true
        try await Task.sleep(for: .seconds(30))
    }
}
private struct PausingCloud: TranscriptionProvider {
    let id = TranscriptionProviderID.qwen
    let engine = "Fixture cloud"
    let gate: CloudPauseGate
    func prepare(locale: String) async throws -> String { locale }
    func transcribe(_ request: TranscriptionRequest, checkpoint: @escaping TranscriptionCheckpointHandler) async throws -> ProviderTranscription {
        try await checkpoint(.init(phase: .submitted, taskID: "durable-before-pause"))
        try await gate.hold()
        return ProviderTranscription(segments: [])
    }
}

@Test @MainActor func cloudPausePreservesAcceptedTaskAndLocalSubtitles() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudPause-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "fixture", applicationName: "fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcript.json").path
    recording.cloudTranscription = .init(); recording.status = .completed
    let chunk = fixtureChunk(); recording.chunks = [chunk]
    try store.save(recording)
    try writeCloudFixture(store.audioURL(recording: recording.id, fileName: chunk.fileName), values: [0.1])
    let gate = CloudPauseGate()
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, chunk, _ in
        [TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource, start: chunk.offset, end: chunk.end, text: "local")]
    }, cloudFactory: { _ in PausingCloud(gate: gate) })
    coordinator.submit(recording, store: store)
    for _ in 0..<1000 {
        if await gate.entered { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(await gate.entered)
    coordinator.pause(recording.id)
    await coordinator.wait(for: recording.id)
    let doc = try TranscriptDocument.load(from: URL(fileURLWithPath: recording.transcriptPath!), recordingID: recording.id)
    #expect(doc.cloud?.status == "interrupted")
    #expect(doc.cloud?.jobs[chunk.id.uuidString]?.checkpoint?.taskID == "durable-before-pause")
    #expect(doc.segments.first?.text == "local")
    #expect(!coordinator.running.contains(recording.id))
}

@Test func stereoPreparationPreservesContentFromBothChannels() async throws {
    let original = FileManager.default.temporaryDirectory.appendingPathComponent("StereoCloud-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: original) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<48000 {
        buffer.floatChannelData![0][frame] = frame < 24000 ? 0.1 * sin(Float(frame) * 0.06) : 0
        buffer.floatChannelData![1][frame] = frame >= 24000 ? 0.1 * sin(Float(frame) * 0.06) : 0
    }
    do { let file = try AVAudioFile(forWriting: original, settings: format.settings); try file.write(from: buffer) }
    let originalBytes = try Data(contentsOf: original)
    let prepared = try await CloudAudioPreparation.prepare(url: original, skipSilence: true)
    let url = try #require(prepared.url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(forReading: url)
    let result = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: UInt32(file.length))!
    try file.read(into: result)
    for range in [1000..<7000, 9000..<15000] {
        #expect(range.contains { abs(result.floatChannelData![0][$0]) > 0.02 })
    }
    #expect(try Data(contentsOf: original) == originalBytes)
}

@Test func timeoutDuringPaidSubmissionPersistsAmbiguityAndBlocksAutomaticRepost() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SubmitTimeout-\(UUID()).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    try writeCloudFixture(url, values: [0.1])
    let http = ScriptedHTTP([.init(body: uploadPolicy), .init(), .init(networkFailure: true)])
    let saved = Checkpoints()
    let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "fixture", transport: http, pollWait: { _ in })
    await #expect(throws: URLError.self) {
        _ = try await provider.transcribe(.init(audioURL: url, chunk: fixtureChunk(), locale: "zh-CN")) { await saved.add($0) }
    }
    #expect(await saved.values.map(\.phase) == [.submitting])
    let checkpoint = await saved.values.last
    await #expect(throws: MeetingError.self) {
        _ = try await provider.transcribe(.init(audioURL: url, chunk: fixtureChunk(), locale: "zh-CN", checkpoint: checkpoint)) { await saved.add($0) }
    }
    #expect(await http.requests.count == 3)
}

private actor CloudOptInGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Test(arguments: [false, true]) @MainActor
func localOnlyRecordingCanAddCloudAfterRecordingWithoutRepeatingLocalWork(whileLocalIsRunning: Bool) async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudOptIn-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "Local first", applicationName: "Fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcript.json").path
    recording.status = .completed
    let chunk = fixtureChunk(source: .microphone, offset: 15)
    recording.chunks = [chunk]
    try store.save(recording)
    try writeCloudFixture(store.audioURL(recording: recording.id, fileName: chunk.fileName), values: [0.1])
    let gate = CloudOptInGate()
    let localAttempts = CloudAttempts()
    let cloudAttempts = CloudAttempts()
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { url, chunk, locale in
        _ = await localAttempts.record(.init(audioURL: url, chunk: chunk, locale: locale))
        if whileLocalIsRunning { await gate.hold() }
        return [TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource, start: chunk.offset, end: chunk.end, text: "local")]
    }, cloudFactory: { _ in FixtureCloud(attempts: cloudAttempts) })
    coordinator.submit(recording, store: store)
    if whileLocalIsRunning {
        for _ in 0..<1000 {
            if await gate.entered { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await gate.entered)
    } else {
        await coordinator.wait(for: recording.id)
        #expect(coordinator.documents[recording.id]?.status == "completed")
        #expect(coordinator.documents[recording.id]?.segments.first?.text == "local")
    }
    #expect(await cloudAttempts.requests.isEmpty)
    #expect(coordinator.documents[recording.id]?.cloud == nil)
    // Opt in for this existing recording independently of its original local-only choice.
    recording.cloudTranscription = .init()
    try store.save(recording)
    coordinator.submit(recording, store: store, retry: true)
    if whileLocalIsRunning { await gate.release() }
    await coordinator.wait(for: recording.id)
    #expect(coordinator.documents[recording.id]?.cloud?.status == "completed")
    #expect(coordinator.documents[recording.id]?.segments.first?.text == "cloud")
    #expect(coordinator.documents[recording.id]?.segments.first?.start == 15.1)
    #expect(coordinator.documents[recording.id]?.segments.first?.source == .microphone)
    #expect(await localAttempts.requests.count == 1)
    #expect(await cloudAttempts.requests.count == 1)
    #expect(try store.loadAll().first?.cloudTranscription != nil)
}

@Test func qwenNoWordsIsTerminalAndNeverResubmitsPaidTask() async throws {
    for body in [
        #"{"output":{"task_status":"FAILED","code":"ASR_RESPONSE_HAVE_NO_WORDS","message":"ASR_RESPONSE_HAVE_NO_WORDS"}}"#,
        #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"FAILED","code":"ASR_RESPONSE_HAVE_NO_WORDS"}]},"usage":{"input_tokens":7}}"#,
        #"{"output":{"task_status":"FAILED","results":[{"subtask_status":"FAILED","code":"ASR_RESPONSE_HAVE_NO_WORDS"}]}}"#,
        #"{"output":{"task_status":"FAILED","code":"SUCCESS_WITH_NO_VALID_FRAGMENT"}}"#,
        #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"FAILED","code":"SUCCESS_WITH_NO_VALID_FRAGMENT"}]}}"#
    ] {
        let http = ScriptedHTTP([.init(body: body)])
        let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "fixture", transport: http, pollWait: { _ in })
        let result = try await provider.transcribe(.init(audioURL: URL(fileURLWithPath: "/missing.wav"),
            chunk: fixtureChunk(source: .microphone), locale: "zh-CN",
            checkpoint: .init(phase: .submitted, taskID: "already-paid")), checkpoint: { _ in Issue.record("must not resubmit") })
        #expect(result.noSpeechRecognized)
        #expect(result.segments.isEmpty)
        #expect(await http.requests.count == 1)
        #expect(await http.requests.first?.url?.path == "/api/v1/tasks/already-paid")
    }
}

@Test func qwenOtherFailuresRemainErrorsWithSafeMachineCodes() async throws {
    for code in ["FILE_DOWNLOAD_FAILED", "InvalidParameter", "https://example.com/secret?token=private"] {
        let data = try JSONSerialization.data(withJSONObject: ["output": ["task_status": "FAILED", "code": code,
            "message": "Bearer private-key https://example.com/signed?secret=value"]])
        let http = ScriptedHTTP([.init(body: String(decoding: data, as: UTF8.self))])
        let provider = QwenTranscriptionProvider(configuration: .init(), apiKey: "private-key", transport: http)
        do {
            _ = try await provider.transcribe(.init(audioURL: URL(fileURLWithPath: "/missing.wav"), chunk: fixtureChunk(),
                locale: "zh-CN", checkpoint: .init(phase: .submitted, taskID: "failed")), checkpoint: { _ in })
            Issue.record("failure must not be treated as no speech")
        } catch {
            #expect(!error.localizedDescription.contains("private"))
            #expect(!error.localizedDescription.contains("https://"))
            if !code.contains(":") { #expect(error.localizedDescription.contains(code)) }
        }
        #expect(await http.requests.count == 1)
    }
}

@Test @MainActor func cloudResumesOldNoWordsFailurePreservesLocalAndProcessesFollowingChunks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoWords-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RecordingStore(root: root)
    var recording = Recording(title: "fixture", applicationName: "fixture", bundleIdentifier: "fixture")
    recording.transcriptPath = root.appendingPathComponent("transcript.json").path
    recording.cloudTranscription = .init(); recording.status = .completed
    var first = fixtureChunk(source: .microphone, offset: 0); first.fileName = "first.wav"
    var second = fixtureChunk(offset: 10); second.fileName = "second.wav"
    recording.chunks = [first, second]
    try store.save(recording)
    var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    for chunk in recording.chunks {
        try document.commit([TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource,
            start: chunk.offset, end: chunk.end, text: "local fallback")], for: chunk)
    }
    document.status = "completed"
    var progress = CloudTranscriptionProgress(configuration: .init())
    progress.status = "failed"; progress.error = "legacy FAILED"
    for (chunk, task) in [(first, "no-words"), (second, "following")] {
        var job = CloudChunkJob(); job.checkpoint = .init(phase: .submitted, taskID: task)
        progress.jobs[chunk.id.uuidString] = job
    }
    document.cloud = progress
    try document.save(to: URL(fileURLWithPath: recording.transcriptPath!))
    // Existing jobs are query-only: no fixture audio files or upload replies are needed.
    let http = ScriptedHTTP([
        .init(body: #"{"output":{"task_status":"FAILED","code":"SUCCESS_WITH_NO_VALID_FRAGMENT"}}"#),
        .init(body: #"{"output":{"task_status":"SUCCEEDED","results":[{"subtask_status":"SUCCEEDED","transcription_url":"https://result.oss-cn-beijing.aliyuncs.com/result.json"}]}}"#),
        .init(body: cloudText)
    ])
    let factory: TranscriptionCoordinator.CloudFactory = { QwenTranscriptionProvider(configuration: $0, apiKey: "fixture", transport: http) }
    let coordinator = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, _, _ in Issue.record("must not redo local work"); return [] }, cloudFactory: factory)
    coordinator.load(recording)
    coordinator.submit(recording, store: store, retry: true)
    await coordinator.wait(for: recording.id)
    let done = try #require(coordinator.documents[recording.id])
    #expect(done.cloud?.status == "completed")
    #expect(done.cloud?.error == nil)
    #expect(done.cloud?.noSpeechCount == 1)
    #expect(done.cloud?.completedCount == 2)
    #expect(done.cloud?.skippedSeconds == 0)
    #expect(done.segments.first { $0.chunkID == first.id }?.text == "local fallback")
    #expect(done.segments.first { $0.chunkID == second.id }?.text == "云端文字")
    // Missing token counts stay unknown even when the result carries model/date metadata.
    #expect(done.cloud?.jobs[first.id.uuidString]?.usage?.inputTokens == nil)
    #expect(done.cloud?.jobs[first.id.uuidString]?.usage?.outputTokens == nil)
    #expect(done.cloud?.jobs[first.id.uuidString]?.usage?.keyID == nil)
    #expect(await http.requests.count == 3)
    let reopened = TranscriptionCoordinator(prepare: { $0 }, recognize: { _, _, _ in [] }, cloudFactory: factory)
    reopened.load(recording)
    reopened.submit(recording, store: store, retry: true)
    await reopened.wait(for: recording.id)
    #expect(await http.requests.count == 3)
    #expect(reopened.documents[recording.id]?.cloud?.noSpeechCount == 1)
}

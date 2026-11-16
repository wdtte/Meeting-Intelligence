import Foundation
import Security
import Testing
@testable import MeetingCore

private actor SummaryFixtureProvider: SummaryProvider {
    nonisolated let id = SummaryProviderID.openAICompatible
    var requests: [SummaryRequest] = []
    var failures: Int
    var delayed: Bool
    var gated = false
    private var gate: CheckedContinuation<Void, Never>?
    init(failures: Int = 0, delayed: Bool = false) { self.failures = failures; self.delayed = delayed }
    func holdResult() { gated = true }
    func releaseResult() { gated = false; gate?.resume(); gate = nil }
    func summarize(_ request: SummaryRequest) async throws -> ProviderSummary {
        requests.append(request)
        if gated { await withCheckedContinuation { gate = $0 } }
        if delayed { try await Task.sleep(for: .seconds(30)) }
        if failures > 0 { failures -= 1; throw MeetingError.message("fixture summary failure") }
        return ProviderSummary(text: "结论：已确认。\n待办：周五发布。", model: "fixture-model")
    }
}

private struct SummaryFixture {
    let root: URL
    let store: RecordingStore
    var recording: Recording
    var document: TranscriptDocument
    var url: URL { URL(fileURLWithPath: recording.transcriptPath!) }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SummaryTests-\(UUID())")
        store = try RecordingStore(root: root)
        recording = Recording(title: "摘要测试", applicationName: "Fixture", bundleIdentifier: "fixture")
        recording.status = .completed
        recording.transcriptPath = root.appendingPathComponent("transcript.json").path
        recording.chunks = [AudioChunk(fileName: "fixture.wav", offset: 0, duration: 1, sampleRate: 16000, channels: 1, isComplete: true)]
        document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
        document.status = "completed"
        try document.commit([TranscriptSegment(chunkID: recording.chunks[0].id, source: .application, start: 0, end: 1, text: "周五发布，负责人未指定。")], for: recording.chunks[0])
        try document.save(to: URL(fileURLWithPath: recording.transcriptPath!))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
}
@MainActor private func summaryCoordinator(_ provider: SummaryFixtureProvider) -> TranscriptionCoordinator {
    TranscriptionCoordinator(prepare: { $0 }, recognize: { _, _, _ in
        throw MeetingError.message("saved chunks must not be transcribed again")
    }, summaryFactory: { provider })
}

@Test func summaryConfigurationAndKeychainKeepSecretsSeparate() throws {
    #expect(SummaryConfiguration(model: " deepseek-chat ").model == "deepseek-chat")
    for model in ["", "   ", "a\nb", String(repeating: "x", count: 257)] {
        #expect(throws: MeetingError.self) { try SummaryConfiguration(model: model).validate() }
    }
    for value in ["https://api.openai.com/v1", "http://localhost:8080/v1", "http://127.0.0.1:1234/v1", "http://[::1]:8080/v1"] {
        try SummaryConfiguration(baseURL: value).validate()
    }
    for value in ["file:///tmp/key", "http://remote.test/v1", "https://user:key@remote.test/v1", "https://remote.test/v1?key=secret", "https://remote.test/v1#x", ""] {
        #expect(throws: MeetingError.self) { try SummaryConfiguration(baseURL: value).validate() }
    }
    let silent = SummaryCredentials.readQuery()
    #expect(silent[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
    #expect(silent[kSecAttrService as String] as? String == "Meeting Intelligence.Summary")
    #expect(silent[kSecAttrAccount as String] as? String == "openai-compatible")
    #expect(SummaryCredentials.readQuery(allowInteraction: true)[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String)
}

@Test func legacyTranscriptsRemainReadableAndSummaryFingerprintSurvivesPersistence() throws {
    var fixture = try SummaryFixture(); defer { fixture.clean() }
    #expect(try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id).summary == nil)
    fixture.document.summary = TranscriptSummary(inputFingerprint: fixture.document.summaryRequest.fingerprint)
    fixture.document.summary?.status = "completed"; fixture.document.summary?.text = "摘要"
    try fixture.document.save(to: fixture.url)
    let reopened = try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id)
    #expect(reopened.currentSummary?.text == "摘要")
    #expect(reopened.summaryRequest.fingerprint == fixture.document.summaryRequest.fingerprint)
    var edited = reopened.segments[0]; edited.text = "更新后的决定"
    try fixture.document.commit([edited], for: fixture.recording.chunks[0])
    #expect(fixture.document.summary == nil)
}

@Test @MainActor func summaryRunsOnceAfterLocalCompletionAndPersistsWithTranscript() async throws {
    let fixture = try SummaryFixture(); defer { fixture.clean() }
    let provider = SummaryFixtureProvider()
    let tested = summaryCoordinator(provider)
    tested.load(fixture.recording)
    tested.submit(fixture.recording, store: fixture.store)
    await tested.wait(for: fixture.recording.id)
    let document = try #require(tested.documents[fixture.recording.id])
    #expect(document.currentSummary?.text?.contains("周五发布") == true)
    #expect(document.segments == fixture.document.segments)
    #expect(try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id) == document)
    tested.submit(fixture.recording, store: fixture.store)
    await tested.wait(for: fixture.recording.id)
    #expect(await provider.requests.count == 1)
}

@Test @MainActor func summaryFailureDoesNotFailTranscriptionAndOnlyExplicitRetryResubmits() async throws {
    let fixture = try SummaryFixture(); defer { fixture.clean() }
    let provider = SummaryFixtureProvider(failures: 1), coordinator = summaryCoordinator(provider)
    coordinator.load(fixture.recording)
    coordinator.submit(fixture.recording, store: fixture.store)
    await coordinator.wait(for: fixture.recording.id)
    #expect(coordinator.documents[fixture.recording.id]?.status == "completed")
    #expect(coordinator.documents[fixture.recording.id]?.summary?.status == "failed")
    coordinator.submit(fixture.recording, store: fixture.store)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.count == 1)
    coordinator.generateSummary(fixture.recording)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.count == 2)
    #expect(coordinator.documents[fixture.recording.id]?.currentSummary != nil)
}

@Test @MainActor func summaryWaitsForRecordingAndCloudCompletion() async throws {
    var fixture = try SummaryFixture(); defer { fixture.clean() }
    let provider = SummaryFixtureProvider(), coordinator = summaryCoordinator(provider)
    coordinator.load(fixture.recording)
    fixture.recording.status = .recording
    coordinator.generateSummary(fixture.recording)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.isEmpty)
    fixture.recording.status = .completed
    fixture.recording.cloudTranscription = CloudTranscriptionConfiguration()
    coordinator.generateSummary(fixture.recording)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.isEmpty)
    fixture.document.cloud = CloudTranscriptionProgress(configuration: fixture.recording.cloudTranscription!)
    fixture.document.cloud?.status = "completed"
    fixture.document.segments[0].text = "云端精校后的最终结论"
    try fixture.document.save(to: fixture.url)
    coordinator.load(fixture.recording)
    coordinator.submit(fixture.recording, store: fixture.store)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.first?.text.contains("云端精校后的最终结论") == true)
}

@Test @MainActor func cancelledSummaryCanRetryAfterRestartAndDeletionWaitsForIt() async throws {
    var fixture = try SummaryFixture(); defer { fixture.clean() }
    fixture.document.summary = TranscriptSummary(inputFingerprint: fixture.document.summaryRequest.fingerprint)
    fixture.document.summary?.status = "running"
    try fixture.document.save(to: fixture.url)
    let provider = SummaryFixtureProvider(delayed: true), coordinator = summaryCoordinator(provider)
    coordinator.load(fixture.recording)
    #expect(coordinator.documents[fixture.recording.id]?.summary?.status == "interrupted")
    coordinator.generateSummary(fixture.recording)
    while await provider.requests.isEmpty { await Task.yield() }
    #expect(coordinator.summaryRunning.contains(fixture.recording.id))
    await coordinator.stopAndForget(fixture.recording.id)
    #expect(coordinator.documents[fixture.recording.id] == nil)
    #expect(!coordinator.summaryRunning.contains(fixture.recording.id))
    let saved = try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id)
    #expect(saved.status == "completed")
    #expect(saved.summary?.status == "interrupted")
    #expect(saved.segments == fixture.document.segments)
}

@Test @MainActor func summaryNeverOverwritesCorruptOrExternallyChangedTranscript() async throws {
    let fixture = try SummaryFixture(); defer { fixture.clean() }
    let provider = SummaryFixtureProvider(), coordinator = summaryCoordinator(provider)
    coordinator.load(fixture.recording)
    let corrupt = Data("do not overwrite".utf8)
    try corrupt.write(to: fixture.url)
    coordinator.generateSummary(fixture.recording)
    await coordinator.wait(for: fixture.recording.id)
    #expect(await provider.requests.isEmpty)
    #expect(try Data(contentsOf: fixture.url) == corrupt)
}

@Test @MainActor func failedRegenerationPreservesPreviousSuccessfulSummaryAndExportNotice() async throws {
    var fixture = try SummaryFixture(); defer { fixture.clean() }
    fixture.document.summary = TranscriptSummary(inputFingerprint: fixture.document.summaryRequest.fingerprint)
    fixture.document.summary?.status = "completed"
    fixture.document.summary?.text = "上次成功摘要"
    fixture.document.summary?.model = "previous-model"
    fixture.document.summary?.generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try fixture.document.save(to: fixture.url)
    let provider = SummaryFixtureProvider(failures: 1), coordinator = summaryCoordinator(provider)
    coordinator.load(fixture.recording)
    coordinator.generateSummary(fixture.recording)
    await coordinator.wait(for: fixture.recording.id)
    let saved = try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id)
    #expect(saved.summaryState == "failed")
    #expect(saved.currentSummary?.text == "上次成功摘要")
    #expect(saved.currentSummary?.model == "previous-model")
    #expect(saved.currentSummary?.generatedAt == fixture.document.summary?.generatedAt)
    #expect(saved.summaryExportNotice?.contains("保留上次成功摘要") == true)
}

@Test @MainActor func inFlightSummaryNeverOverwritesExternallyEditedTranscript() async throws {
    let fixture = try SummaryFixture(); defer { fixture.clean() }
    let provider = SummaryFixtureProvider(), coordinator = summaryCoordinator(provider)
    await provider.holdResult()
    coordinator.load(fixture.recording)
    coordinator.generateSummary(fixture.recording)
    while await provider.requests.isEmpty { await Task.yield() }
    var edited = try TranscriptDocument.load(from: fixture.url, recordingID: fixture.recording.id)
    edited.segments[0].text = "外部编辑后的新决定"
    try edited.save(to: fixture.url)
    let editedBytes = try Data(contentsOf: fixture.url)
    await provider.releaseResult()
    await coordinator.wait(for: fixture.recording.id)
    #expect(try Data(contentsOf: fixture.url) == editedBytes)
    #expect(!coordinator.summaryRunning.contains(fixture.recording.id))
    #expect(coordinator.documents[fixture.recording.id]?.summary?.error?.contains("已更改") == true)
    coordinator.load(fixture.recording)
    #expect(coordinator.documents[fixture.recording.id]?.segments[0].text == "外部编辑后的新决定")
    #expect(coordinator.documents[fixture.recording.id]?.currentSummary == nil)
}

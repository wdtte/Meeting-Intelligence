import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingIntelligence

@Test @MainActor func unifiedImportRestoresHTMLWithoutCloudConfigurationAndSelectsIt() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("HTMLAppImport-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let settingsStore = try StorageSettingsStore(base: root)
    let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/legacy-meeting-0.3.0.html")
    let model = AppModel(settingsStore: settingsStore, startBackgroundServices: false)
    model.importURL = fixture
    model.importPreview = try await MeetingHTMLImporter.inspect(fixture)
    model.startAudioImport()
    for _ in 0..<500 {
        if model.importProgress == nil { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.importProgress == nil && model.errorMessage == nil)
    let recording = try #require(model.selectedRecording)
    #expect(recording.title == "合成历史导出" && recording.cloudTranscription == nil)
    #expect(!model.modelPreparing && model.transcription.running.isEmpty && model.transcription.summaryRunning.isEmpty)
    #expect(model.transcription.documents[recording.id]?.segments.first?.text == "合成字幕 <示例>。\n保留换行。")
    #expect(model.transcription.documents[recording.id]?.currentSummary?.model == "synthetic-model")
    let manifest = try Data(contentsOf: settingsStore.load().audioDirectory.appendingPathComponent(recording.id.uuidString).appendingPathComponent("recording.json"))
    let transcript = try Data(contentsOf: URL(fileURLWithPath: recording.transcriptPath!))
    try model.reload(); model.select(recording.id)
    #expect(try Data(contentsOf: settingsStore.load().audioDirectory.appendingPathComponent(recording.id.uuidString).appendingPathComponent("recording.json")) == manifest)
    #expect(try Data(contentsOf: URL(fileURLWithPath: recording.transcriptPath!)) == transcript)
}

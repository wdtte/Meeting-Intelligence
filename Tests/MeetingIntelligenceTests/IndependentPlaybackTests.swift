import AVFoundation
import Foundation
import Testing
@testable import MeetingCore
@testable import MeetingIntelligence

@MainActor private struct PlaybackFixture {
    let root: URL
    let model: AppModel
    let records: [Recording]

    init(count: Int = 2) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("IndependentPlayback-\(UUID())")
        let settingsStore = try StorageSettingsStore(base: root)
        let settings = try settingsStore.load()
        let store = try RecordingStore(root: settings.audioDirectory)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        var records: [Recording] = []
        for index in 0..<count {
            var recording = Recording(title: "Record \(index)", applicationName: "Fixture", bundleIdentifier: "fixture")
            recording.status = .completed
            recording.transcriptPath = settings.transcriptDirectory.appendingPathComponent("\(recording.id).json").path
            let chunk = AudioChunk(fileName: "fixture.wav", offset: 0, duration: 4, sampleRate: 48000, channels: 1, isComplete: true)
            recording.chunks = [chunk]
            try store.save(recording)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
            buffer.frameLength = buffer.frameCapacity
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
            let file = try AVAudioFile(forWriting: store.audioURL(recording: recording.id, fileName: chunk.fileName), settings: format.settings)
            try file.write(from: buffer)
            var document = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
            let starts = index == 0 ? [0.0, 1, 2] : [0.0, 1.5, 3]
            try document.commit(starts.map {
                TranscriptSegment(chunkID: chunk.id, source: .application, start: $0, end: $0 + 0.5, text: "Fixture")
            }, for: chunk)
            document.status = "completed"
            try document.save(to: URL(fileURLWithPath: recording.transcriptPath!))
            records.append(recording)
        }
        self.records = records
        model = AppModel(settingsStore: settingsStore, startBackgroundServices: false)
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        model.playback = PlaybackCoordinator(engine: engine)
    }
    func clean() { model.playback.load(nil, store: nil); try? FileManager.default.removeItem(at: root) }
}

@Test @MainActor func upDownBrowseInSidebarOrderWithoutStartingOrSwitchingPlayback() throws {
    let fixture = try PlaybackFixture(count: 3)
    defer { fixture.clean() }
    let model = fixture.model, records = model.recordings
    #expect(!model.navigateRecording(.next))
    model.select(records[0].id)
    #expect(model.navigateRecording(.previous))
    #expect(model.selectedID == records[0].id)
    #expect(model.navigateRecording(.next))
    #expect(model.selectedID == records[1].id)
    #expect(model.playback.recordingID == nil)
    #expect(!model.playback.isPlaying)
    model.toggleRecordingPlayback(records[1].id)
    model.playback.seek(to: 1)
    #expect(model.navigateRecording(.next))
    #expect(model.selectedID == records[2].id)
    #expect(model.playback.recordingID == records[1].id)
    #expect(model.playback.isPlaying)
    #expect(model.playback.position == 1)
    #expect(model.navigateRecording(.next))
    #expect(model.selectedID == records[2].id)
    model.playback.pause()
    let position = model.playback.position
    #expect(model.navigateRecording(.previous))
    #expect(model.selectedID == records[1].id)
    #expect(model.navigateRecording(.previous))
    #expect(model.selectedID == records[0].id)
    #expect(model.playback.recordingID == records[1].id)
    #expect(!model.playback.isPlaying)
    #expect(model.playback.position == position)
    model.beginRename(records[0].id)
    #expect(!model.navigateRecording(.next))
    model.renamingRecordingID = nil
    model.showSettings()
    #expect(!model.navigateRecording(.next))
    model.select(records[0].id)
    model.state = .recording
    #expect(!model.navigateRecording(.next))
    model.state = .idle
    model.errorMessage = "Fixture error"
    #expect(!model.navigateRecording(.next))
    #expect(model.selectedID == records[0].id)
}

@Test @MainActor func browsingRecordsAndSettingsNeverReplacesOrPausesCurrentPlayback() throws {
    let fixture = try PlaybackFixture()
    defer { fixture.clean() }
    let model = fixture.model, first = fixture.records[0], second = fixture.records[1]
    #expect(!model.showsPlaybackBar)
    model.select(first.id)
    #expect(model.showsPlaybackBar)
    #expect(model.playback.recordingID == nil)
    #expect(!model.togglePlayback())
    model.toggleRecordingPlayback(first.id)
    #expect(model.playback.isPlaying)
    model.playback.seek(to: 1)
    model.select(second.id)
    #expect(model.showsPlaybackBar)
    #expect(model.selectedID == second.id)
    #expect(model.playbackRecording?.id == first.id)
    #expect(model.playback.isPlaying)
    #expect(model.playback.position == 1)
    model.showSettings()
    #expect(!model.showsPlaybackBar)
    #expect(model.playback.isPlaying)
    #expect(model.playbackRecording?.id == first.id)
    model.select(nil)
    #expect(!model.showsPlaybackBar)
    #expect(model.playbackRecording?.id == first.id)
    #expect(model.playback.isPlaying)
    #expect(model.togglePlayback())
    #expect(!model.playback.isPlaying)
    #expect(model.togglePlayback())
    #expect(model.playback.isPlaying)
    model.select(second.id)
    #expect(model.showsPlaybackBar)
    model.toggleRecordingPlayback(second.id)
    #expect(model.playbackRecording?.id == second.id)
    #expect(model.playback.isPlaying)
    #expect(model.playback.position == 0)
    model.playback.seek(to: 1.5)
    model.toggleRecordingPlayback(second.id)
    #expect(!model.playback.isPlaying)
    #expect(abs(model.playback.position - 1.5) < 0.1)
}

@Test @MainActor func subtitleClicksSwitchExplicitlyAndArrowsUsePlayingRecordsTranscript() throws {
    let fixture = try PlaybackFixture()
    defer { fixture.clean() }
    let model = fixture.model, first = fixture.records[0], second = fixture.records[1]
    model.select(first.id)
    model.toggleRecordingPlayback(first.id)
    model.select(second.id)
    let segment = try #require(model.transcription.documents[second.id]?.segments[1])
    model.playSegment(segment, recordingID: second.id)
    #expect(model.playback.recordingID == second.id)
    #expect(model.playback.position == 1.5)
    #expect(model.playback.isPlaying)
    model.playback.pause()
    model.select(first.id)
    #expect(model.navigateTranscript(.next))
    #expect(model.playback.recordingID == second.id)
    #expect(model.playback.position == 3)
    #expect(!model.playback.isPlaying)
    #expect(model.navigateTranscript(.previous))
    #expect(model.playback.position == 1.5)
    model.beginRename(first.id)
    #expect(!model.togglePlayback())
    #expect(!model.navigateTranscript(.next))
}

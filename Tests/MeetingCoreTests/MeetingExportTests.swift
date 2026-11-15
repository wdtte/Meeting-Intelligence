import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private func htmlFixture() throws -> (RecordingStore, Recording, TranscriptDocument) {
    let store = try RecordingStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("MeetingHTMLTests-\(UUID())"))
    var recording = Recording(title: "产品周会 · 录音与转写体验", applicationName: "腾讯会议", bundleIdentifier: "fixture")
    recording.status = .completed
    var transcript = TranscriptDocument(recordingID: recording.id, locale: "zh-CN")
    transcript.status = "completed"
    let lines = ["今天先确认导出页面的阅读体验，让每一次回顾都更轻松。", "音频和转写保存在同一个文件里，分享给同事后，用浏览器打开就能回听。",
                 "时间戳需要与原始录音对齐，停顿和静音也应该保留。", "我会检查应用声音与麦克风混合后的效果，以及不同采样率的情况。",
                 "搜索时可以直接输入关键词，播放时也能看到当前发言。", "最后确认手机上的阅读布局，整理测试结果，今天就按这个方向推进。"]
    transcript.segments = lines.enumerated().map { index, text in
        TranscriptSegment(chunkID: UUID(), source: index.isMultiple(of: 2) ? .application : .microphone,
                          start: Double(index * 2), end: Double(index * 2 + 2), text: text)
    }
    return (store, recording, transcript)
}

private func htmlFixtureAudio(recording: inout Recording, store: RecordingStore) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)!
    buffer.frameLength = buffer.frameCapacity
    for frame in 0..<Int(buffer.frameLength) {
        buffer.floatChannelData![0][frame] = frame < 16_000 ? 0 : 0.15 * Float(sin(2 * .pi * 440 * Double(frame) / 16000))
    }
    try FileManager.default.createDirectory(at: store.directory(for: recording.id), withIntermediateDirectories: true)
    let file = try AVAudioFile(forWriting: store.audioURL(recording: recording.id, fileName: "0.wav"), settings: format.settings)
    try file.write(from: buffer)
    recording.chunks = [AudioChunk(fileName: "0.wav", offset: 0, duration: 12, sampleRate: 16000, channels: 1, isComplete: true)]
}

@Test func htmlTranscriptExportEscapesContentAndWorksWithoutAudio() async throws {
    var (store, recording, transcript) = try htmlFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    recording.title = "Review {{SEGMENTS}} & <agenda>"
    transcript.status = "running"
    let injected = "</script><script>window.exportInjected = true</script><img src=x onerror=alert(1)> & \"quoted\""
    transcript.segments[0].text = injected
    transcript.segments[0].engine = "Qwen & <custom>"
    let destination = store.root.appendingPathComponent("transcript.html")
    try Data("previous export".utf8).write(to: destination)
    try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcript, to: destination)
    let html = try String(contentsOf: destination, encoding: .utf8)
    #expect(html.contains("Review {{SEGMENTS}} &amp; &lt;agenda&gt;"))
    #expect(html.contains(TranscriptHTMLWriter.escape(injected)))
    #expect(!html.contains(injected))
    #expect(!html.contains("<audio "))
    #expect(!html.contains("data:audio/mp4;base64,"))
    #expect(html.contains("转写尚未全部完成"))
    #expect(html.contains("系统音频") && html.contains("麦克风"))
    #expect(html.contains("Qwen &amp; &lt;custom&gt;") && html.contains("Apple SpeechTranscriber"))
    #expect(html.contains("00:10"))
    #expect(!html.contains(store.root.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
}

@Test func htmlExportEmbedsPlayableAudioAndCanBeMovedAlone() async throws {
    var (store, recording, transcript) = try htmlFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try htmlFixtureAudio(recording: &recording, store: store)
    let destination = store.root.appendingPathComponent("meeting.html")
    try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcriptAndAudio, to: destination)
    let html = try String(contentsOf: destination, encoding: .utf8)
    let marker = try #require(html.range(of: "data:audio/mp4;base64,"))
    let end = try #require(html[marker.upperBound...].firstIndex(of: "\""))
    let audio = try #require(Data(base64Encoded: String(html[marker.upperBound..<end])))
    let extracted = store.root.appendingPathComponent("extracted.m4a")
    try audio.write(to: extracted)
    let duration = try await AVURLAsset(url: extracted).load(.duration)
    #expect(abs(duration.seconds - 12) < 0.03)
    #expect(!html.contains(store.root.path))
    #expect(!html.contains("{{NONCE}}"))
    #expect(html.contains("data-start=\"10.0\""))
    #expect(html.contains("<button class=\"timestamp\""))
    #expect(html.contains("href=\"#clock\"/></svg>00:12"))
    let waveform = try #require(html.range(of: "data-peaks=\""))
    let waveformEnd = try #require(html[waveform.upperBound...].firstIndex(of: "\""))
    let peaks = html[waveform.upperBound..<waveformEnd].split(separator: ",").compactMap { UInt8($0) }
    #expect(peaks.count == 384)
    #expect(peaks.prefix(25).allSatisfy { $0 == 0 })
    #expect(peaks.dropFirst(45).contains { $0 > 25 })
    #expect(html.contains("media-src data:"))
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
    if let previewPath = ProcessInfo.processInfo.environment["MI_EXPORT_PREVIEW_DIR"] {
        let preview = URL(fileURLWithPath: previewPath, isDirectory: true)
        try FileManager.default.createDirectory(at: preview, withIntermediateDirectories: true)
        try Data(html.utf8).write(to: preview.appendingPathComponent("meeting.html"))
        transcript.segments[1].text = "安全测试：<img src=x onerror=\"window.exportInjected=true\"> {{NONCE}} & <script>alert(1)</script>"
        try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcript,
                                         to: preview.appendingPathComponent("transcript.html"))
    }
}

@Test func htmlExportValidatesSnapshotAndKeepsDestinationOnFailure() async throws {
    var (store, recording, transcript) = try htmlFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    let destination = store.root.appendingPathComponent("keep.html")
    let original = Data("keep existing export".utf8)
    try original.write(to: destination)
    transcript.recordingID = UUID()
    await #expect(throws: MeetingError.self) { try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcript, to: destination) }
    transcript.recordingID = recording.id
    transcript.segments[0].start = .infinity
    await #expect(throws: MeetingError.self) { try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcript, to: destination) }
    transcript.segments[0].start = 0
    recording.chunks = [AudioChunk(fileName: "missing.wav", offset: 0, duration: 1, sampleRate: 16000, channels: 1, isComplete: true)]
    await #expect(throws: (any Error).self) { try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcriptAndAudio, to: destination) }
    let cancelled = Task { [store, recording, transcript] in
        withUnsafeCurrentTask { $0?.cancel() }
        try await MeetingExporter.export(recording, transcript: transcript, store: store, kind: .transcript, to: destination)
    }
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try Data(contentsOf: destination) == original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy { !$0.hasPrefix(".meeting-export-") })
}

@Test func audioOnlyExportNeedsNoTranscript() async throws {
    var (store, recording, _) = try htmlFixture()
    defer { try? FileManager.default.removeItem(at: store.root) }
    try htmlFixtureAudio(recording: &recording, store: store)
    let destination = store.root.appendingPathComponent("audio.m4a")
    try await MeetingExporter.export(recording, transcript: nil, store: store, kind: .audio, to: destination)
    let duration = try await AVURLAsset(url: destination).load(.duration)
    #expect(abs(duration.seconds - 12) < 0.03)
}

@Test(arguments: [0, 1, 2, 3, 65535, 65536, 65537, 200000])
func streamedBase64PreservesBytesAcrossReadBoundaries(count: Int) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("Base64Tests-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let input = root.appendingPathComponent("input.bin"), output = root.appendingPathComponent("output.txt")
    let bytes = Data((0..<count).map { UInt8($0 % 251) })
    try bytes.write(to: input)
    try Data().write(to: output)
    let handle = try FileHandle(forWritingTo: output)
    try TranscriptHTMLWriter.writeBase64(input, to: handle)
    try handle.close()
    let encoded = try String(contentsOf: output, encoding: .utf8)
    #expect(Data(base64Encoded: encoded) == bytes)
}

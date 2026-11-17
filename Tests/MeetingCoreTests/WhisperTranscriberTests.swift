#if MEETING_WHISPER
import AVFoundation
import Foundation
import Testing
@testable import MeetingCore

private struct WhisperFixture {
    let root: URL
    let audio: URL
    let assets: WhisperAssets
    let chunk: AudioChunk

    init(_ body: String = "exit 7", silent: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Whisper fixture \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("mock whisper")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let model = root.appendingPathComponent("mock model.bin")
        try Data("not a real model".utf8).write(to: model)
        assets = WhisperAssets(executable: executable, model: model)
        audio = root.appendingPathComponent("audio with spaces.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24000)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = silent ? 0 : 0.1 * sin(Float(frame) / 20)
            }
        }
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
        chunk = AudioChunk(source: .microphone, fileName: audio.lastPathComponent, offset: 12, duration: 0.5,
                           sampleRate: 48000, channels: 2, isComplete: true)
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite(.serialized) struct WhisperTranscriberTests {
    @Test func timestampsUseMillisecondsAndKeepTrackAndChunkOffset() throws {
        let fixture = try WhisperFixture()
        defer { fixture.remove() }
        let data = Data(#"{"transcription":[{"offsets":{"from":100,"to":900},"text":" 你好 "}]}"#.utf8)
        let segments = try WhisperTranscriber.decode(data, chunk: fixture.chunk)
        #expect(segments.count == 1)
        #expect(segments[0].start == 12.1)
        #expect(segments[0].end == 12.5)
        #expect(segments[0].source == .microphone)
        #expect(segments[0].chunkID == fixture.chunk.id)
        #expect(segments[0].text == "你好")
        #expect(segments[0].engine == "Whisper base (q5_1)")
        var document = TranscriptDocument(recordingID: UUID(), locale: "zh-CN")
        try document.commit(segments, for: fixture.chunk)
        #expect(document.engine == "Whisper base (q5_1)")
    }

    @Test func invalidResultsNeverBecomeProcessedChunks() throws {
        let fixture = try WhisperFixture()
        defer { fixture.remove() }
        for json in ["{}", #"{"transcription":[{"offsets":{"from":-1,"to":100},"text":"bad"}]}"#,
                     #"{"transcription":[{"offsets":{"from":200,"to":100},"text":"bad"}]}"#] {
            #expect(throws: (any Error).self) { try WhisperTranscriber.decode(Data(json.utf8), chunk: fixture.chunk) }
        }
        let empty = try WhisperTranscriber.decode(Data(#"{"transcription":[]}"#.utf8), chunk: fixture.chunk)
        #expect(empty.isEmpty)
        #expect(try WhisperTranscriber.language("zh-CN") == "zh")
        #expect(try WhisperTranscriber.language("en_US") == "en")
        #expect(throws: (any Error).self) { try WhisperTranscriber.language("fr-FR") }
    }

    @Test func chineseResultsMatchSimplifiedChineseSetting() throws {
        let fixture = try WhisperFixture()
        defer { fixture.remove() }
        let data = Data(#"{"transcription":[{"offsets":{"from":0,"to":400},"text":"會議討論項目計畫"}]}"#.utf8)
        let segments = try WhisperTranscriber.decode(data, chunk: fixture.chunk, language: "zh")
        #expect(segments.map(\.text) == ["会议讨论项目计划"])
    }

    @Test func missingOrCorruptBundledModelFailsPreparation() throws {
        let fixture = try WhisperFixture()
        defer { fixture.remove() }
        #expect(throws: (any Error).self) { try fixture.assets.validate() }
        try FileManager.default.removeItem(at: fixture.assets.model)
        #expect(throws: (any Error).self) { try fixture.assets.validate() }
    }

    @Test func invokesHelperWithoutShellAndReadsJsonFile() async throws {
        let fixture = try WhisperFixture("""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--output-file' ]; then shift; output="$1"; fi
          shift
        done
        printf '%s' '{"transcription":[{"offsets":{"from":0,"to":400},"text":"hello"}]}' > "$output.json"
        """)
        defer { fixture.remove() }
        let segments = try await WhisperTranscriber.transcribe(url: fixture.audio, chunk: fixture.chunk,
            locale: "en-US", assets: fixture.assets)
        #expect(segments.map(\.text) == ["hello"])
        #expect(segments[0].start == 12)
        #expect(segments[0].end == 12.4)
    }

    @Test func silentAudioDoesNotLaunchHelper() async throws {
        let fixture = try WhisperFixture(silent: true)
        defer { fixture.remove() }
        let result = try await WhisperTranscriber.transcribe(url: fixture.audio, chunk: fixture.chunk,
            locale: "zh-CN", assets: fixture.assets)
        #expect(result.isEmpty)
    }

    @Test func failedHelperDoesNotExposeOutput() async throws {
        let fixture = try WhisperFixture("echo 'private transcript' >&2; exit 7")
        defer { fixture.remove() }
        do {
            _ = try await WhisperTranscriber.transcribe(url: fixture.audio, chunk: fixture.chunk,
                locale: "en", assets: fixture.assets)
            Issue.record("Expected helper failure")
        } catch {
            #expect(error.localizedDescription.contains("7"))
            #expect(!error.localizedDescription.contains("private transcript"))
        }
    }

    @Test func watchdogKillsUnresponsiveHelper() async throws {
        let fixture = try WhisperFixture("trap '' TERM\nexec /bin/sleep 30")
        defer { fixture.remove() }
        let start = ContinuousClock.now
        do {
            _ = try await WhisperTranscriber.transcribe(url: fixture.audio, chunk: fixture.chunk,
                locale: "en", assets: fixture.assets, timeout: 0.1)
            Issue.record("Expected timeout")
        } catch {
            #expect(error.localizedDescription.contains("超时"))
        }
        #expect(start.duration(to: .now) < .seconds(5))
    }

    @Test func cancellationStopsHelperAndKeepsAudio() async throws {
        let fixture = try WhisperFixture("exec /bin/sleep 30")
        defer { fixture.remove() }
        let task = Task {
            try await WhisperTranscriber.transcribe(url: fixture.audio, chunk: fixture.chunk,
                locale: "en", assets: fixture.assets)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(FileManager.default.fileExists(atPath: fixture.audio.path))
    }
}
#endif

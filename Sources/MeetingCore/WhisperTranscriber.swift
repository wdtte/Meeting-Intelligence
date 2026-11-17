#if MEETING_WHISPER
import CryptoKit
import Darwin
import Foundation
import Synchronization

struct WhisperAssets: Sendable {
    static let modelName = "ggml-base-q5_1.bin"
    static let modelSHA256 = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
    let executable: URL
    let model: URL

    static func bundled() throws -> Self {
        if Bundle.main.bundleURL.pathExtension == "app", let resources = Bundle.main.resourceURL,
           let executable = Bundle.main.executableURL {
            return Self(executable: executable.deletingLastPathComponent().appendingPathComponent("meeting-whisper"),
                        model: resources.appendingPathComponent("Whisper/\(modelName)"))
        }
        #if DEBUG
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/whisper/runtime")
        return Self(executable: root.appendingPathComponent("meeting-whisper"), model: root.appendingPathComponent(modelName))
        #else
        throw MeetingError.message("Whisper 兼容版资源缺失，请重新安装完整应用。")
        #endif
    }

    func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path) else {
            throw MeetingError.message("Whisper 引擎或模型缺失，请重新安装完整的兼容版应用。")
        }
        let bytes = try Data(contentsOf: model, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == Self.modelSHA256 else {
            throw MeetingError.message("Whisper 模型校验失败，请重新安装兼容版应用。")
        }
    }
}

enum WhisperTranscriber {
    // One inference at a time bounds model memory across meetings and both tracks.
    // The dedicated queue never blocks the main actor or audio capture callbacks.
    private static let queue = DispatchQueue(label: "MeetingIntelligence.whisper", qos: .utility)

    static func language(_ locale: String) throws -> String {
        switch locale.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first {
        case "zh": return "zh"
        case "en": return "en"
        default: throw MeetingError.message("Whisper 兼容版当前支持中文和英文转写。")
        }
    }

    static func prepare(locale: String) async throws -> String {
        let language = try language(locale)
        let check = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try WhisperAssets.bundled().validate()
            try Task.checkCancellation()
        }
        try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
        return language
    }

    static func transcribe(url: URL, chunk: AudioChunk, locale: String,
                           assets: WhisperAssets? = nil, timeout: TimeInterval = 180) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let language = try language(locale)
        let assets = try assets ?? WhisperAssets.bundled()
        // Reuse the validated PCM conversion, phase-safe downmix, and conservative
        // silence gate. WAV and JSON are temporary and never enter diagnostics.
        let prepared = try await CloudAudioPreparation.prepare(url: url, skipSilence: true)
        guard let wav = prepared.url else { return [] }
        defer { try? FileManager.default.removeItem(at: wav) }
        let job = WhisperProcess()
        let segments = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let data = try job.run(assets: assets, wav: wav, language: language, timeout: timeout)
                        continuation.resume(returning: try decode(data, chunk: chunk, language: language))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { job.cancel() }
        try Task.checkCancellation()
        return segments
    }

    static func decode(_ data: Data, chunk: AudioChunk, language: String = "en") throws -> [TranscriptSegment] {
        struct Response: Decodable {
            struct Entry: Decodable {
                struct Offsets: Decodable { let from: Double; let to: Double }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Entry]
        }
        guard data.count <= 4 * 1024 * 1024, let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw MeetingError.message("Whisper 返回了无效的转写结果，音频已保存，可稍后重试。")
        }
        return try response.transcription.compactMap { entry in
            let start = entry.offsets.from / 1000, end = entry.offsets.to / 1000
            guard start.isFinite, end.isFinite, start >= 0, end >= start else {
                throw MeetingError.message("Whisper 返回了无效时间戳。")
            }
            let original = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Whisper may alternate scripts despite selecting Mandarin. The UI's
            // Chinese option promises Simplified Chinese, matching Apple output.
            let text = language == "zh"
                ? original.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? original
                : original
            guard !text.isEmpty, start < chunk.duration, end > start else { return nil }
            var segment = TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource,
                start: chunk.offset + start, end: chunk.offset + min(chunk.duration, end), text: text)
            segment.engine = LocalTranscriber.engine
            return segment
        }
    }
}

private final class WhisperProcess: Sendable {
    private struct State {
        var process: Process?
        var cancelled = false
        var timedOut = false
    }
    private let state = Mutex(State())

    func cancel() {
        state.withLock { value in
            value.cancelled = true
            if let process = value.process, process.isRunning { process.terminate() }
        }
        forceExitIfNeeded()
    }

    private func forceExitIfNeeded() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(1)) { [self] in
            state.withLock { value in
                if let process = value.process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func run(assets: WhisperAssets, wav: URL, language: String, timeout: TimeInterval) throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Meeting-Whisper-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("result")
        let process = Process()
        process.executableURL = assets.executable
        process.arguments = ["--model", assets.model.path, "--file", wav.path, "--language", language,
                             "--output-json", "--output-file", output.path, "--no-prints", "--suppress-nst",
                             "--threads", String(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try state.withLock { value in
            guard !value.cancelled else { throw CancellationError() }
            try process.run(); value.process = process
        }
        defer { state.withLock { $0.process = nil } }
        let watchdog = DispatchWorkItem { [self] in
            let running = state.withLock { value in
                guard let process = value.process, process.isRunning else { return false }
                value.timedOut = true; process.terminate(); return true
            }
            if running { forceExitIfNeeded() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }
        process.waitUntilExit()
        try state.withLock { value in
            if value.cancelled { throw CancellationError() }
            if value.timedOut { throw MeetingError.message("Whisper 转写超时，音频已保存，可稍后继续转写。") }
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw MeetingError.message("Whisper 引擎未能完成转写（退出码 \(process.terminationStatus)），音频已保存。")
        }
        let result = output.appendingPathExtension("json")
        let size = try result.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4 * 1024 * 1024 else { throw MeetingError.message("Whisper 返回的结果过大。") }
        return try Data(contentsOf: result)
    }
}
#endif

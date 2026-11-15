import Foundation
import AVFoundation
import Speech

/// Reads closed files, never shares capture buffers or blocks the real-time writer.
/// Each file is bounded to ten seconds; a slow recognizer catches up from disk.
public enum LocalTranscriber {
    public static func prepare(locale identifier: String, download: Bool) async throws -> String {
        try await SpeechAssetPreparation.shared.prepare(locale: identifier, download: download)
    }

    fileprivate static func install(locale identifier: String, download: Bool) async throws -> String {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw MeetingError.message("这台 Mac 不支持所选语言的本地转写。录音仍可独立使用。")
        }
        // false means this locale was already reserved; it is not a failure.
        _ = try await AssetInventory.reserve(locale: locale)
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [module])
        if status != .installed {
            guard download else { throw MeetingError.message("请先在设置中下载所选语言的本地转写模型。") }
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw MeetingError.message("语言模型尚未安装完成，请稍后重试。")
        }
        return locale.identifier
    }

    public static func transcribe(url: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
            group.addTask { try await recognize(url: url, chunk: chunk, locale: locale) }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw MeetingError.message("本地转写超时；音频已保存，可以稍后继续转写。")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? []
        }
    }

    private static func recognize(url: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let module = SpeechTranscriber(locale: Locale(identifier: locale), preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let results = Task { () throws -> [TranscriptSegment] in
            var segments: [TranscriptSegment] = []
            for try await result in module.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                guard start.isFinite, end.isFinite else { throw MeetingError.message("语音引擎返回了无效时间戳。") }
                guard !text.isEmpty else { continue }
                segments.append(TranscriptSegment(chunkID: chunk.id, source: chunk.audioSource,
                    start: chunk.offset + min(chunk.duration, max(0, start)),
                    end: chunk.offset + min(chunk.duration, max(start, end)), text: text))
            }
            return segments
        }
        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: url)
                // The file API performs format conversion using the module's supported format.
                _ = try await analyzer.analyzeSequence(from: file)
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let value = try await results.value
                try Task.checkCancellation()
                return value
            } catch {
                await analyzer.cancelAndFinishNow()
                results.cancel()
                _ = await results.result
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

// Settings preparation and recording jobs may request the same assets together.
// Share the in-flight operation so only one installation request runs per locale.
private actor SpeechAssetPreparation {
    static let shared = SpeechAssetPreparation()
    private var tasks: [String: Task<String, Error>] = [:]
    func prepare(locale: String, download: Bool) async throws -> String {
        let key = locale.replacingOccurrences(of: "-", with: "_").lowercased() + (download ? ":install" : ":check")
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await LocalTranscriber.install(locale: locale, download: download) }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

import Foundation

/// Build editions deliberately choose their engine. Standard builds contain no
/// Whisper backend or weights; compatibility builds also work offline on macOS 15.
public enum LocalTranscriber {
    #if MEETING_WHISPER
    public static let usesWhisper = true
    public static let engine = "Whisper base (q5_1)"
    public static let minimumSystemVersion = "15.0"
    #else
    public static let usesWhisper = false
    public static let engine = "Apple SpeechTranscriber"
    public static let minimumSystemVersion = "26.0"
    #endif

    public static var resourceDescription: String {
        usesWhisper
            ? "使用随兼容版安装包提供的 Whisper 多语言模型在本机转写，无需下载语音资源。较慢的 Mac 可能需要更长时间，录音会独立保存。"
            : "默认使用中文，通过 macOS 语音转写服务在本机处理。语言资源由 Apple 管理，缺少时自动下载，无需另装模型。"
    }

    public static func prepare(locale: String, download: Bool) async throws -> String {
        #if MEETING_WHISPER
        return try await WhisperTranscriber.prepare(locale: locale)
        #else
        guard #available(macOS 26.0, *) else {
            throw MeetingError.message("此安装包需要 macOS 26；macOS 15–25 请使用 Whisper 兼容版。")
        }
        return try await AppleSpeechTranscriber.prepare(locale: locale, download: download)
        #endif
    }

    public static func transcribe(url: URL, chunk: AudioChunk, locale: String) async throws -> [TranscriptSegment] {
        #if MEETING_WHISPER
        return try await WhisperTranscriber.transcribe(url: url, chunk: chunk, locale: locale)
        #else
        guard #available(macOS 26.0, *) else {
            throw MeetingError.message("请使用支持此系统的 Whisper 兼容版。")
        }
        return try await AppleSpeechTranscriber.transcribe(url: url, chunk: chunk, locale: locale)
        #endif
    }
}

import Foundation

public enum AudioSource: String, Codable, Sendable, CaseIterable {
    // Keep the legacy `application` wire value for system audio and older recordings.
    // These are capture sources, never inferred speakers.
    case application, microphone, imported
    public var label: String { switch self { case .application: "系统音频"; case .microphone: "麦克风"; case .imported: "导入音频" } }
}

public enum RecordingStatus: String, Codable, Sendable {
    case recording, completed, interrupted, failed
}

public struct AudioChunk: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var source: AudioSource?
    public var audioSource: AudioSource { source ?? .application }
    public var fileName: String
    public var offset: Double
    public var duration: Double
    public var sampleRate: Double
    public var channels: UInt32
    public var isComplete: Bool
    public var end: Double { offset + duration }
}

public struct Recording: Identifiable, Codable, Sendable, Equatable {
    public var schemaVersion = 2
    public var id: UUID = UUID()
    public var title: String
    public var applicationName: String
    public var bundleIdentifier: String
    public var startedAt: Date = Date()
    public var endedAt: Date?
    public var status: RecordingStatus = .recording
    public var chunks: [AudioChunk] = []
    public var note: String?
    public var transcriptPath: String?
    public var transcriptionLocale: String?
    public var cloudTranscription: CloudTranscriptionConfiguration?
    public var microphoneCaptureMode: MicrophoneCaptureMode?
    public var origin: RecordingOrigin?
    public var importMetadata: AudioImportMetadata?
    public var transcriptionPlan: TranscriptionPlan?
    public var automaticSummary: Bool?
    public var effectivePlan: TranscriptionPlan { transcriptionPlan ?? .localThenCloud }
    public var duration: Double { chunks.filter(\.isComplete).map(\.end).max() ?? 0 }
    public var audioDuration: Double { chunks.filter(\.isComplete).reduce(0) { $0 + $1.duration } }

    /// Global audio has no originating application. Retain the legacy metadata
    /// fields so existing manifests and the read-only CLI remain compatible.
    public static func systemAudio(title: String) -> Recording {
        Recording(title: title, applicationName: AudioSource.application.label, bundleIdentifier: "")
    }

    public init(title: String, applicationName: String, bundleIdentifier: String) {
        self.title = title; self.applicationName = applicationName; self.bundleIdentifier = bundleIdentifier
    }
}

public enum MeetingError: LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

public enum AudioTimeline {
    public static func position(_ time: Double, duration: Double) -> Double {
        guard time.isFinite, duration.isFinite else { return 0 }
        return min(max(0, time), max(0, duration))
    }
    public static func playableChunks(_ chunks: [AudioChunk], after time: Double) -> [AudioChunk] {
        chunks.filter { $0.isComplete && $0.duration > 0 && $0.end > time }.sorted { $0.offset < $1.offset }
    }
    public static func clock(_ seconds: Double) -> String {
        let value = Int(max(0, seconds.isFinite ? seconds : 0))
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
}

public enum RecordingOrigin: String, Codable, Sendable { case recorded, imported }
public enum TranscriptionPlan: String, Codable, Sendable { case localThenCloud, cloudOnly }
public struct AudioImportMetadata: Codable, Sendable, Equatable {
    public var originalFileName: String
    public var importedAt: Date
    public var format: String
    public var duration: Double
}

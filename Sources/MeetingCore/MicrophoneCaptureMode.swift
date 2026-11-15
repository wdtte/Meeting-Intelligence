// Persisted recording metadata. Keep the legacy value readable for old recordings;
// new captures always use shared input.
public enum MicrophoneCaptureMode: String, Codable, Sendable {
    case shared
    case systemEchoCancellation
}

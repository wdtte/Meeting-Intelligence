import CryptoKit
import Foundation

/// Model names remain case-sensitive; credentials are represented only by a one-way fingerprint.
public struct APIUsageIdentity: Hashable, Sendable {
    public let modelName: String?
    public let keyID: String?

    public init(modelName: String?, keyID: String?) {
        self.modelName = Self.normalized(modelName)
        self.keyID = Self.normalized(keyID)
    }

    public static func keyID(for apiKey: String) -> String? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        return "key-\(digest)"
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value.precomposedStringWithCanonicalMapping
    }
}

extension TranscriptionUsage {
    func attributed(modelName: String, apiKey: String, at date: Date = Date()) -> Self {
        var value = self
        value.modelName = APIUsageIdentity(modelName: modelName, keyID: nil).modelName
        value.keyID = APIUsageIdentity.keyID(for: apiKey)
        value.recordedAt = date
        return value
    }
}

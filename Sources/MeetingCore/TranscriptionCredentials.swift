import Foundation
import Security
import Synchronization

public enum TranscriptionCredentials {
    private static let session = CredentialSessionCache()
    public enum Presence { case saved, missing, authorizationRequired }

    /// Metadata only, with Keychain interaction forbidden. Launching the app
    /// must never unlock the keychain or request access to a secret.
    public static func presence(region: QwenRegion) throws -> Presence {
        var request = query(region)
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .saved
        case errSecItemNotFound: return .missing
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: return .authorizationRequired
        default: throw MeetingError.message("无法检查 API Key（Keychain：\(status)）。")
        }
    }

    private static let service = "Meeting Intelligence.Transcription"
    private static func query(_ region: QwenRegion) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "qwen.\(region.rawValue)"]
    }
    public static func load(region: QwenRegion) throws -> String? {
        try session.load(region.rawValue) {
            try readKeychain(region: region, allowInteraction: false)
        }
    }
    /// Only the explicit Settings action can display macOS authorization UI.
    /// Bypass the session cache so users can grant persistent access even after
    /// having chosen the one-time Allow option in an earlier prompt.
    public static func authorize(region: QwenRegion) throws -> Bool {
        let key = try readKeychain(region: region, allowInteraction: true)
        session.update(region.rawValue, value: key) {}
        return key != nil
    }
    static func readQuery(region: QwenRegion, allowInteraction: Bool = false) -> [String: Any] {
        var request = query(region)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        return request
    }
    private static func readKeychain(region: QwenRegion, allowInteraction: Bool) throws -> String? {
        let request = readQuery(region: region, allowInteraction: allowInteraction)
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        DiagnosticLog.shared.record("credentials.read", fields: ["region": region.rawValue,
            "stage": allowInteraction ? "explicit_authorization" : "silent_read", "code": String(status)])
        if status == errSecItemNotFound { return nil }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw MeetingError.message("钥匙串尚未授权或已锁定。请在设置中点击“授权钥匙串访问”，并在系统提示中选择“始终允许”。")
        }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw MeetingError.message("无法读取转写 API Key（Keychain：\(status)）。")
        }
        return key
    }
    public static func save(_ key: String, region: QwenRegion) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw MeetingError.message("请输入有效的 API Key。") }
        try session.update(region.rawValue, value: value) {
            let attributes = [kSecValueData as String: Data(value.utf8)]
            let status = SecItemUpdate(query(region) as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query(region)
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw MeetingError.message("API Key 保存失败（Keychain：\(added)）。") }
            } else if status != errSecSuccess { throw MeetingError.message("API Key 保存失败（Keychain：\(status)）。") }
        }
    }
    public static func delete(region: QwenRegion) throws {
        try session.update(region.rawValue, value: nil) {
            let status = SecItemDelete(query(region) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MeetingError.message("API Key 删除失败（Keychain：\(status)）。") }
        }
    }
}

/// Process-lifetime cache only. Serialize reads and mutations so concurrent
/// cloud jobs share one authorization and never retain an outdated saved key.
final class CredentialSessionCache: Sendable {
    private let keys = Mutex<[String: String]>([:])
    func load(_ account: String, read: () throws -> String?) rethrows -> String? {
        try keys.withLock { values in
            if let key = values[account] { return key }
            let key = try read()
            values[account] = key
            return key
        }
    }
    func update(_ account: String, value: String?, persist: () throws -> Void) rethrows {
        try keys.withLock { values in
            try persist()
            values[account] = value
        }
    }
}

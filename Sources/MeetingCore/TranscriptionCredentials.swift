import Foundation
import Security
import Synchronization

public enum TranscriptionCredentials {
    public typealias Presence = CredentialPresence
    private static func store(_ region: QwenRegion) -> KeychainCredentialStore {
        KeychainCredentialStore(service: "Meeting Intelligence.Transcription", account: "qwen.\(region.rawValue)")
    }
    public static func presence(region: QwenRegion) throws -> Presence { try store(region).presence() }
    public static func load(region: QwenRegion) throws -> String? { try store(region).load() }
    public static func authorize(region: QwenRegion) throws -> Bool { try store(region).authorize() }
    public static func save(_ key: String, region: QwenRegion) throws { try store(region).save(key) }
    public static func delete(region: QwenRegion) throws { try store(region).delete() }
    static func readQuery(region: QwenRegion, allowInteraction: Bool = false) -> [String: Any] {
        store(region).readQuery(allowInteraction: allowInteraction)
    }
}

public enum SummaryCredentials {
    private static var store: KeychainCredentialStore {
        KeychainCredentialStore(service: "Meeting Intelligence.Summary", account: "openai-compatible")
    }
    public static func presence() throws -> CredentialPresence { try store.presence() }
    public static func load() throws -> String? { try store.load() }
    public static func authorize() throws -> Bool { try store.authorize() }
    public static func save(_ key: String) throws { try store.save(key) }
    public static func delete() throws { try store.delete() }
    static func readQuery(allowInteraction: Bool = false) -> [String: Any] { store.readQuery(allowInteraction: allowInteraction) }
}

public enum CredentialPresence { case saved, missing, authorizationRequired }

struct KeychainCredentialStore {
    let service: String
    let account: String
    private static let session = CredentialSessionCache()

    /// Metadata only, with Keychain interaction forbidden. Launching the app
    /// must never unlock the keychain or request access to a secret.
    func presence() throws -> CredentialPresence {
        var request = query()
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

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func load() throws -> String? {
        try Self.session.load(service + "." + account) {
            try readKeychain(allowInteraction: false)
        }
    }
    /// Only the explicit Settings action can display macOS authorization UI.
    /// Bypass the session cache so users can grant persistent access even after
    /// having chosen the one-time Allow option in an earlier prompt.
    func authorize() throws -> Bool {
        let key = try readKeychain(allowInteraction: true)
        Self.session.update(service + "." + account, value: key) {}
        return key != nil
    }
    func readQuery(allowInteraction: Bool = false) -> [String: Any] {
        var request = query()
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecUseAuthenticationUI as String] = allowInteraction ? kSecUseAuthenticationUIAllow : kSecUseAuthenticationUIFail
        return request
    }
    private func readKeychain(allowInteraction: Bool) throws -> String? {
        let request = readQuery(allowInteraction: allowInteraction)
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        DiagnosticLog.shared.record("credentials.read", fields: ["stage": allowInteraction ? "explicit_authorization" : "silent_read",
            "code": String(status)])
        if status == errSecItemNotFound { return nil }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status) {
            throw MeetingError.message("钥匙串尚未授权或已锁定。请在设置中点击“授权钥匙串访问”，并在系统提示中选择“始终允许”。")
        }
        guard status == errSecSuccess, let data = value as? Data, let key = String(data: data, encoding: .utf8) else {
            throw MeetingError.message("无法读取 API Key（Keychain：\(status)）。")
        }
        return key
    }
    func save(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("\n"), !value.contains("\r") else { throw MeetingError.message("请输入有效的 API Key。") }
        try Self.session.update(service + "." + account, value: value) {
            let attributes = [kSecValueData as String: Data(value.utf8)]
            let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
            if status == errSecItemNotFound {
                var item = query()
                item.merge(attributes) { _, new in new }
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw MeetingError.message("API Key 保存失败（Keychain：\(added)）。") }
            } else if status != errSecSuccess { throw MeetingError.message("API Key 保存失败（Keychain：\(status)）。") }
        }
    }
    func delete() throws {
        try Self.session.update(service + "." + account, value: nil) {
            let status = SecItemDelete(query() as CFDictionary)
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

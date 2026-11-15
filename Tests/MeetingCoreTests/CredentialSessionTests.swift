import Foundation
import Synchronization
import Testing
import Security
@testable import MeetingCore

@Test func credentialReadsRequireExplicitOptInToSystemPrompts() {
    for region in [QwenRegion.beijing, .singapore] {
        let silent = TranscriptionCredentials.readQuery(region: region)
        let authorized = TranscriptionCredentials.readQuery(region: region, allowInteraction: true)
        #expect(silent[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIFail as String)
        #expect(authorized[kSecUseAuthenticationUI as String] as? String == kSecUseAuthenticationUIAllow as String)
        #expect(silent[kSecAttrAccount as String] as? String == "qwen.\(region.rawValue)")
        #expect(silent[kSecReturnData as String] as? Bool == true)
    }
}

@Test func credentialSessionReusesAuthorizationAndSeparatesAccounts() async {
    let cache = CredentialSessionCache()
    let reads = Mutex(0)
    await withTaskGroup(of: String?.self) { group in
        for _ in 0..<20 {
            group.addTask {
                cache.load("beijing") {
                    reads.withLock { $0 += 1 }
                    return "test-only-key"
                }
            }
        }
        for await value in group { #expect(value == "test-only-key") }
    }
    #expect(reads.withLock { $0 } == 1)
    #expect(cache.load("singapore") { "other-test-key" } == "other-test-key")
}

@Test func credentialSessionUpdatesOnlyAfterSuccessfulPersistence() throws {
    let cache = CredentialSessionCache()
    #expect(cache.load("account") { "old" } == "old")
    #expect(throws: MeetingError.self) {
        try cache.update("account", value: "failed") { throw MeetingError.message("test failure") }
    }
    #expect(cache.load("account") { "unexpected" } == "old")
    cache.update("account", value: "new") {}
    #expect(cache.load("account") { "unexpected" } == "new")
    cache.update("account", value: nil) {}
    #expect(cache.load("account") { nil } == nil)
    // Missing keys and denied requests must not prevent a later successful read.
    #expect(throws: MeetingError.self) {
        try cache.load("account") { throw MeetingError.message("denied") }
    }
    #expect(cache.load("account") { "restored" } == "restored")
}

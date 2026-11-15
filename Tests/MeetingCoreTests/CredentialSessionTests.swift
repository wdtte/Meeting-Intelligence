import Foundation
import Synchronization
import Testing
@testable import MeetingCore

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

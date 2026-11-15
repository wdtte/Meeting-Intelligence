import Foundation

/// Driven by the capture queue's timer, so retries never block a user's Stop request.
struct CaptureRecoverySchedule {
    enum Action { case wait, retry, expired }
    private let deadline: TimeInterval
    private var nextAttempt: TimeInterval

    init(now: TimeInterval) {
        deadline = now + 12
        nextAttempt = now + 0.5
    }

    mutating func advance(now: TimeInterval) -> Action {
        if now >= deadline { return .expired }
        guard now >= nextAttempt else { return .wait }
        nextAttempt = now + 0.5
        return .retry
    }
}

import Foundation
import ReckonCore

@MainActor
struct ReckonAppLockTests {
    func requiresAuthenticationOnEverySession() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        try bankExpect(!lock.isUnlocked)
        let first = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        try bankExpect(!lock.isUnlocked)
        authentication.completeNext(.success(()))
        let firstResult = await first.value
        try bankExpect(firstResult)
        try bankExpect(lock.isUnlocked)
        lock.lock()
        try bankExpect(!lock.isUnlocked)
        let second = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        try bankExpect(authentication.attempts == 2)
        authentication.completeNext(.success(()))
        let secondResult = await second.value
        try bankExpect(secondResult)
    }

    func reusesSessionUntilTenMinuteBoundary() async throws {
        let authentication = PendingReckonAuthentication()
        let clock = ReckonTestUptime()
        let lock = ReckonAppLock(authenticator: authentication, now: { clock.now })
        var closedViews = 0
        lock.onLock = { closedViews += 1 }
        let first = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        authentication.completeNext(.success(()))
        let firstResult = await first.value
        try bankExpect(firstResult)
        clock.now = 699
        try bankExpect(lock.isUnlocked)
        let reused = await lock.unlock()
        try bankExpect(reused)
        try bankExpect(authentication.attempts == 1)
        clock.now = 700
        try bankExpect(!lock.isUnlocked)
        lock.expireSessionIfNeeded()
        try bankExpect(lock.state == .locked)
        try bankExpect(closedViews == 1)
        let next = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        try bankExpect(authentication.attempts == 2)
        authentication.completeNext(.failure(AuthenticationRejected()))
        let nextRejected = !(await next.value)
        try bankExpect(nextRejected)
        try bankExpect(!lock.isUnlocked)
    }

    func sessionStartsWhenAuthenticationCompletes() async throws {
        let authentication = PendingReckonAuthentication()
        let clock = ReckonTestUptime()
        let lock = ReckonAppLock(authenticator: authentication, now: { clock.now })
        let attempt = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        clock.now = 1000
        authentication.completeNext(.success(()))
        let result = await attempt.value
        try bankExpect(result)
        clock.now = 1599
        try bankExpect(lock.isUnlocked)
        clock.now = 1600
        try bankExpect(!lock.isUnlocked)
        lock.expireSessionIfNeeded()
        try bankExpect(lock.state == .locked)
    }

    func rejectionKeepsAccountsLocked() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        let attempt = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        authentication.completeNext(.failure(AuthenticationRejected()))
        let attemptRejected = !(await attempt.value)
        try bankExpect(attemptRejected)
        try bankExpect(lock.state == .locked)
        try bankExpect(lock.errorMessage != nil)
    }

    func lateSuccessCannotUnlockAfterLock() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        let attempt = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        lock.lock()
        authentication.completeNext(.success(()))
        let attemptRejected = !(await attempt.value)
        try bankExpect(attemptRejected)
        try bankExpect(!lock.isUnlocked)
        try bankExpect(authentication.cancellations == 1)
    }

    func previousReplyCannotUnlockNewAttempt() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        let previous = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        lock.lock()
        let current = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        authentication.completeNext(.success(()))
        let previousRejected = !(await previous.value)
        try bankExpect(previousRejected)
        try bankExpect(lock.state == .authenticating)
        authentication.completeNext(.failure(AuthenticationRejected()))
        let currentRejected = !(await current.value)
        try bankExpect(currentRejected)
        try bankExpect(!lock.isUnlocked)
    }

    func concurrentClickDoesNotStartAnotherPrompt() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        let first = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        let duplicate = await lock.unlock()
        try bankExpect(!duplicate)
        try bankExpect(authentication.attempts == 1)
        authentication.completeNext(.success(()))
        let firstResult = await first.value
        try bankExpect(firstResult)
    }

    func cancelledTaskCannotUnlock() async throws {
        let authentication = PendingReckonAuthentication()
        let lock = ReckonAppLock(authenticator: authentication)
        let attempt = Task { await lock.unlock() }
        await authentication.waitUntilStarted()
        attempt.cancel()
        authentication.completeNext(.success(()))
        let attemptRejected = !(await attempt.value)
        try bankExpect(attemptRejected)
        try bankExpect(lock.state == .locked)
    }
}

private struct AuthenticationRejected: LocalizedError {
    var errorDescription: String? { "Authentication rejected" }
}

@MainActor
private final class PendingReckonAuthentication: ReckonAuthenticating {
    private var pending: [CheckedContinuation<Void, any Error>] = []
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var observedAttempts = 0
    private(set) var attempts = 0
    private(set) var cancellations = 0

    func authenticate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            attempts += 1
            pending.append(continuation)
            startWaiter?.resume()
            startWaiter = nil
        }
    }

    func cancelAuthentication() { cancellations += 1 }

    func waitUntilStarted() async {
        if attempts == observedAttempts {
            await withCheckedContinuation { startWaiter = $0 }
        }
        observedAttempts = attempts
    }

    func completeNext(_ result: Result<Void, any Error>) {
        pending.removeFirst().resume(with: result)
    }
}

@MainActor
private final class ReckonTestUptime {
    var now: TimeInterval = 100
}

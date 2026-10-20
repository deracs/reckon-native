import Combine
import Foundation

/// Authentication must be cancellable when the app locks or the Mac sleeps.
@MainActor public protocol ReckonAuthenticating: AnyObject {
    func authenticate() async throws
    func cancelAuthentication()
}

/// An unlocked session expires ten minutes after authentication, using monotonic uptime.
@MainActor public final class ReckonAppLock: ObservableObject {
    public enum State: Equatable {
        case locked
        case authenticating
        case unlocked(until: TimeInterval)
    }

    public static let sessionDuration: TimeInterval = 10 * 60
    @Published public private(set) var state: State = .locked
    @Published public private(set) var errorMessage: String?
    public var onLock: (() -> Void)?
    private let authenticator: any ReckonAuthenticating
    private let now: @MainActor () -> TimeInterval
    private var authenticationGeneration = UUID()
    private var expirationTask: Task<Void, Never>?

    public init(authenticator: any ReckonAuthenticating,
                now: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.authenticator = authenticator
        self.now = now
    }

    deinit { expirationTask?.cancel() }

    public var isUnlocked: Bool {
        guard case .unlocked(let deadline) = state else { return false }
        return now() < deadline
    }

    public func unlock() async -> Bool {
        expireSessionIfNeeded()
        if isUnlocked { return true }
        guard state == .locked else { return false }
        let generation = UUID()
        authenticationGeneration = generation
        errorMessage = nil
        state = .authenticating
        do {
            try await authenticator.authenticate()
            guard authenticationGeneration == generation else { return false }
            guard !Task.isCancelled else {
                state = .locked
                return false
            }
            state = .unlocked(until: now() + Self.sessionDuration)
            expirationTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Self.sessionDuration)) }
                catch { return }
                self?.expireSessionIfNeeded()
            }
            return true
        } catch {
            guard authenticationGeneration == generation else { return false }
            state = .locked
            errorMessage = error.localizedDescription
            return false
        }
    }

    public func expireSessionIfNeeded() {
        if case .unlocked(let deadline) = state, now() >= deadline { lock() }
    }

    public func lock() {
        authenticationGeneration = UUID()
        expirationTask?.cancel()
        expirationTask = nil
        state = .locked
        errorMessage = nil
        authenticator.cancelAuthentication()
        onLock?()
    }
}

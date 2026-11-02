import Foundation

/// Keeps the last completed update check while throttling automatic checks to once per minute.
public struct ReckonUpdateCheckState: Codable, Equatable, Sendable {
    public enum Result: String, Codable, Sendable {
        case upToDate, available, unavailable, failed, skipped
    }

    public private(set) var latestVersion: String?
    public private(set) var lastCheckedAt: Date?
    public private(set) var result: Result?
    public private(set) var isChecking = false
    private var lastStartedAt: Date?

    // An interrupted check must never restore as an active check after relaunch.
    private enum CodingKeys: String, CodingKey { case latestVersion, lastCheckedAt, result }

    public init() { }

    /// Returns true only when automatic checks are enabled, idle, and outside the cooldown.
    public mutating func beginAutomaticCheck(at date: Date, enabled: Bool, sessionInProgress: Bool) -> Bool {
        guard enabled, !sessionInProgress, !isChecking else { return false }
        if let previous = lastStartedAt ?? lastCheckedAt, date.timeIntervalSince(previous) < 60 { return false }
        beginCheck(at: date)
        return true
    }

    /// Explicit user checks bypass the automatic cooldown.
    public mutating func beginCheck(at date: Date) {
        isChecking = true
        lastStartedAt = date
    }

    public mutating func foundUpdate(version: String, at date: Date) {
        latestVersion = version
        complete(.available, at: date)
    }

    /// An unavailable update is not proof the installed version is current.
    public mutating func foundNoUpdate(latestVersion: String?, isUpToDate: Bool, at date: Date) {
        self.latestVersion = latestVersion
        complete(isUpToDate ? .upToDate : .unavailable, at: date)
    }

    /// Keep the last known release when a new network check fails.
    public mutating func failed(at date: Date) { complete(.failed, at: date) }

    public mutating func skippedUpdate() {
        result = .skipped
        isChecking = false
    }

    public mutating func finishCheck() { isChecking = false }

    private mutating func complete(_ result: Result, at date: Date) {
        self.result = result
        lastCheckedAt = date
        isChecking = false
    }
}

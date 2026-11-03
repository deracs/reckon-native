import Foundation

/// Startup mode is independent of macOS login registration and never stores financial data.
enum ReckonDesktopPreferences {
    static let launchKey = "ReckonOpenDesktopAtLaunch"
    static var opensAtLaunch: Bool { UserDefaults.standard.object(forKey: launchKey) as? Bool ?? true }
}

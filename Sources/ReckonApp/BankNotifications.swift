import Foundation
import ReckonCore
import UserNotifications

@MainActor
final class BankNotifications {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            center.requestAuthorization(options: [.alert]) { granted, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    func permissionDescription() async -> String {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                let message: String
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral: message = "Notifications allowed. Banners hide account names and amounts."
                case .denied: message = "Notifications blocked in System Settings → Notifications → Reckon."
                case .notDetermined: message = "Enable alerts to request permission."
                @unknown default: message = "Check Reckon in System Settings → Notifications."
                }
                continuation.resume(returning: message)
            }
        }
    }

    func deliver(_ alerts: [BankAlert]) async throws {
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = "Reckon"
            content.body = alert.kind == .lowBalance
                ? "An account crossed your balance limit. Open Reckon to see the details."
                : "A standing order estimate increased. Open Reckon to see the details."
            let request = UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                center.add(request) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
    }
}

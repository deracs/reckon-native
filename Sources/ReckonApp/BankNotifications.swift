import Foundation
import ReckonCore
import UserNotifications

@MainActor
final class BankNotifications {
    private let center = UNUserNotificationCenter.current()

    func requestPermission() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }

    func permissionDescription() async -> String {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return "Notifications allowed. Banners hide account names and amounts."
        case .denied: return "Notifications blocked in System Settings → Notifications → Reckon."
        case .notDetermined: return "Enable alerts to request permission."
        @unknown default: return "Check Reckon in System Settings → Notifications."
        }
    }

    func deliver(_ alerts: [BankAlert]) async throws {
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = "Reckon"
            content.body = alert.kind == .lowBalance
                ? "An account crossed your balance limit. Open Reckon to see the details."
                : "A standing order estimate increased. Open Reckon to see the details."
            try await center.add(UNNotificationRequest(identifier: alert.id.uuidString, content: content, trigger: nil))
        }
    }
}

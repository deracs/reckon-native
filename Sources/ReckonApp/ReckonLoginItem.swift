import Foundation
import ServiceManagement

enum ReckonLoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static func runCommandIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--enable-launch-at-login")
            || arguments.contains("--disable-launch-at-login")
            || arguments.contains("--launch-at-login-status") else { return }
        do {
            if arguments.contains("--disable-launch-at-login") { try setEnabled(false) }
            else if arguments.contains("--enable-launch-at-login") { try setEnabled(true) }
            let status: String
            switch SMAppService.mainApp.status {
            case .enabled: status = "enabled"
            case .notRegistered: status = "notRegistered"
            case .requiresApproval: status = "requiresApproval"
            case .notFound: status = "notFound"
            @unknown default: status = "unknown"
            }
            let data = try JSONSerialization.data(withJSONObject: ["status": status, "app": Bundle.main.bundlePath], options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            if arguments.contains("--enable-launch-at-login") && !isEnabled { exit(2) }
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Could not change Reckon’s launch-at-login setting.\n".utf8))
            exit(1)
        }
    }
}

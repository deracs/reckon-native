import AppKit
import Sparkle
@testable import ReckonApp

private struct WindowCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct ReckonWindowCheckRunner {
    @MainActor static func main() {
        guard ProcessInfo.processInfo.arguments.contains("--demo") else {
            print("Window lifecycle checks require --demo.")
            exit(1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = ReckonApplicationDelegate()
        application.delegate = delegate
        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
                try runUpdateCallbackChecks()
                print("PASS Sparkle callbacks report current, failed, and incompatible update checks")
                try await runWindowChecks(delegate)
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                print("PASS Menu-bar dropdown remains available while Settings is open or inactive")
                exit(0)
            } catch {
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                print("FAIL \(error)")
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { application.run() }
    }

    @MainActor private static func runWindowChecks(_ delegate: ReckonApplicationDelegate) async throws {
        let popover = try storedPopover(delegate)
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(150))
        try expectWindow(popover.isShown, "Initial menu-bar click did not open the dropdown")

        try sendWindowAction("showSettings", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        let settings = try settingsWindow()
        try expectWindow(settings.isVisible, "Settings did not open from the dropdown")
        try expectWindow(!popover.isShown, "Dropdown did not close when Settings opened")

        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Menu-bar click redirected to Settings instead of opening the dropdown")

        popover.performClose(nil)
        settings.makeKeyAndOrderFront(nil)
        NSApp.deactivate()
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(settings.isVisible, "Settings disappeared when the app lost focus")
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Menu-bar click did not reopen the dropdown after clicking away from Settings")

        popover.performClose(nil)
        settings.orderOut(nil)
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Menu-bar click did not reopen the dropdown after Settings was hidden")

        try sendWindowAction("showSettings", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(try settingsWindow() === settings, "Reopening Settings created a duplicate window")
        try expectWindow(settings.isVisible, "Existing Settings window did not return to the screen")
        try expectWindow(!popover.isShown, "Reopening Settings left the dropdown open")

        settings.miniaturize(nil)
        try await Task.sleep(for: .milliseconds(100))
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Minimized Settings prevented the menu-bar dropdown from opening")
        try sendWindowAction("showSettings", to: delegate)
        try await Task.sleep(for: .milliseconds(150))
        try expectWindow(!settings.isMiniaturized && settings.isVisible, "Settings did not restore from the Dock")

        settings.close()
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Closing Settings prevented the dropdown from reopening")
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(!popover.isShown, "Second menu-bar click did not dismiss the dropdown")
        try sendWindowAction("toggleDashboard", to: delegate)
        try await Task.sleep(for: .milliseconds(100))
        try expectWindow(popover.isShown, "Dropdown stopped opening after a repeated menu-bar click")
    }

    @MainActor private static func runUpdateCallbackChecks() throws {
        // Exercise the real optional delegate methods without starting Sparkle or making requests.
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updates = ReckonSoftwareUpdates(isDemo: true)
        try expectWindow(updates.responds(to: #selector(SPUUpdaterDelegate.updaterDidNotFindUpdate(_:error:))),
                         "Sparkle cannot discover the detailed no-update callback")
        try expectWindow(updates.responds(to: #selector(SPUUpdaterDelegate.updater(_:didFinishUpdateCycleFor:error:))),
                         "Sparkle cannot discover the completed-check callback")
        let current = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                              userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.onLatestVersion.rawValue)])
        updates.updaterDidNotFindUpdate(controller.updater, error: current)
        try expectWindow(updates.checkState.result == .upToDate, "Current version was not reported as up to date")
        try expectWindow(updates.checkState.latestVersion == updates.installedVersion && updates.lastCheckedAt != nil,
                         "Completed check did not record the version and time")
        updates.updater(controller.updater, didAbortWithError: URLError(.notConnectedToInternet))
        try expectWindow(updates.checkState.result == .failed && updates.statusTitle == "Update check failed",
                         "Failed check was incorrectly reported as up to date")
        try expectWindow(updates.checkState.latestVersion == updates.installedVersion,
                         "Failed check erased the last known release")
        let incompatible = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue),
                                   userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: SPUNoUpdateFoundReason.systemIsTooOld.rawValue)])
        updates.updaterDidNotFindUpdate(controller.updater, error: incompatible)
        updates.updater(controller.updater, didFinishUpdateCycleFor: .updateInformation, error: incompatible)
        try expectWindow(updates.checkState.result == .unavailable && !updates.checkState.isChecking,
                         "Incompatible update was incorrectly reported as up to date")
    }

    @MainActor private static func sendWindowAction(_ name: String, to delegate: ReckonApplicationDelegate) throws {
        if name == "toggleDashboard" {
            guard let item = Mirror(reflecting: delegate).children.first(where: { $0.label == "statusItem" })?.value as? NSStatusItem,
                  let button = item.button else {
                throw WindowCheckFailure(description: "Menu-bar button was not created")
            }
            try expectWindow(button.isEnabled, "Menu-bar button stopped accepting clicks")
            button.performClick(nil)
            return
        }
        try expectWindow(NSApp.sendAction(NSSelectorFromString(name), to: delegate, from: nil),
                         "Window action was not connected: \(name)")
    }

    @MainActor private static func storedPopover(_ delegate: ReckonApplicationDelegate) throws -> NSPopover {
        guard let popover = Mirror(reflecting: delegate).children.first(where: { $0.label == "popover" })?.value as? NSPopover else {
            throw WindowCheckFailure(description: "Could not inspect the app's real popover")
        }
        return popover
    }

    @MainActor private static func settingsWindow() throws -> NSWindow {
        guard let window = NSApp.windows.first(where: { $0.title == "Reckon Settings" }) else {
            throw WindowCheckFailure(description: "Settings window was not created")
        }
        return window
    }

    private static func expectWindow(_ condition: Bool, _ message: String) throws {
        if !condition { throw WindowCheckFailure(description: message) }
    }
}

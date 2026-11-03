import AppKit
import Sparkle
@testable import ReckonApp

private struct WindowCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class WindowTransitionReceipt {
    var completed = false
}

@main
struct ReckonWindowCheckRunner {
    @MainActor static func main() {
        if ReckonWindowFocusHelper.runFocusHelperIfRequested() { return }
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
                try await waitForWindowState("app launch") {
                    (Mirror(reflecting: delegate).children.first(where: { $0.label == "statusItem" })?.value as? NSStatusItem)?.button != nil
                }
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
        let focusDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ReckonFocusCheck-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: focusDirectory, withIntermediateDirectories: true)
        let readyURL = focusDirectory.appendingPathComponent("ready")
        let focusProcess = Process()
        focusProcess.executableURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("ReckonFocusHelper.app/Contents/MacOS/ReckonWindowChecks")
        focusProcess.arguments = ["--focus-helper", String(ProcessInfo.processInfo.processIdentifier), readyURL.path]
        defer {
            if focusProcess.isRunning {
                focusProcess.terminate()
                focusProcess.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: focusDirectory)
        }
        try focusProcess.run()
        try await waitForWindowState("focus helper launch") {
            NSRunningApplication(processIdentifier: focusProcess.processIdentifier)?.isFinishedLaunching == true
        }
        guard let focusApp = NSRunningApplication(processIdentifier: focusProcess.processIdentifier) else {
            throw WindowCheckFailure(description: "Focus helper exited before the check")
        }
        let popover = try storedPopover(delegate)
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Initial menu-bar click did not open the dropdown")

        try await sendWindowAction("showSettings", to: delegate)
        let settings = try settingsWindow()
        try expectWindow(settings.isVisible, "Settings did not open from the dropdown")
        try expectWindow(!popover.isShown, "Dropdown did not close when Settings opened")

        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Menu-bar click redirected to Settings instead of opening the dropdown")

        popover.performClose(nil)
        settings.makeKeyAndOrderFront(nil)
        try await waitForWindowState("Settings activation before the focus handoff") { NSApp.isActive && settings.isKeyWindow }
        // A delayed deactivate() request can otherwise dismiss a dropdown several clicks later.
        NSApp.yieldActivation(to: focusApp)
        try expectWindow(focusApp.activate(from: .current, options: []), "macOS rejected the focus helper activation")
        try await waitForWindowState("focus handoff to the helper") {
            !NSApp.isActive && focusApp.isActive && FileManager.default.fileExists(atPath: readyURL.path)
        }
        try expectWindow(settings.isVisible, "Settings disappeared when the app lost focus")
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Menu-bar click did not reopen the dropdown after clicking away from Settings")

        popover.performClose(nil)
        settings.orderOut(nil)
        try await waitForWindowState("Settings hidden") { !settings.isVisible && !settings.isKeyWindow && !settings.occlusionState.contains(.visible) }
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Menu-bar click did not reopen the dropdown after Settings was hidden")

        try await sendWindowAction("showSettings", to: delegate)
        try expectWindow(try settingsWindow() === settings, "Reopening Settings created a duplicate window")
        try expectWindow(settings.isVisible, "Existing Settings window did not return to the screen")
        try expectWindow(!popover.isShown, "Reopening Settings left the dropdown open")

        try await performWindowTransition("Settings minimization", completion: NSWindow.didMiniaturizeNotification, window: settings) {
            settings.miniaturize(nil)
        }
        try expectWindow(settings.isMiniaturized, "Settings did not minimize before the menu-bar check")
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Minimized Settings prevented the menu-bar dropdown from opening")
        try await performWindowTransition("Settings restoration", completion: NSWindow.didDeminiaturizeNotification, window: settings) {
            try await sendWindowAction("showSettings", to: delegate)
        }
        try expectWindow(!settings.isMiniaturized && settings.isVisible, "Settings did not restore from the Dock")

        settings.close()
        try await waitForWindowState("Settings closed") { !settings.isVisible && !settings.isKeyWindow && !settings.occlusionState.contains(.visible) }
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Closing Settings prevented the dropdown from reopening")
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(!popover.isShown, "Second menu-bar click did not dismiss the dropdown")
        try await sendWindowAction("toggleDashboard", to: delegate)
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

    @MainActor private static func sendWindowAction(_ name: String, to delegate: ReckonApplicationDelegate) async throws {
        if name == "toggleDashboard" {
            guard let item = Mirror(reflecting: delegate).children.first(where: { $0.label == "statusItem" })?.value as? NSStatusItem,
                  let button = item.button else {
                throw WindowCheckFailure(description: "Menu-bar button was not created")
            }
            try expectWindow(button.isEnabled, "Menu-bar button stopped accepting clicks")
            let popover = try storedPopover(delegate)
            let shouldOpen = !popover.isShown
            button.performClick(nil)
            try await waitForWindowState(shouldOpen ? "dropdown activation" : "dropdown dismissal") {
                if !shouldOpen { return !popover.isShown }
                return NSApp.isActive && popover.isShown && popover.contentViewController?.view.window?.isKeyWindow == true
            }
            return
        }
        try expectWindow(NSApp.sendAction(NSSelectorFromString(name), to: delegate, from: nil),
                         "Window action was not connected: \(name)")
        // isVisible can be true before WindowServer finishes a hide/show, when minimization is still ignored.
        try await waitForWindowState("Settings activation") {
            guard let settings = try? settingsWindow() else { return false }
            return NSApp.isActive && settings.isVisible && settings.isKeyWindow && settings.occlusionState.contains(.visible) && !settings.isMiniaturized
                && (try? storedPopover(delegate).isShown) == false
        }
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

    /// Register before the action so synchronous and asynchronous AppKit completions are both observed.
    @MainActor private static func performWindowTransition(_ description: String, completion: Notification.Name, window: NSWindow,
                                                           action: @MainActor () async throws -> Void) async throws {
        let receipt = WindowTransitionReceipt()
        let observer = NotificationCenter.default.addObserver(forName: completion, object: window, queue: nil) { _ in
            MainActor.assumeIsolated { receipt.completed = true }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        try await action()
        try await waitForWindowState(description) { receipt.completed }
    }

    /// Wait for the requested state rather than assuming a desktop transition finishes in 100 ms.
    @MainActor private static func waitForWindowState(_ description: String, until predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        // Always return control to AppKit before the next action, even for an already-true property.
        try await Task.sleep(for: .milliseconds(10))
        while !predicate() {
            guard clock.now < deadline else {
                let settings = try? settingsWindow()
                let details = "app active=\(NSApp.isActive), Settings minimized=\(settings?.isMiniaturized ?? false)"
                throw WindowCheckFailure(description: "Timed out waiting for \(description); \(details)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

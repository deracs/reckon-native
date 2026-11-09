import AppKit
import SwiftUI
import Sparkle
import ReckonCore
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
                try runManualFinancialStorageChecks()
                print("PASS Manual accounts, goals and forecast settings are encrypted and survive reload")
                try runUpdateCallbackChecks()
                print("PASS Sparkle callbacks report current, failed, and incompatible update checks")
                try await runWindowChecks(delegate)
                try await runDesktopWindowChecks(delegate)
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                print("PASS Menu-bar dropdown remains available while Settings is open or inactive")
                print("PASS Desktop window shares the session, visit, settings and menu-bar lifecycle")
                exit(0)
            } catch {
                delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
                print("FAIL \(error)")
                exit(1)
            }
        }
        withExtendedLifetime(delegate) { application.run() }
    }

    private static func runManualFinancialStorageChecks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReckonManualCheck-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.enc")
        let storage = try ManualFinancialAccountsStorage(url: url, key: Data(repeating: 7, count: 32))
        let account = ManualFinancialAccount(name: "Fixture KiwiSaver", kind: "KiwiSaver", currency: "NZD", balance: 1234)
        let goal = SavingsGoal(accountID: "fixture-account", name: "Fixture goal", target: 2000, deadline: nil, paydayIntervalDays: 14)
        var settings = LocalFinancialSettings()
        settings.accounts = [account]; settings.goals = [goal]; settings.forecastAdjustments.weeklySpending = 35
        try storage.save(settings)
        let encrypted = try Data(contentsOf: url)
        guard encrypted.range(of: Data("Fixture KiwiSaver".utf8)) == nil else { throw WindowCheckFailure(description: "Manual account was saved in plaintext") }
        let restored = try storage.load()
        guard restored.accounts == [account], restored.goals == [goal], restored.forecastAdjustments.weeklySpending == 35 else {
            throw WindowCheckFailure(description: "Manual financial settings did not survive reload")
        }
        let wrongKey = try ManualFinancialAccountsStorage(url: url, key: Data(repeating: 8, count: 32))
        do {
            _ = try wrongKey.load()
            throw WindowCheckFailure(description: "Wrong key opened manual financial settings")
        } catch is WindowCheckFailure { throw WindowCheckFailure(description: "Wrong key opened manual financial settings") }
        catch { }
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

    @MainActor private static func runDesktopWindowChecks(_ delegate: ReckonApplicationDelegate) async throws {
        guard let store = Mirror(reflecting: delegate).children.first(where: { $0.label == "store" })?.value as? BankDashboardStore,
              let appLock = Mirror(reflecting: delegate).children.first(where: { $0.label == "appLock" })?.value as? ReckonAppLock,
              let navigation = Mirror(reflecting: delegate).children.first(where: { $0.label == "desktopNavigation" })?.value as? ReckonDesktopNavigation else {
            throw WindowCheckFailure(description: "Could not inspect the shared desktop dependencies")
        }
        try await waitForWindowState("sample backend dashboard") { store.dashboard != nil || store.loadError != nil }
        try expectWindow(store.dashboard != nil, "Sample backend did not load the dashboard: \(store.loadError ?? "unknown error")")
        let popover = try storedPopover(delegate)
        popover.performClose(nil)
        try expectWindow(NSApp.sendAction(NSSelectorFromString("openDesktop"), to: delegate, from: nil), "Open app action was not connected")
        try await waitForWindowState("desktop window") { desktopWindow()?.isKeyWindow == true && desktopWindow()?.occlusionState.contains(.visible) == true }
        guard let desktop = desktopWindow(), let host = desktop.contentViewController as? NSHostingController<ReckonDesktopView> else {
            throw WindowCheckFailure(description: "Desktop window did not host the protected desktop view")
        }
        try expectWindow(host.rootView.store === store && host.rootView.appLock === appLock,
                         "Desktop created a separate data store or authentication session")
        try expectWindow(desktop.frame.width >= 1000 && desktop.frame.height >= 700, "Desktop hosting collapsed the native window frame")
        try expectWindow(NSApp.activationPolicy() == .regular, "Desktop is missing from the Dock and Command–Tab")
        let baseline = store.visitSummary?.since
        try expectWindow(baseline != nil, "Desktop did not begin its comparison visit")
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(desktop.isVisible, "Opening the dropdown hid the desktop window")
        popover.performClose(nil)
        store.beginVisit()
        try expectWindow(store.visitSummary?.since == baseline, "Dropdown reopening reset the desktop comparison baseline")
        try await sendWindowAction("showSettings", to: delegate)
        try expectWindow(desktop.isVisible, "Settings hid the desktop dashboard")
        try expectWindow(NSApp.sendAction(NSSelectorFromString("searchDesktop"), to: delegate, from: nil), "Desktop search action was not connected")
        try await waitForWindowState("desktop search") { navigation.section == .activity && desktop.isKeyWindow }
        try expectWindow(desktopWindow() === desktop, "Search created a duplicate desktop window")
        try await runAccountFilterChecks(desktop, navigation: navigation)
        navigation.selectBank("Sample Bank")
        navigation.selectAccount("spending")
        navigation.search = "coffee"
        try expectWindow(navigation.section == .activity && navigation.accountID == "spending", "Account navigation did not scope activity")
        try await performWindowTransition("desktop minimization", completion: NSWindow.didMiniaturizeNotification, window: desktop) {
            desktop.performMiniaturize(nil)
        }
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(desktop.isMiniaturized && popover.isShown, "Minimized desktop blocked the normal menu-bar dropdown")
        try await performWindowTransition("desktop restoration", completion: NSWindow.didDeminiaturizeNotification, window: desktop) {
            try expectWindow(NSApp.sendAction(NSSelectorFromString("openDesktop"), to: delegate, from: nil), "Desktop reopen failed")
        }
        try expectWindow(desktopWindow() === desktop, "Reopening created a second desktop window")
        try expectWindow(NSApp.sendAction(NSSelectorFromString("lockReckon"), to: delegate, from: nil), "Lock action was not connected")
        try await waitForWindowState("shared desktop lock") { !appLock.isUnlocked && !popover.isShown }
        try expectWindow(navigation.search.isEmpty && navigation.bankID == nil && navigation.accountID == nil && navigation.transactionID == nil,
                         "Lock retained private desktop search or selection")
        try expectWindow(desktop.isVisible, "Desktop lock removed the window instead of its private content")
        try expectWindow(NSApp.sendAction(NSSelectorFromString("unlockDesktop"), to: delegate, from: nil), "Desktop unlock was not connected")
        try await waitForWindowState("demo desktop unlock") { appLock.isUnlocked }
        desktop.setContentSize(NSSize(width: 1100, height: 740))
        let size = desktop.frame.size
        desktop.close()
        try await waitForWindowState("desktop closed") { desktopWindow() == nil }
        try await sendWindowAction("toggleDashboard", to: delegate)
        try expectWindow(popover.isShown, "Closing the desktop disabled the menu-bar icon")
        try expectWindow(NSApp.sendAction(NSSelectorFromString("openDesktop"), to: delegate, from: nil), "Desktop could not reopen after close")
        try await waitForWindowState("desktop frame restoration") { desktopWindow()?.occlusionState.contains(.visible) == true }
        guard let reopened = desktopWindow() else { throw WindowCheckFailure(description: "Desktop did not reopen") }
        try expectWindow(abs(reopened.frame.width - size.width) < 2 && abs(reopened.frame.height - size.height) < 2,
                         "Desktop did not retain the resized window frame")
        reopened.close()
    }

    @MainActor private static func runAccountFilterChecks(_ window: NSWindow, navigation: ReckonDesktopNavigation) async throws {
        try await waitForWindowState("account selector layout") {
            guard let content = window.contentView, let button = accountFilterButton(in: content) else { return false }
            return button.bounds.width >= 250 && button.bounds.height >= 40
        }
        guard let content = window.contentView, let button = accountFilterButton(in: content) else {
            throw WindowCheckFailure(description: "Desktop activity is missing its native account selector")
        }
        try expectWindow(window.makeFirstResponder(button) && window.firstResponder === button && button.canBecomeKeyView,
                         "Account selector cannot receive keyboard focus")
        for x in [CGFloat(1), CGFloat(20), button.bounds.midX, button.bounds.maxX - 1] {
            let point = button.convert(NSPoint(x: x, y: button.bounds.midY), to: content.superview)
            try expectWindow(content.hitTest(point) === button, "Account selector has an unclickable logo, label, or empty area")
        }
        guard let item = button.menu?.items.first(where: { $0.title == "Rainy day · NZD" }), let action = item.action else {
            throw WindowCheckFailure(description: "Account selector is missing the sample savings account")
        }
        try expectWindow(NSApp.sendAction(action, to: item.target, from: item), "Native account selection was not connected")
        try expectWindow(navigation.bankID == "Sample Bank" && navigation.accountID == "savings",
                         "Native account menu did not apply its bank and account scope")
    }

    @MainActor private static func accountFilterButton(in view: NSView) -> BankAccountFilterButton? {
        if let button = view as? BankAccountFilterButton { return button }
        for child in view.subviews {
            if let button = accountFilterButton(in: child) { return button }
        }
        return nil
    }

    @MainActor private static func desktopWindow() -> NSWindow? {
        NSApp.windows.first { $0.title == "Reckon" && $0.isVisible }
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
            if shouldOpen && !NSApp.isActive && popover.isShown {
                throw WindowCheckFailure(description: "Dropdown opened before application activation completed")
            }
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

import AppKit
import Combine
import ReckonCore
import SwiftUI
import UserNotifications

@MainActor
final class ReckonApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var store: BankDashboardStore!
    private var appLock: ReckonAppLock!
    private var shortcut: ReckonKeyboardShortcut!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var unlockTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        store = BankDashboardStore(isDemo: isDemo)
        appLock = ReckonAppLock(authenticator: isDemo ? ReckonDemoAuthentication() : ReckonTouchID())
        shortcut = ReckonKeyboardShortcut()
        shortcut.onActivate = { [weak self] in self?.toggleDashboard() }
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleDashboard)
        statusItem.button?.imagePosition = .imageOnly
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        appLock.onLock = { [weak self] in self?.dismissDashboard() }

        store.objectWillChange.sink { [weak self] _ in self?.scheduleStatusUpdate() }.store(in: &subscriptions)
        appLock.objectWillChange.sink { [weak self] _ in self?.scheduleStatusUpdate() }.store(in: &subscriptions)
        updateStatusItem()

        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockReckon() }
            })
        }
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "Quit Reckon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        NSApp.mainMenu = menu
        if ProcessInfo.processInfo.arguments.contains("--preview") {
            openDashboard(inPreview: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLock?.lock()
        store?.shutdown()
        shortcut?.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDashboard()
        return false
    }

    @objc private func toggleDashboard() {
        if appLock.state == .authenticating {
            lockReckon()
        } else if popover.isShown {
            popover.performClose(nil)
        } else {
            openDashboard()
        }
    }

    private func openDashboard(inPreview: Bool = false) {
        guard unlockTask == nil else { return }
        appLock.expireSessionIfNeeded()
        if appLock.isUnlocked {
            if let settingsWindow, settingsWindow.isVisible { settingsWindow.makeKeyAndOrderFront(nil) }
            else { showDashboard(inPreview: inPreview) }
            return
        }
        popover.performClose(nil)
        unlockTask = Task { [weak self] in
            guard let self else { return }
            let unlocked = await self.appLock.unlock()
            guard !Task.isCancelled else { return }
            self.unlockTask = nil
            if unlocked {
                self.showDashboard(inPreview: inPreview)
            } else {
                self.showLockedPopover()
            }
        }
    }

    private func showDashboard(inPreview: Bool) {
        guard appLock.isUnlocked else { return }
        store.beginVisit()
        NSApp.activate(ignoringOtherApps: true)
        let content = ReckonProtectedView(appLock: appLock) { [weak self, store = self.store!] in
            BankDashboardView(store: store, openSettings: { [weak self] in self?.showSettings() },
                              lockReckon: { [weak self] in self?.lockReckon() },
                              dismissDashboard: { [weak self] in self?.dismissDashboard() })
        }
        if inPreview {
            popover.performClose(nil)
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.title = "Reckon Preview"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            previewWindow = window
            window.makeKeyAndOrderFront(nil)
        } else {
            setPopoverContent(content)
            showPopover()
        }
        updateStatusItem()
    }

    private func showLockedPopover() {
        setPopoverContent(ReckonLockedView(appLock: appLock,
            unlock: { [weak self] in self?.openDashboard() }))
        showPopover()
    }

    private func setPopoverContent<Content: View>(_ content: Content) {
        let controller = NSHostingController(rootView: content.fixedSize())
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller
        popover.contentSize = controller.view.fittingSize
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showSettings() {
        guard appLock.isUnlocked else { return }
        let window = NSWindow(contentViewController: NSHostingController(rootView: ReckonProtectedView(appLock: appLock) { [weak self, store = self.store!] in
            if let shortcut = self?.shortcut {
                ReckonPreferencesView(store: store, shortcut: shortcut, close: { [weak self] in self?.settingsWindow?.close() })
            }
        }))
        window.title = "Reckon Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        popover.performClose(nil)
        previewWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func popoverDidClose(_ notification: Notification) { store.endVisit() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.openDashboard() }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === settingsWindow { settingsWindow = nil }
            if window === previewWindow { store.endVisit(); previewWindow = nil }
        }
    }

    private func lockReckon() {
        unlockTask?.cancel()
        unlockTask = nil
        appLock.lock()
        updateStatusItem()
    }

    private func dismissDashboard() {
        store.endVisit()
        popover.performClose(nil)
        settingsWindow?.orderOut(nil)
        previewWindow?.orderOut(nil)
        settingsWindow = nil
        previewWindow = nil
    }

    private func scheduleStatusUpdate() {
        Task { [weak self] in self?.updateStatusItem() }
    }

    private func updateStatusItem() {
        let unlocked = appLock.isUnlocked
        statusItem.button?.title = ""
        statusItem.button?.image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: nil)
        statusItem.button?.setAccessibilityLabel(unlocked ? "Reckon. Liquid balance \(store.menuBarTitle)" : "Reckon. Locked. Unlock with Touch ID")
    }
}

private struct ReckonProtectedView<Content: View>: View {
    @ObservedObject var appLock: ReckonAppLock
    @ViewBuilder let content: () -> Content

    var body: some View {
        if appLock.isUnlocked { content() }
        else { Text("Reckon is locked.").padding(30).frame(width: 410) }
    }
}

private struct ReckonLockedView: View {
    @ObservedObject var appLock: ReckonAppLock
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "touchid").font(.system(size: 38)).foregroundStyle(.secondary)
            Text("Reckon is locked").font(.system(.title2, design: .serif).weight(.semibold))
            Text(appLock.errorMessage ?? "Use Touch ID to view your accounts.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(appLock.state == .authenticating ? "Waiting for Touch ID…" : "Unlock with Touch ID", action: unlock)
                .disabled(appLock.state == .authenticating)
            Button("Quit Reckon") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(28).frame(width: 410).background(.regularMaterial)
    }
}

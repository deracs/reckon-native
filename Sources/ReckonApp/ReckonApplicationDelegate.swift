import AppKit
import Combine
import ReckonCore
import SwiftUI
import UserNotifications

@MainActor
final class ReckonApplicationDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation, UNUserNotificationCenterDelegate {
    private var store: BankDashboardStore!
    private var appLock: ReckonAppLock!
    private var shortcut: ReckonKeyboardShortcut!
    private var softwareUpdates: ReckonSoftwareUpdates!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var desktopWindow: NSWindow?
    private let desktopNavigation = ReckonDesktopNavigation()
    private var unlockTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        store = BankDashboardStore(isDemo: isDemo)
        appLock = ReckonAppLock(authenticator: isDemo ? ReckonDemoAuthentication() : ReckonLocalAuthentication())
        softwareUpdates = ReckonSoftwareUpdates(isDemo: isDemo)
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
        appLock.onLock = { [weak self] in self?.handleDesktopLock() }

        store.objectWillChange.sink { [weak self] _ in self?.scheduleStatusUpdate() }.store(in: &subscriptions)
        appLock.objectWillChange.sink { [weak self] _ in self?.scheduleStatusUpdate() }.store(in: &subscriptions)
        updateStatusItem()

        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification,
                     NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.lockReckon() }
            })
        }
        installApplicationMenu()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--desktop") {
            openDesktop()
            if isDemo { unlockDesktop() }
        } else if arguments.contains("--preview") {
            openDashboard(inPreview: true)
        } else if !isDemo && ReckonDesktopPreferences.opensAtLaunch {
            openDesktop()
        }
    }

    private func installApplicationMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        let settingsItem = applicationMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        applicationMenu.addItem(.separator())
        let updateItem = applicationMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForSoftwareUpdates), keyEquivalent: "")
        updateItem.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Quit Reckon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editMenu = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(action), keyEquivalent: key)
        }
        editMenu.addItem(.separator())
        let findItem = editMenu.addItem(withTitle: "Find Activity…", action: #selector(searchDesktop), keyEquivalent: "f")
        findItem.target = self
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        let viewMenu = NSMenu(title: "View")
        for (index, section) in ReckonDashboardSection.allCases.enumerated() {
            let item = viewMenu.addItem(withTitle: section.shortLabel, action: #selector(selectDesktopSection(_:)), keyEquivalent: String(index + 1))
            item.tag = index
            item.target = self
        }
        let viewItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        viewItem.submenu = viewMenu
        menu.addItem(viewItem)
        let windowMenu = NSMenu(title: "Window")
        let desktopItem = windowMenu.addItem(withTitle: "Open Reckon", action: #selector(openDesktop), keyEquivalent: "0")
        desktopItem.target = self
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(showSettings) || menuItem.action == #selector(searchDesktop)
            || menuItem.action == #selector(selectDesktopSection(_:)) { return appLock.isUnlocked }
        if menuItem.action == #selector(checkForSoftwareUpdates) { return softwareUpdates.canCheckForUpdates }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        appLock?.lock()
        store?.shutdown()
        shortcut?.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openDesktop()
        return false
    }

    /// The desktop window and dropdown share one store, updater, and ten-minute unlock session.
    @objc private func openDesktop() {
        appLock.expireSessionIfNeeded()
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if desktopWindow == nil {
            let root = ReckonDesktopView(store: store, appLock: appLock, navigation: desktopNavigation, softwareUpdates: softwareUpdates,
                openSettings: { [weak self] in self?.showSettings() }, unlock: { [weak self] in self?.unlockDesktop() },
                lock: { [weak self] in self?.lockReckon() }, openSoftwareUpdate: { [weak self] in self?.checkForSoftwareUpdates() })
            let controller = NSHostingController(rootView: root)
            controller.sizingOptions = []
            controller.safeAreaRegions = []
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Reckon"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.appearance = NSAppearance(named: .aqua)
            window.contentViewController = controller
            window.contentMinSize = NSSize(width: 1000, height: 700)
            // Hosting replaces the original content frame; size the resizable window after attachment.
            window.setContentSize(NSSize(width: 1180, height: 800))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            window.setFrameAutosaveName("ReckonDesktop")
            if !window.setFrameUsingName("ReckonDesktop") { window.center() }
            if window.frame.width < 1000 || window.frame.height < 700 {
                window.setContentSize(NSSize(width: 1180, height: 800))
                window.center()
            }
            desktopWindow = window
        }
        if desktopWindow?.isMiniaturized == true { desktopWindow?.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        desktopWindow?.makeKeyAndOrderFront(nil)
        popover.performClose(nil)
        if appLock.isUnlocked { store.beginVisit(); softwareUpdates.checkWhenOpened() }
    }

    @objc private func unlockDesktop() {
        guard unlockTask == nil else { return }
        unlockTask = Task { [weak self] in
            guard let self else { return }
            let unlocked = await self.appLock.unlock()
            guard !Task.isCancelled else { return }
            self.unlockTask = nil
            if unlocked {
                self.store.beginVisit()
                self.softwareUpdates.checkWhenOpened()
            }
        }
    }

    @objc private func searchDesktop() {
        openDesktop()
        if appLock.isUnlocked { desktopNavigation.focusActivitySearch() }
    }

    @objc private func selectDesktopSection(_ item: NSMenuItem) {
        guard appLock.isUnlocked, ReckonDashboardSection.allCases.indices.contains(item.tag) else { return }
        openDesktop()
        desktopNavigation.selectSection(ReckonDashboardSection.allCases[item.tag])
    }

    @objc private func checkForSoftwareUpdates() {
        guard softwareUpdates.canCheckForUpdates else { return }
        dismissDashboard()
        NSApp.activate(ignoringOtherApps: true)
        softwareUpdates.checkForUpdates()
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

    /// Menu-bar, shortcut, and reopen actions show the dashboard even when Settings is open.
    private func openDashboard(inPreview: Bool = false) {
        guard unlockTask == nil else { return }
        appLock.expireSessionIfNeeded()
        if appLock.isUnlocked {
            showDashboard(inPreview: inPreview)
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
        softwareUpdates.checkWhenOpened()
        store.beginVisit()
        NSApp.activate(ignoringOtherApps: true)
        let content = ReckonProtectedView(appLock: appLock) { [weak self, store = self.store!, softwareUpdates = self.softwareUpdates!] in
            BankDashboardView(store: store, softwareUpdates: softwareUpdates,
                              openSettings: { [weak self] in self?.showSettings() },
                              openDesktop: { [weak self] in self?.openDesktop() },
                              openSoftwareUpdate: { [weak self] in self?.checkForSoftwareUpdates() },
                              lockReckon: { [weak self] in self?.lockReckon() },
                              dismissDashboard: { [weak self] in self?.dismissDashboard() },
                              isWindow: inPreview)
        }
        if inPreview {
            popover.performClose(nil)
            let window = makeReckonWindow(title: "Reckon Preview", content: content)
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

    @objc private func showSettings() {
        guard appLock.isUnlocked else { return }
        softwareUpdates.checkWhenOpened()
        if let settingsWindow {
            popover.performClose(nil)
            settingsWindow.deminiaturize(nil)
            NSApp.activate(ignoringOtherApps: true)
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = makeReckonWindow(title: "Reckon Settings", content: ReckonProtectedView(appLock: appLock) { [weak self, store = self.store!] in
            if let shortcut = self?.shortcut, let softwareUpdates = self?.softwareUpdates {
                ReckonPreferencesView(store: store, shortcut: shortcut, softwareUpdates: softwareUpdates, close: { [weak self] in self?.settingsWindow?.close() })
            }
        })
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        settingsWindow = window
        popover.performClose(nil)
        previewWindow?.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Blends the native title bar into the content while keeping Mac window controls.
    private func makeReckonWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = [.intrinsicContentSize]
        controller.safeAreaRegions = []
        let contentSize = controller.view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: contentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = ReckonAppearance.canvasColor
        window.contentViewController = controller
        window.setFrame(NSRect(origin: window.frame.origin, size: contentSize), display: false)
        return window
    }

    func popoverDidClose(_ notification: Notification) { endVisitIfDashboardHidden() }

    private func endVisitIfDashboardHidden() {
        guard !popover.isShown, desktopWindow?.isVisible != true, previewWindow?.isVisible != true else { return }
        store.endVisit()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else { return }
        appLock.expireSessionIfNeeded()
        if appLock.isUnlocked { store.beginVisit() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        await MainActor.run { self.openDesktop() }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === settingsWindow { settingsWindow = nil }
            if window === previewWindow { previewWindow = nil }
            if window === desktopWindow {
                window.saveFrame(usingName: "ReckonDesktop")
                desktopWindow = nil
            }
            endVisitIfDashboardHidden()
        }
    }

    @objc private func lockReckon() {
        unlockTask?.cancel()
        unlockTask = nil
        appLock.lock()
        updateStatusItem()
    }

    private func dismissDashboard() {
        popover.performClose(nil)
        previewWindow?.close()
        endVisitIfDashboardHidden()
    }

    private func handleDesktopLock() {
        desktopNavigation.clearPrivateSelection()
        settingsWindow?.close()
        dismissDashboard()
        store.endVisit()
    }

    private func scheduleStatusUpdate() {
        Task { [weak self] in self?.updateStatusItem() }
    }

    private func updateStatusItem() {
        let unlocked = appLock.isUnlocked
        statusItem.button?.title = ""
        statusItem.button?.image = unlocked ? ReckonStatusIcon.unlocked : ReckonStatusIcon.locked
        statusItem.button?.setAccessibilityLabel(unlocked ? "Reckon. Liquid balance \(store.menuBarTitle)" : "Reckon. Locked. Unlock Reckon")
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
            Image(systemName: "lock.shield").font(.system(size: 38)).foregroundStyle(.secondary)
            Text("Reckon is locked").font(.system(.title2).weight(.semibold))
            Text(appLock.errorMessage ?? "Use Touch ID, Apple Watch, or your Mac login password to view your accounts.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(appLock.state == .authenticating ? "Unlock in the macOS prompt…" : "Unlock Reckon", action: unlock)
                .disabled(appLock.state == .authenticating)
            Button("Quit Reckon") { NSApp.terminate(nil) }.buttonStyle(.borderless)
        }
        .padding(28).frame(width: 430).background(ReckonAppearance.background)
        .tint(ReckonAppearance.accent)
    }
}

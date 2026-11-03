import AppKit

/// Supplies an isolated click-away target and yields activation back before the next menu-bar click.
@MainActor
final class ReckonWindowFocusHelper: NSObject, NSApplicationDelegate {
    private let parentID: pid_t
    private let readyURL: URL
    private var window: NSWindow?

    private init(parentID: pid_t, readyURL: URL) {
        self.parentID = parentID
        self.readyURL = readyURL
    }

    /// Runs only the dedicated focus-helper fixture, without starting Reckon or reading credentials.
    static func runFocusHelperIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.count == 4, arguments[1] == "--focus-helper",
              let parentID = pid_t(arguments[2]) else { return false }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = ReckonWindowFocusHelper(parentID: parentID, readyURL: URL(fileURLWithPath: arguments[3]))
        application.delegate = delegate
        // Do not leave a fixture app running if the parent check is interrupted.
        Task { @MainActor in
            while NSRunningApplication(processIdentifier: parentID) != nil {
                try? await Task.sleep(for: .seconds(1))
            }
            application.terminate(nil)
        }
        withExtendedLifetime(delegate) { application.run() }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window?.title = "Reckon window check"
        window?.center()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard let parent = NSRunningApplication(processIdentifier: parentID) else {
            NSApp.terminate(nil)
            return
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.yieldActivation(to: parent)
        // Signal only after the next simulated menu click has permission to reactivate the parent.
        do { try Data().write(to: readyURL, options: .atomic) }
        catch { NSApp.terminate(nil) }
    }
}

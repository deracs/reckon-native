import AppKit

@main
struct ReckonMenuBarApp {
    @MainActor static func main() {
        AkahuCredentialImport.runIfRequested()
        ReckonLoginItem.runCommandIfRequested()
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = ReckonApplicationDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

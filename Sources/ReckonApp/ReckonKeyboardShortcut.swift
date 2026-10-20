import AppKit
import Carbon
import Combine

@MainActor
final class ReckonKeyboardShortcut: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message: String?
    var onActivate: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<ReckonKeyboardShortcut>.fromOpaque(context).takeUnretainedValue().onActivate?()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { message = "Could not register the keyboard shortcut."; return }
        setEnabled(UserDefaults.standard.object(forKey: "globalShortcutEnabled") as? Bool ?? true)
    }

    func setEnabled(_ enabled: Bool) {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        isEnabled = false
        message = nil
        if enabled {
            let identifier = EventHotKeyID(signature: 0x52434B4E, id: 1)
            let status = RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey), identifier,
                                             GetApplicationEventTarget(), 0, &hotKey)
            guard status == noErr else {
                message = "Control–Option–R is in use by another app. Disable its shortcut and try again."
                return
            }
            isEnabled = true
        }
        UserDefaults.standard.set(isEnabled, forKey: "globalShortcutEnabled")
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}

import Carbon.HIToolbox
import Foundation

/// System-wide hotkeys via Carbon `RegisterEventHotKey`. Chosen over an NSEvent global
/// monitor because it needs no Accessibility permission and fires even when AgentBar
/// isn't focused. Singleton because the Carbon event handler is a C callback with no
/// captured context — it dispatches through `shared`.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false
    private var nextID: UInt32 = 1

    /// Turn the Allow/Deny hotkeys on or off. ⌥⌘A → allow, ⌥⌘D → deny.
    func setEnabled(_ enabled: Bool, allow: @escaping () -> Void, deny: @escaping () -> Void) {
        unregisterAll()
        guard enabled else { return }
        installHandlerIfNeeded()
        let mods = UInt32(optionKey | cmdKey)
        register(keyCode: UInt32(kVK_ANSI_A), modifiers: mods, handler: allow)
        register(keyCode: UInt32(kVK_ANSI_D), modifiers: mods, handler: deny)
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            HotKeyCenter.shared.handlers[hkID.id]?()
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) {
        let id = nextID; nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x41474254), id: id) // 'AGBT'
        if RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref { refs.append(ref) }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}

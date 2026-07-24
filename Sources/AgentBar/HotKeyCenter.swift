import Carbon.HIToolbox
import Foundation

/// One recordable key combination (Carbon key code + modifier mask) plus its
/// human-readable form ("⌥⌘A"). Persisted to UserDefaults as a small dictionary
/// so users can rebind the global Allow/Deny keys in Settings.
struct KeyCombo: Equatable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let display: String

    static let defaultAllow = KeyCombo(keyCode: UInt32(kVK_ANSI_A),
                                       carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘A")
    static let defaultDeny = KeyCombo(keyCode: UInt32(kVK_ANSI_D),
                                      carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘D")

    /// The currently configured combos (defaults when never customized).
    static var allow: KeyCombo { stored("allowHotKey", fallback: .defaultAllow) }
    static var deny: KeyCombo { stored("denyHotKey", fallback: .defaultDeny) }

    static func stored(_ key: String, fallback: KeyCombo) -> KeyCombo {
        guard let d = UserDefaults.standard.dictionary(forKey: key),
              let code = (d["keyCode"] as? NSNumber)?.uint32Value,
              let mods = (d["modifiers"] as? NSNumber)?.uint32Value,
              let display = d["display"] as? String else { return fallback }
        return KeyCombo(keyCode: code, carbonModifiers: mods, display: display)
    }

    func store(as key: String) {
        UserDefaults.standard.set(["keyCode": NSNumber(value: keyCode),
                                   "modifiers": NSNumber(value: carbonModifiers),
                                   "display": display], forKey: key)
    }
}

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

    /// Turn the Allow/Deny hotkeys on or off with the given combos.
    func setEnabled(_ enabled: Bool, allow: KeyCombo, deny: KeyCombo,
                    onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
        unregisterAll()
        guard enabled else { return }
        installHandlerIfNeeded()
        register(combo: allow, handler: onAllow)
        register(combo: deny, handler: onDeny)
    }

    /// Release the registrations without forgetting the configuration — used while
    /// the Settings recorder captures keystrokes, so pressing the current combo
    /// records it instead of firing an answer. Re-enable via `setEnabled`.
    func suspend() {
        unregisterAll()
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

    private func register(combo: KeyCombo, handler: @escaping () -> Void) {
        let id = nextID; nextID += 1
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x41474254), id: id) // 'AGBT'
        if RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hkID,
                               GetApplicationEventTarget(), 0, &ref) == noErr,
           let ref { refs.append(ref) }
    }

    private func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
}

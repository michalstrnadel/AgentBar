import Cocoa

/// When the keyboard's backlight goes dark while Keep Mac Awake holds the Mac up,
/// from plain values.
///
/// A Mac kept awake with its screen on keeps its keyboard lit too, all night, and
/// the presence nudge relights it every four minutes even where macOS would have
/// dimmed it. So: dark half a minute after the person's last input, lit again at
/// their next one. The idle clock is the human one (`InputIdle.seconds`), so our
/// own nudge never counts as somebody coming back.
enum KeyboardLightPolicy {
    /// No input for this long and the light goes off.
    static let awayAfter: TimeInterval = 30
    /// Input this recent and it comes back. Polled four times a second while dark,
    /// so the first keystroke finds the keys lit.
    static let backWithin: TimeInterval = 1

    static func shouldBeDark(active: Bool, humanIdle: TimeInterval, dark: Bool) -> Bool {
        guard active else { return false }
        return dark ? humanIdle >= backWithin : humanIdle >= awayAfter
    }
}

/// The built-in keyboard's backlight, through CoreBrightness's
/// `KeyboardBrightnessClient` — the client Control Center's keyboard brightness
/// slider uses. It is a private framework, so every selector is checked before it
/// is called and a Mac without it (or without a backlit keyboard: an iMac, a Mac
/// mini) simply has no `KeyboardBacklight`.
///
/// Brightness is set with `commit: false`: the person's own setting is never
/// rewritten, only what the keys show right now.
final class KeyboardBacklight {
    private let client: NSObject
    private let cls: AnyClass
    private let id: UInt64

    private typealias GetFloat = @convention(c) (AnyObject, Selector, UInt64) -> Float
    private typealias GetBool = @convention(c) (AnyObject, Selector, UInt64) -> Bool
    private typealias SetLevel = @convention(c) (AnyObject, Selector, Float, Int32, Bool, UInt64) -> Bool

    private static let brightnessSel = NSSelectorFromString("brightnessForKeyboard:")
    private static let dimmedSel = NSSelectorFromString("isBacklightDimmedOnKeyboard:")
    private static let builtInSel = NSSelectorFromString("isKeyboardBuiltIn:")
    private static let setSel = NSSelectorFromString("setBrightness:fadeSpeed:commit:forKeyboard:")
    private static let idsSel = NSSelectorFromString("copyKeyboardBacklightIDs")

    /// The built-in backlit keyboard, or nil.
    static let builtIn: KeyboardBacklight? = KeyboardBacklight()

    private init?() {
        guard dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY) != nil,
              let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type else { return nil }
        let client = cls.init()
        for sel in [Self.brightnessSel, Self.dimmedSel, Self.builtInSel, Self.setSel, Self.idsSel]
        where !client.responds(to: sel) { return nil }
        guard let ids = client.perform(Self.idsSel)?.takeRetainedValue() as? [NSNumber] else { return nil }
        self.cls = cls
        self.client = client
        let builtInImp = unsafeBitCast(class_getMethodImplementation(cls, Self.builtInSel), to: GetBool.self)
        guard let id = ids.map(\.uint64Value).first(where: { builtInImp(client, Self.builtInSel, $0) })
        else { return nil }
        self.id = id
    }

    /// 0…1, what the keys show now (0 while macOS has dimmed them).
    var brightness: Float {
        unsafeBitCast(class_getMethodImplementation(cls, Self.brightnessSel), to: GetFloat.self)(
            client, Self.brightnessSel, id)
    }

    /// macOS dimmed it for inactivity (Keyboard settings), as opposed to set low.
    var isDimmed: Bool {
        unsafeBitCast(class_getMethodImplementation(cls, Self.dimmedSel), to: GetBool.self)(
            client, Self.dimmedSel, id)
    }

    /// `fade` in milliseconds.
    func set(_ level: Float, fade: Int32) {
        _ = unsafeBitCast(class_getMethodImplementation(cls, Self.setSel), to: SetLevel.self)(
            client, Self.setSel, min(max(level, 0), 1), fade, false, id)
    }
}

/// Applies `KeyboardLightPolicy` while Keep Mac Awake is on and its setting is.
/// The level it darkened from is kept in the defaults until it is given back, so a
/// crash or a forced quit is mended at the next launch instead of leaving the keys
/// dark.
final class KeyboardLight {
    static let shared = KeyboardLight()

    private static let leftoverKey = "keyboardLightRestoreLevel"
    private var timer: Timer?
    private var active = false
    private var dark = false
    /// The last brightness seen while the keys were lit by the person's own
    /// setting: what "lit again" means.
    private var litLevel: Float?

    private init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.setActive(false)
        }
    }

    /// A backlit keyboard to look after, for Settings to decide whether to show it.
    static var isAvailable: Bool { KeyboardBacklight.builtIn != nil }

    /// Gives back a level an earlier run darkened and never restored. At launch.
    func restoreLeftover(_ d: UserDefaults = .standard) {
        guard let level = d.object(forKey: Self.leftoverKey) as? Float else { return }
        d.removeObject(forKey: Self.leftoverKey)
        guard level > 0, let kb = KeyboardBacklight.builtIn, kb.brightness == 0 else { return }
        kb.set(level, fade: 0)
    }

    func setActive(_ on: Bool) {
        let on = on && KeyboardBacklight.builtIn != nil
        guard on != active else { return }
        active = on
        if on {
            tick()
        } else {
            if dark { light() }
            timer?.invalidate()
            timer = nil
        }
    }

    private func schedule() {
        let interval: TimeInterval = dark ? 0.25 : 2
        guard timer?.timeInterval != interval else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = interval / 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard active, let kb = KeyboardBacklight.builtIn else { return }
        if !dark {
            let level = kb.brightness
            if level > 0, !kb.isDimmed { litLevel = level }
        }
        let want = KeyboardLightPolicy.shouldBeDark(active: true, humanIdle: InputIdle.seconds(), dark: dark)
        if want, !dark, let litLevel {
            UserDefaults.standard.set(litLevel, forKey: Self.leftoverKey)
            kb.set(0, fade: 600)
            dark = true
        } else if !want, dark {
            light()
        }
        schedule()
    }

    private func light() {
        dark = false
        UserDefaults.standard.removeObject(forKey: Self.leftoverKey)
        if let litLevel { KeyboardBacklight.builtIn?.set(litLevel, fade: 0) }
    }
}

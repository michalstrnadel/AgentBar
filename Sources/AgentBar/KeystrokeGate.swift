import CoreGraphics
import Foundation

/// The decisions behind a posted keystroke, with no event posted and no app asked:
/// which app has to be in front, what each key becomes on the wire, and — before
/// every key — whether to send it now, wait, or give up and leave the prompt to
/// the human. `KeystrokeApprover` is the thin shell that feeds it the live
/// frontmost app and modifier state and posts what it says.
///
/// The invariant everything here serves: **a key never lands in the wrong app,
/// and never as a different key.** A Return typed into whatever the user was
/// writing, or a Return that arrives as ⌘Return because ⌘ was down, is worse than
/// an approval that did not happen — the prompt is still on screen for the person.
enum KeystrokeGate {
    /// How long the target gets to come forward. A missed approval beats an early
    /// keystroke, and the frontmost check is what makes waiting safe.
    static let activationCeiling: TimeInterval = 2.0
    /// How long a held modifier gets to be let go before a key that is due. Short:
    /// somebody holding ⌘ is in the middle of something, and it isn't our prompt.
    static let modifierCeiling: TimeInterval = 0.6
    static let pollInterval: TimeInterval = 0.05
    /// Between consecutive keys of one mapping ("y" then Return): a terminal can
    /// drop the second key if both arrive in the same pass of its input loop.
    static let keyStagger: TimeInterval = 0.05

    /// The modifiers a person physically holds. Caps Lock is not among them: it is
    /// a latch nobody can be waited on to release, and the posted event carries
    /// explicit flags either way.
    static let heldModifierMask: CGEventFlags = [
        .maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn,
    ]

    static func heldModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        flags.intersection(heldModifierMask)
    }

    /// The app that has to own the keyboard before a key is posted. `landedIn` is
    /// what `TerminalFocus` reported bringing forward and wins (in tmux it is the
    /// host terminal, not "tmux"); a desktop Antigravity session lives in its app;
    /// everything else is the terminal TERM_PROGRAM names.
    static func targetApp(entrypoint: String, termProgram: String, landedIn: String?) -> String {
        if let landedIn { return landedIn }
        if entrypoint == "antigravity-app" { return "Antigravity" }
        return TerminalApp.appName(forTermProgram: termProgram)
    }

    /// Whether the frontmost app is `target`. Matched against both the localized
    /// name and the bundle's file name, which disagree for some apps (iTerm2, Code).
    /// No frontmost app at all is never a match.
    static func isTarget(_ target: String, localizedName: String?, bundleName: String?) -> Bool {
        guard !target.isEmpty else { return false }
        return localizedName?.caseInsensitiveCompare(target) == .orderedSame
            || bundleName?.caseInsensitiveCompare(target) == .orderedSame
    }

    enum Phase: Equatable {
        /// Before the first key: the target is still coming forward.
        case activating
        /// Between keys: the target was in front a moment ago.
        case midSequence
    }

    enum Verdict: Equatable {
        case send
        case wait
        case giveUp(String)
    }

    /// One look before one key.
    ///
    /// - Activating, the target may not be in front yet: wait until it is, up to
    ///   `deadline`. Mid-sequence it already was, so it losing focus means the
    ///   person moved on — give up at once rather than wait for it to come back.
    /// - A held modifier waits for release up to `deadline` and then gives up; a
    ///   key is never sent with one down.
    static func verdict(phase: Phase, targetFront: Bool, held: CGEventFlags,
                        now: Date, deadline: Date) -> Verdict {
        if !targetFront, phase == .midSequence {
            return .giveUp("target lost focus mid-sequence")
        }
        let modifiers = heldModifiers(held)
        if targetFront, modifiers.isEmpty { return .send }
        guard now < deadline else {
            return .giveUp(targetFront ? "a modifier key stayed held" : "target never came forward")
        }
        return .wait
    }

    /// The deadline for the look before key `index`: the first key is waiting on
    /// activation, the others only ever on a modifier.
    static func deadline(forKeyAt index: Int, from start: Date) -> Date {
        start.addingTimeInterval(index == 0 ? activationCeiling : modifierCeiling)
    }

    struct KeyEvent: Equatable {
        let key: CGKeyCode
        let keyDown: Bool
        let flags: CGEventFlags

        static func == (a: KeyEvent, b: KeyEvent) -> Bool {
            a.key == b.key && a.keyDown == b.keyDown && a.flags.rawValue == b.flags.rawValue
        }
    }

    /// What one key becomes on the wire: a down and an up, each carrying exactly
    /// `flags` — empty for an approval key — so nothing the person is holding can
    /// ride along on it.
    static func events(for key: CGKeyCode, flags: CGEventFlags = []) -> [KeyEvent] {
        [KeyEvent(key: key, keyDown: true, flags: flags),
         KeyEvent(key: key, keyDown: false, flags: flags)]
    }
}

import CoreGraphics
import Foundation
import Testing
@testable import AgentBar

/// The part of keystroke approval that decides. Nothing here posts an event or
/// asks which app is in front; the invariant under test is that a key never lands
/// in the wrong app and never as a different key — and that every doubt ends with
/// nothing sent, leaving the prompt to the person.
@Suite struct KeystrokeGateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func verdict(_ phase: KeystrokeGate.Phase, front: Bool, held: CGEventFlags = [],
                         at offset: TimeInterval = 0) -> KeystrokeGate.Verdict {
        KeystrokeGate.verdict(phase: phase, targetFront: front, held: held,
                              now: t0.addingTimeInterval(offset),
                              deadline: KeystrokeGate.deadline(forKeyAt: phase == .activating ? 0 : 1, from: t0))
    }

    // MARK: - Whether to send

    @Test func sendsOnlyWhenTheTargetIsFrontAndNoModifierIsHeld() {
        #expect(verdict(.activating, front: true) == .send)
        #expect(verdict(.midSequence, front: true) == .send)
    }

    /// Cold start: the terminal is still coming forward. Waiting is safe because
    /// nothing goes out until it is in front; past the ceiling, nothing goes out.
    @Test func waitsForTheTargetToComeForwardThenGivesUp() {
        #expect(verdict(.activating, front: false, at: 0) == .wait)
        #expect(verdict(.activating, front: false, at: 1.9) == .wait)
        guard case .giveUp = verdict(.activating, front: false, at: KeystrokeGate.activationCeiling) else {
            Issue.record("a target that never came forward must give up"); return
        }
    }

    /// A target that was in front for the first key and isn't for the second means
    /// the person moved on: the second key would land in their app.
    @Test func losingFocusMidSequenceGivesUpAtOnce() {
        guard case .giveUp = verdict(.midSequence, front: false, at: 0) else {
            Issue.record("focus lost between keys must not be waited out"); return
        }
    }

    /// Return with ⌘ down is ⌘Return. A held modifier waits for release, briefly,
    /// and then the key is not sent at all.
    @Test func aHeldModifierWaitsForReleaseThenGivesUp() {
        for mod: CGEventFlags in [.maskCommand, .maskShift, .maskControl, .maskAlternate, .maskSecondaryFn] {
            #expect(verdict(.activating, front: true, held: mod, at: 0) == .wait)
            #expect(verdict(.midSequence, front: true, held: mod, at: 0) == .wait)
            guard case .giveUp = verdict(.midSequence, front: true, held: mod,
                                         at: KeystrokeGate.modifierCeiling) else {
                Issue.record("modifier \(mod.rawValue) held past the ceiling must give up"); continue
            }
        }
        // Released inside the window: the key goes.
        #expect(verdict(.midSequence, front: true, held: [], at: KeystrokeGate.modifierCeiling / 2) == .send)
    }

    /// Caps Lock is a latch, not a held key: waiting on it would never end. Mouse
    /// buttons and device bits in the flags word are not modifiers either.
    @Test func capsLockAndNonModifierBitsDoNotBlock() {
        #expect(verdict(.activating, front: true, held: .maskAlphaShift) == .send)
        #expect(verdict(.activating, front: true, held: [.maskNonCoalesced, .maskNumericPad]) == .send)
        #expect(KeystrokeGate.heldModifiers([.maskAlphaShift, .maskCommand]) == .maskCommand)
    }

    /// The modifier ceiling is shorter than the activation one: someone holding ⌘
    /// is busy with something else, and it isn't our prompt.
    @Test func deadlinesPerKey() {
        #expect(KeystrokeGate.deadline(forKeyAt: 0, from: t0) == t0.addingTimeInterval(KeystrokeGate.activationCeiling))
        #expect(KeystrokeGate.deadline(forKeyAt: 1, from: t0) == t0.addingTimeInterval(KeystrokeGate.modifierCeiling))
        #expect(KeystrokeGate.modifierCeiling < KeystrokeGate.activationCeiling)
        #expect(KeystrokeGate.keyStagger >= 0.03 && KeystrokeGate.keyStagger <= 0.1)
    }

    // MARK: - Which app

    @Test func frontmostMatchesByEitherName() {
        #expect(KeystrokeGate.isTarget("iTerm2", localizedName: "iTerm2", bundleName: "iTerm"))
        #expect(KeystrokeGate.isTarget("iTerm", localizedName: "iTerm2", bundleName: "iTerm"))
        #expect(KeystrokeGate.isTarget("terminal", localizedName: "Terminal", bundleName: "Terminal"))
        #expect(!KeystrokeGate.isTarget("Terminal", localizedName: "Safari", bundleName: "Safari"))
        // A name that merely contains the target is not it.
        #expect(!KeystrokeGate.isTarget("Code", localizedName: "Xcode", bundleName: "Xcode"))
        // No frontmost app, or nothing to aim at, is never a match.
        #expect(!KeystrokeGate.isTarget("Terminal", localizedName: nil, bundleName: nil))
        #expect(!KeystrokeGate.isTarget("", localizedName: "", bundleName: ""))
    }

    /// The tab `TerminalFocus` verified wins over TERM_PROGRAM: in tmux the app
    /// in front is the host terminal, not "tmux".
    @Test func targetAppPrefersWhereTheTabLanded() {
        #expect(KeystrokeGate.targetApp(entrypoint: "cli", termProgram: "tmux", landedIn: "iTerm2") == "iTerm2")
        #expect(KeystrokeGate.targetApp(entrypoint: "antigravity-app", termProgram: "", landedIn: nil) == "Antigravity")
        #expect(KeystrokeGate.targetApp(entrypoint: "cli", termProgram: "Apple_Terminal", landedIn: nil)
                == TerminalApp.appName(forTermProgram: "Apple_Terminal"))
    }

    // MARK: - What goes on the wire

    /// Every approval key is a down and an up with no flags at all, so nothing the
    /// person holds can ride along.
    @Test func approvalKeysCarryNoFlags() {
        let mapped = Agent.all.compactMap(\.approveKeys)
        #expect(!mapped.isEmpty)
        for keys in mapped + [[19]] {   // [19] is the plan dialog's "2"
            for key in keys {
                let events = KeystrokeGate.events(for: key)
                #expect(events.map(\.keyDown) == [true, false])
                #expect(events.allSatisfy { $0.key == key && $0.flags.isEmpty })
            }
        }
    }

    @Test func pasteCarriesOnlyCommand() {
        let events = KeystrokeGate.events(for: 9, flags: .maskCommand)
        #expect(events.allSatisfy { $0.flags == .maskCommand })
    }
}

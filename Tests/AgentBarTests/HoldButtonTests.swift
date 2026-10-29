import Foundation
import Testing
@testable import AgentBar

/// A held Allow answers only once the hold is complete. Everything else — let go
/// early, slid off, pressed twice — answers nothing.
@MainActor @Suite(.serialized) struct HoldButtonTests {
    private func button(hold: TimeInterval, count: @escaping () -> Void) -> HoldButton {
        return HoldButton(title: "Allow", hint: nil, hold: hold, onCommit: count)
    }

    @Test func letGoEarlyAnswersNothing() {
        var answers = 0
        let b = button(hold: 1.2) { answers += 1 }
        b.press(at: 100)
        b.tick(at: 100.5)
        b.release(at: 101.0)
        #expect(answers == 0)
        #expect(b.progress == 0)
        #expect(b.pressedAt == nil)
    }

    @Test func heldToTheEndAnswersOnce() {
        var answers = 0
        let b = button(hold: 0.6) { answers += 1 }
        b.press(at: 10)
        b.tick(at: 10.3)
        #expect(answers == 0)
        b.tick(at: 10.6)
        #expect(answers == 1)
        b.release(at: 10.7)
        b.press(at: 11)
        b.tick(at: 12)
        #expect(answers == 1)
    }

    @Test func releasedAfterTheHoldStillAnswers() {
        // A timer that slipped a frame must not cost the answer the person held for.
        var answers = 0
        let b = button(hold: 0.6) { answers += 1 }
        b.press(at: 0)
        b.release(at: 0.65)
        #expect(answers == 1)
    }

    @Test func slidingOffTakesAPressBack() {
        var answers = 0
        let plain = button(hold: 0) { answers += 1 }
        plain.press(at: 0)
        plain.release(inside: false, at: 0.1)
        #expect(answers == 0)
        plain.press(at: 1)
        plain.release(inside: true, at: 1.1)
        #expect(answers == 1)
    }

    @Test func cancelledHoldAnswersNothing() {
        var answers = 0
        let b = button(hold: 0.6) { answers += 1 }
        b.press(at: 0)
        b.cancel()
        b.tick(at: 5)
        b.release(at: 5)
        #expect(answers == 0)
    }

    @Test func holdFollowsTheSeverity() {
        UserDefaults.standard.removeObject(forKey: HoldButton.enabledKey)
        let high = [BlastRadius.chip(.privileged)], medium = [BlastRadius.chip(.network)]
        #expect(HoldButton.duration(for: []) == 0)
        #expect(HoldButton.duration(for: medium) == 0.6)
        #expect(HoldButton.duration(for: high) == 1.2)
        UserDefaults.standard.set(false, forKey: HoldButton.enabledKey)
        #expect(HoldButton.duration(for: high) == 0)
        UserDefaults.standard.removeObject(forKey: HoldButton.enabledKey)
    }

    @Test func queueKeysAreReadByCode() {
        #expect(IslandQueueKeys.key(for: 36) == .allow)
        #expect(IslandQueueKeys.key(for: 51) == .deny)
        #expect(IslandQueueKeys.key(for: 45) == .note)
        #expect(IslandQueueKeys.key(for: 53) == .close)
        #expect(IslandQueueKeys.key(for: 1) == nil)
    }
}

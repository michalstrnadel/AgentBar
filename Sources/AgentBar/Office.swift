import Foundation

/// **The office**: the island opened into a room with a desk for each session on
/// screen, everyone at work in the pose they are in right now. Not a game — it
/// keeps no score — but it opens and closes like one (`GameChoice.office`), so
/// it is a break by the same rules: only on a click, Esc gives the keys back, and
/// its clock runs only while it is looked at.
///
/// Pure on purpose, like `ClawdScene`: who sits where, what each one is seen
/// doing, where a click on a desk leads and when the office steps aside are all
/// worked out here from the sessions, so they can be read and tested without a
/// view. `OfficeView` only draws it.
enum Office {
    /// More than this and the rest are a "+N" — the room has no more desks.
    static let maxDesks = 8
    static let columns = 2
    static let rows = 4

    /// The room, in the view's points (origin bottom left): the wall along the
    /// top, the footer along the bottom, the desks in between.
    static let size = CGSize(width: 432, height: 470)
    static let wallHeight: CGFloat = 50
    static let footerHeight: CGFloat = 38
    static let margin: CGFloat = 12
    static let gap: CGFloat = 8

    /// One desk and who sits at it.
    struct Desk: Equatable {
        let sessionID: String
        let agentID: String
        let project: String
        let state: Session.State
        /// What Clawd is drawn doing; for every other agent, only whether its mark
        /// moves (working), raises a sign (waiting) or rests.
        let scene: ClawdScene
        let subagents: Int
        let rect: CGRect

        /// A permission or a question: the hand is up.
        var handRaised: Bool { state.waitsOnHuman }
    }

    struct Layout: Equatable {
        var desks: [Desk]
        /// Sessions with no desk left for them.
        var overflow: Int
    }

    /// The sessions in the order they come (the island's: whatever needs the
    /// person first), the first `maxDesks` at desks, row by row from the top left.
    static func layout(_ sessions: [Session], now: TimeInterval) -> Layout {
        let seated = sessions.prefix(maxDesks)
        let desks = seated.enumerated().map { i, s in
            Desk(sessionID: s.id, agentID: s.agentID, project: s.project, state: s.state,
                 scene: scene(for: s, now: now), subagents: s.subagentCount, rect: deskRect(i))
        }
        return Layout(desks: desks, overflow: max(0, sessions.count - maxDesks))
    }

    /// Desk `index`'s cell: two to a row, the first row just under the wall.
    static func deskRect(_ index: Int) -> CGRect {
        let w = ((size.width - margin * 2 - gap) / CGFloat(columns)).rounded(.down)
        let h = ((size.height - wallHeight - footerHeight) / CGFloat(rows)).rounded(.down)
        let col = index % columns, row = index / columns
        return CGRect(x: margin + CGFloat(col) * (w + gap),
                      y: size.height - wallHeight - CGFloat(row + 1) * h,
                      width: w, height: h)
    }

    /// What a session is seen doing at its desk. Waiting on the person is the hand
    /// up — the amber "!" for an approval, the blue "?" for a question — whatever
    /// it was doing before; a finished turn is asleep. A working session does
    /// what `ClawdScene` says, except that at a desk "nothing more specific" is
    /// typing, not walking.
    static func scene(for s: Session, now: TimeInterval) -> ClawdScene {
        switch s.state {
        case .permission: return .approve
        case .question: return .ask
        case .done, .idle, .error: return .sleep
        case .thinking, .tool:
            let scene = ClawdScene.scene(for: s, now: now)
            return scene == .walk ? .type : scene
        }
    }

    /// Where a click on a desk leads.
    enum Target: Equatable {
        /// The hand is up: the office closes onto the island's rows, with that
        /// request in them. Never a focus — focusing a waiting session hands its
        /// request back to the terminal (`AgentActions.focus` writes `defer`), and
        /// a click on a picture must not answer anything.
        case showRequest(sessionID: String)
        /// Everyone else: their terminal comes forward and the office closes.
        case focus(sessionID: String)
    }

    static func target(for desk: Desk) -> Target {
        desk.handRaised ? .showRequest(sessionID: desk.sessionID) : .focus(sessionID: desk.sessionID)
    }

    /// The desk under `point`, if any.
    static func desk(at point: CGPoint, in layout: Layout) -> Desk? {
        layout.desks.first { $0.rect.contains(point) }
    }

    /// Whether the office steps aside, given the waiting keys when it opened and
    /// now (`IslandController.waitingKeys`: `req:<file>` and `ses:<id>`).
    ///
    /// Unlike a game it does **not** step aside for a session already at a desk
    /// that starts waiting — its hand going up is the signal, and the pill still
    /// turns amber — nor for that session's request. Something new from a session
    /// the office has no desk for steps it aside, as it does a game.
    static func yields(before: Set<String>, now: Set<String>, seated: Set<String>,
                       requestSessions: [String: String]) -> Bool {
        let new = now.subtracting(before).filter { key in
            if key.hasPrefix("ses:") { return !seated.contains(String(key.dropFirst(4))) }
            if key.hasPrefix("req:"), let session = requestSessions[String(key.dropFirst(4))] {
                return !seated.contains(session)
            }
            return true
        }
        return !new.isEmpty
    }

    /// What a desk says under it.
    static func stateWord(_ desk: Desk, label: String) -> String {
        switch desk.state {
        case .permission: return "waits on you"
        case .question: return "has a question"
        case .done: return "done"
        case .idle: return "idle"
        case .error: return "stopped on an error"
        case .thinking, .tool:
            return label.isEmpty ? (desk.state == .thinking ? "thinking" : "working") : label
        }
    }
}

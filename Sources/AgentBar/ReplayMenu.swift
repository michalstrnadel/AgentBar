import AppKit

/// **Replay last turn…** on a row's right-click menu: the only way, with Your
/// Day's Replay buttons, that a replay opens — a click, never a link or a turn
/// ending (CLAUDE.md rule 2).
final class ReplayMenu: NSObject {
    static let shared = ReplayMenu()

    /// Replays read Claude Code's transcript, which says when each step happened.
    static func canReplay(_ s: Session) -> Bool {
        s.agentID == "claude" && s.entrypoint != "cloud" && !s.id.isEmpty
    }

    func item(for s: Session) -> NSMenuItem? {
        guard Self.canReplay(s) else { return nil }
        let item = NSMenuItem(title: "Replay Last Turn…", action: #selector(replay(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = s
        item.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        item.toolTip = "Watch this session's last turn played back as a little level, in Your Day's window."
        return item
    }

    /// `menu` with the replay item at its end, or a menu of just that — nil when
    /// there is neither.
    func adding(to menu: NSMenu?, for s: Session) -> NSMenu? {
        guard let item = item(for: s) else { return menu }
        let out = menu ?? NSMenu()
        if !out.items.isEmpty { out.addItem(.separator()) }
        out.addItem(item)
        return out
    }

    /// Your Day's Share menu: the longest run, replayed from the turn under way
    /// when it began. Only Claude Code's transcript says when each step happened.
    func items(for w: DayWrap) -> [NSMenuItem] {
        guard let l = w.longest, l.agent == "claude", !l.sessionId.isEmpty else { return [] }
        let item = NSMenuItem(title: "Replay the Longest Run…", action: #selector(replayLongest(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ReplayTurn.Subject(sessionID: l.sessionId, cwd: l.cwd, project: l.project,
                                                    by: l.from > 0 ? l.from + 1 : nil)
        item.image = NSImage(systemSymbolName: "play.rectangle", accessibilityDescription: nil)
        item.toolTip = "Watch the turn that ran longest played back as a little level."
        return [item]
    }

    @objc private func replay(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        WrapWindow.shared.showReplay(session: s)
    }

    @objc private func replayLongest(_ sender: NSMenuItem) {
        guard let subject = sender.representedObject as? ReplayTurn.Subject else { return }
        WrapWindow.shared.showReplay(subject)
    }
}

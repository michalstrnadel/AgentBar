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

    @objc private func replay(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? Session else { return }
        WrapWindow.shared.showReplay(session: s)
    }
}

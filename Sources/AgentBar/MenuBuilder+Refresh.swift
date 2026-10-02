import Cocoa

/// Keeping an open dropdown true without rebuilding it: rows are updated in
/// place, answered strips are muted, and growth is left to a real populate.
extension MenuBuilder {
    // MARK: - Live refresh of an open menu

    /// Reconcile an OPEN menu with fresh state without adding or removing rows.
    /// An open NSMenu window never shrinks — removing rows leaves a blank band
    /// hanging at the bottom until the menu closes — so surviving rows are
    /// updated in place and vanished ones are dimmed (`ended` sessions, muted
    /// approval strips); the next open rebuilds cleanly. Returns false when
    /// fresh state needs rows that aren't displayed (new session or request):
    /// growth needs a real populate, which an open menu handles fine.
    /// The request an item belongs to, whichever way it carries the tag: summary
    /// lines and card views hold a "req:<file>" string in representedObject; a
    /// question's option/escape items need representedObject for their payload,
    /// so their tag rides in the identifier instead.
    private static func requestTag(_ item: NSMenuItem) -> String? {
        if let tag = item.representedObject as? String, tag.hasPrefix("req:") {
            return String(tag.dropFirst(4))
        }
        if let id = item.identifier?.rawValue, id.hasPrefix("req:") {
            return String(id.dropFirst(4))
        }
        return nil
    }

    /// What a strip's tag identifies. The file name alone is NOT enough: names
    /// repeat across the tools of one turn (`RequestStore` keys its snapshots the
    /// same way), and a strip left keyed to the old request would answer the new
    /// one while showing the old command — `updateInPlace` must see a replaced
    /// request as a row it isn't displaying, so the menu rebuilds.
    static func requestKey(_ r: ApprovalRequest) -> String {
        "\(r.fileName)|\(r.identity)"
    }

    static func updateInPlace(_ menu: NSMenu, sessions: [Session], requests: [ApprovalRequest],
                              controller: StatusItemController) -> Bool {
        var displayedSessions = Set<String>()
        var displayedRequests = Set<String>()
        for item in menu.items {
            if let tag = requestTag(item) { displayedRequests.insert(tag); continue }
            if let s = item.representedObject as? Session { displayedSessions.insert(s.id) }
        }
        guard Set(sessions.map(\.id)).isSubset(of: displayedSessions),
              Set(requests.map(requestKey)).isSubset(of: displayedRequests) else { return false }

        let live = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let liveRequests = Set(requests.map(requestKey))
        for item in menu.items {
            // Request-tagged rows first: a question's escape item also carries a
            // Session and must not be rewritten into a second session row.
            if let tag = requestTag(item) {
                if !liveRequests.contains(tag) { mute(item) }
                continue
            }
            if let s = item.representedObject as? Session {
                if let updated = live[s.id] {
                    item.representedObject = updated
                    let row = item.view as? SessionRowView
                    row?.update(updated)
                    row?.toolTip = rowToolTip(updated)
                    if let row { item.title = SessionRowView.plainTitle(row.content) }
                    // Keystroke fallback appears/disappears with the permission state.
                    let hasStrip = requests.contains { $0.sessionId == updated.id }
                    item.submenu = (updated.state == .permission && !hasStrip)
                        ? keystrokeSubmenu(for: updated, controller: controller) : nil
                } else {
                    (item.view as? SessionRowView)?.showEnded(s)
                    item.submenu = nil
                }
            } else if item.identifier?.rawValue == "shortcutRow" {
                configureShortcutRow(item, controller: controller)
            }
        }
        // The shared rows (the update row above all) are re-applied from a fresh
        // model; they carry their own identifiers, so nothing above touches them.
        AppMenuRenderer.refresh(menu, with: AppMenuModel.appSection(.current),
                                target: controller, action: appMenuAction)
        return true
    }

    /// A vanished approval strip: fade the custom views and disarm their buttons
    /// so an already-answered request can't be answered twice; the summary line
    /// dims to match, and clickable rows (question options) lose their action.
    static func mute(_ item: NSMenuItem) {
        item.action = nil
        if let view = item.view {
            guard view.alphaValue > 0.55 else { return } // already muted
            view.alphaValue = 0.5
            disableControls(in: view)
        } else if let title = item.attributedTitle {
            let dimmed = NSMutableAttributedString(attributedString: title)
            dimmed.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor,
                                range: NSRange(location: 0, length: dimmed.length))
            item.attributedTitle = dimmed
        }
    }

    private static func disableControls(in view: NSView) {
        for sub in view.subviews {
            (sub as? NSControl)?.isEnabled = false
            disableControls(in: sub)
        }
    }
}

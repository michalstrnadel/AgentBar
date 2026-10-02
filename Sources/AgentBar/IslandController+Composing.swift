import Cocoa

/// A denial note being typed on an approval card: the panel takes keys for it,
/// holds still under the caret, and hands the keyboard back when it is done.
extension IslandController {
    func beginComposing(_ fileName: String) {
        // One note at a time: opening a second card's field closes the first.
        if let other = composing, other != fileName,
           let card = approvalCards[other].flatMap(Self.approvalView(in:)) {
            card.setComposing(false, notify: false)
        }
        composing = fileName
        let front = NSWorkspace.shared.frontmostApplication
        keysCameFrom = front?.processIdentifier == getpid() ? nil : front
        collapseWork?.cancel()
        panel.acceptsKeys = true
        // One last layout with the note row showing, so the panel grows to it —
        // then rows hold still until the note is done.
        layout(animated: true, force: true)
        panel.makeKey()
    }

    func endComposing(relayout: Bool = true) {
        guard let c = composing else { return }
        composing = nil
        if let card = approvalCards[c].flatMap(Self.approvalView(in:)), card.composing {
            card.setComposing(false, notify: false)
        }
        panel.makeFirstResponder(nil)
        panel.acceptsKeys = false
        panel.resignKey()
        // Open exactly as far as the pointer says: it may have left long ago (the
        // grace timer was held off while typing), or still be on the panel after
        // an answer elsewhere asked it to close. A peek ends the same way.
        wantsExpanded = hovered
        peeking = hovered
        // Keys go back to the app that had them. The panel never activated this
        // app, so that app is still frontmost; activating it again is what hands
        // the key window back rather than leaving keys addressed to the island.
        if let app = keysCameFrom, !app.isTerminated { app.activate() }
        keysCameFrom = nil
        if relayout { rebuild(animated: true) }
    }

    /// Cards are cached wrapped in their indent; the approval view is inside.
    private static func approvalView(in wrapper: NSView) -> IslandApprovalView? {
        (wrapper as? NSStackView)?.arrangedSubviews.first as? IslandApprovalView
    }
}

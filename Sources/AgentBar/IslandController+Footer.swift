import Cocoa

/// The open panel's pinned footer: the quota meters, the optional day strip,
/// and the ⋯ button that opens the menu.
extension IslandController {
    /// In Island-only mode the menu bar mark is gone, so the panel carries the way
    /// into Settings, updates and Quit itself. The provider quota line rides
    /// along on the left — a glance, not a dashboard.
    func footer() -> NSView {
        let row = footerRow()
        guard let strip = todayStrip() else { return row }
        // A vertical pair rather than a taller single row: `setFooter` measures what
        // it is handed (`fittingSize`) and `contentHeight` already carries the result,
        // so the panel grows by exactly the strip and nothing else moves.
        let stack = NSStackView(views: [strip, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func todayStrip() -> TodayStripView? {
        // Both halves off unless asked for in Appearance — the panel's whole argument
        // is that it stays small, and the same numbers are a click away under ⋯ and in
        // `agentbar history`. See TodayStripView for why they switch on separately.
        guard TodayStripView.enabled else { todayStripCache = nil; return nil }
        let (summary, entries) = HistoryDigest.today(HistoryStore.cached())
        guard !summary.isEmpty else { todayStripCache = nil; return nil }
        let signature = TodayStripView.signature(summary, entries)
        if let cache = todayStripCache, cache.signature == signature {
            // A view can only live in one place: `setRows`/`setFooter` tear the old
            // hierarchy down, so the cached one has to be lifted out before reuse.
            cache.view.removeFromSuperview()
            return cache.view
        }
        let view = TodayStripView(summary: summary, entries: entries,
                                  width: Self.expandedWidth - IslandContentView.hPad * 2)
        todayStripCache = (signature, view)
        return view
    }

    /// Take a break, one click from the corner — beside ⋯, as quiet as it is. In the
    /// accent colour while a game is put aside, so the way back is visible.
    private func breakButton() -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: "gamecontroller",
                                        accessibilityDescription: "Take a break")!,
                         target: self, action: #selector(breakClicked(_:)))
        b.isBordered = false
        b.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let resumable = breakGame != nil
        b.contentTintColor = resumable ? .controlAccentColor : NSColor.white.withAlphaComponent(0.55)
        b.toolTip = resumable
            ? "Back to the break — \(breakChoice?.title ?? "") \(Self.grouped(breakGame?.score ?? 0))"
            : "Take a break — a small game that steps aside when an agent needs you"
        b.setAccessibilityLabel(b.toolTip)
        return b
    }

    private func footerRow() -> NSView {
        let dots = NSButton(title: "⋯", target: self, action: #selector(showMenu(_:)))
        dots.isBordered = false
        dots.font = .systemFont(ofSize: 15, weight: .semibold)
        dots.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        dots.toolTip = "AgentBar"

        var views: [NSView] = []
        // The same line the footer always spent on quota, drawn instead of
        // written: a meter reads at a glance and a sentence does not, and at this
        // size they cost the same height. The full numbers stay one tooltip and
        // one ⋯ away — which is also what makes it fair to show only the
        // providers actually in use here. See `UsageCenter.relevant`.
        let all = UsageCenter.shared.readings
        let active = Set(sessions.compactMap { UsageCenter.provider(forAgent: $0.agentID) })
        let shown = UsageCenter.relevant(all, active: active,
                                         lastUsed: active.isEmpty ? lastUsedProvider() : nil)
        if let meters = UsageMeterView(readings: shown, style: .islandFooter,
                                       tooltipReadings: all) {
            meters.translatesAutoresizingMaskIntoConstraints = false
            meters.heightAnchor.constraint(equalToConstant: meters.frame.height).isActive = true
            // Exactly its own width, and the spacer takes the rest. Both used to
            // hug at the same priority, which left the solver free to decide
            // between them — and when it decided against the line, the line got
            // no width and the quota vanished off the island.
            meters.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            // It must never squeeze the ⋯ button out; it truncates instead.
            meters.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(meters)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        views.append(breakButton())
        views.append(dots)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant:
            Self.expandedWidth - IslandContentView.hPad * 2).isActive = true
        return row
    }

    /// The provider of the last session that ended, so the quota line has
    /// something to keep showing when nothing is running. Only asked for when
    /// nothing is — the history is memoised, but the scan is not free.
    private func lastUsedProvider() -> String? {
        // One pass, not a sort: the newest record that belongs to a provider,
        // which is rarely the newest record.
        var best: (at: TimeInterval, provider: String)?
        for r in HistoryStore.cached() {
            guard let provider = UsageCenter.provider(forAgent: r.agent),
                  r.endedAt > (best?.at ?? 0) else { continue }
            best = (r.endedAt, provider)
        }
        return best?.provider
    }
}

import Cocoa

/// One session in the menu bar's dropdown, drawn rather than typeset: the agent's
/// mark, a state dot, `project · branch` and what it is doing on the left, how long
/// it has run and whose it is in two aligned columns on the right. An attributed
/// title could only run all of that together, so the right-hand pieces landed
/// wherever the name happened to end.
///
/// Lives in `NSMenuItem.view`, so it does what a titled item gets for free: draws
/// its own highlight, performs the item's action on a click and dismisses the
/// menu, and answers `update(_:)` so an open menu can refresh it in place
/// (`MenuBuilder.updateInPlace`). Menu surface only — the island draws its rows
/// its own way (CLAUDE.md rule 2).
final class SessionRowView: NSView {
    /// Which colour the dot is. An enum rather than a colour so the mapping is
    /// testable without a drawing context.
    enum Dot: Equatable { case waiting, asking, working, failed, quiet, ended }

    /// Everything the row says, as plain values.
    struct Content: Equatable {
        var dot: Dot
        var name: String
        var detail: String
        var elapsed: String
        var agent: String
        /// Whose brand colour a working dot takes.
        var agentID: String
        /// "ctx 82%" once a Claude Code session's context is filling up, "" until
        /// then and for every row the mod does not report on (`ContextGauge`).
        var context = ""
        var contextLevel: ContextGauge.Level = .hidden
    }

    static func content(for s: Session, ended: Bool = false) -> Content {
        var name = s.project.isEmpty ? "session" : s.project
        if let branch = s.gitBranch { name += " · \(branch)" }
        let agent = s.agent.name.uppercased()
        if ended {
            return Content(dot: .ended, name: name, detail: "ended", elapsed: "", agent: agent, agentID: s.agentID)
        }

        let dot: Dot
        switch s.state {
        case .permission:      dot = .waiting
        case .question:        dot = .asking
        case .thinking, .tool: dot = .working
        case .error:           dot = .failed
        case .idle, .done:     dot = .quiet
        }
        var detail: String
        switch s.state {
        // A held call's label is the command being held: the one thing worth reading.
        case .permission: detail = s.heldByMod ? s.label : s.permissionWord
        case .error:      detail = s.label.isEmpty ? "failed" : "failed — \(s.label)"
        default:          detail = s.label
        }
        // Done rows say WHAT finished. 60 characters keeps the menu from
        // ballooning; the tooltip carries the full line.
        if detail.isEmpty, s.state == .done || s.state == .idle, !s.recap.isEmpty {
            detail = String(s.recap.prefix(60)) + (s.recap.count > 60 ? "…" : "")
        }
        // Accurate as of the render; a menu stays open too briefly to need ticking.
        return Content(dot: dot, name: name, detail: detail, elapsed: s.elapsed ?? "",
                       agent: agent, agentID: s.agentID,
                       context: ContextGauge.text(s.contextPercent) ?? "",
                       contextLevel: ContextGauge.level(s.contextPercent))
    }

    /// The same words as one line, for accessibility and type-to-select.
    static func plainTitle(_ c: Content) -> String {
        let context = c.context.replacingOccurrences(of: "ctx ", with: "context ")
            + (c.context.isEmpty ? "" : " full")
        return [c.name, c.detail, context, c.elapsed, c.agent].filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// Room the context figure takes beside the time, when there is one.
    static func contextWidth(_ c: Content) -> CGFloat {
        c.context.isEmpty ? 0 : textWidth(c.context, elapsedFont) + gap
    }

    // MARK: - Metrics

    static let height: CGFloat = 22
    static let markX: CGFloat = 14
    /// The menu marks share one canvas width (`MenuBuilder.menuMarks`), so the
    /// text column is the same for every agent; this is its fallback.
    static let defaultMarkWidth: CGFloat = 16
    static func textX(markWidth: CGFloat) -> CGFloat { markX + markWidth + 6 + 7 + 6 }
    /// Room at the right edge for the submenu chevron a titled item would draw,
    /// kept on every row so the columns line up whether a row has one or not.
    static let rightPad: CGFloat = 24
    /// The elapsed column is sized for the widest thing it can hold ("59m", "<1m"),
    /// so times line up down the list instead of following each agent's name.
    static let elapsedColumn: CGFloat = 30
    static let agentColumn: CGFloat = 70
    static let gap: CGFloat = 8
    /// Beyond this the detail is cut, not the menu widened.
    static let maxWidth: CGFloat = 520
    static let minWidth: CGFloat = 300

    static let nameFont = NSFont.menuFont(ofSize: 0)
    static let detailFont = NSFont.menuFont(ofSize: 11)
    static let elapsedFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let agentFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)

    static func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
        s.isEmpty ? 0 : ceil((s as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The width the row asks for: everything on one line, within `min`/`maxWidth`.
    static func idealWidth(_ c: Content, markWidth: CGFloat = defaultMarkWidth) -> CGFloat {
        let textX = textX(markWidth: markWidth)
        let left = textWidth(c.name, nameFont)
            + (c.detail.isEmpty ? 0 : gap + textWidth(c.detail, detailFont))
        let right = contextWidth(c) + elapsedColumn + gap + agentColumn + rightPad
        return min(maxWidth, max(minWidth, textX + left + gap * 2 + right))
    }

    /// Where the left-hand text goes at a given width: the name keeps up to all
    /// of the room it needs and the detail gets what is left, so a long recap is
    /// the thing that ends in an ellipsis, never the project.
    static func textLayout(_ c: Content, width: CGFloat,
                           markWidth: CGFloat = defaultMarkWidth) -> (name: CGFloat, detail: CGFloat) {
        let textX = textX(markWidth: markWidth)
        let room = max(0, width - textX - contextWidth(c)
                       - (elapsedColumn + gap + agentColumn + rightPad) - gap * 2)
        let name = min(textWidth(c.name, nameFont), room)
        let left = room - name - gap
        let detail = c.detail.isEmpty || left < 24 ? 0 : min(textWidth(c.detail, detailFont), left)
        return (name, detail)
    }

    // MARK: - View

    private(set) var content: Content
    private let mark: NSImage

    init(session: Session, mark: NSImage) {
        self.content = Self.content(for: session)
        self.mark = mark
        super.init(frame: NSRect(x: 0, y: 0, width: Self.idealWidth(content, markWidth: mark.size.width),
                                 height: Self.height))
        autoresizingMask = [.width]
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(Self.plainTitle(content))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Fresh state for a row that is still on screen. Never changes the frame: an
    /// open menu does not re-lay itself out, so a wider row would draw past its edge.
    func update(_ s: Session) { set(Self.content(for: s)) }

    /// The session ended while the menu was open: dimmed, still clickable.
    func showEnded(_ s: Session) { set(Self.content(for: s, ended: true)) }

    private func set(_ c: Content) {
        guard c != content else { return }
        content = c
        setAccessibilityLabel(Self.plainTitle(c))
        needsDisplay = true
    }

    // MARK: - Drawing

    /// Set only by `renderForVerification`: outside a menu nothing is ever highlighted.
    var highlightForRendering = false
    private var highlighted: Bool { highlightForRendering || enclosingMenuItem?.isHighlighted == true }

    override func draw(_ dirtyRect: NSRect) {
        let lit = highlighted
        if lit {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
        }
        let ended = content.dot == .ended
        let primary: NSColor = lit ? .selectedMenuItemTextColor : ended ? .secondaryLabelColor : .labelColor
        let secondary: NSColor = lit ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
        let tertiary: NSColor = lit ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.65) : .tertiaryLabelColor
        let midY = bounds.midY

        // Mark: a template, so it is tinted by hand — nothing tints a template
        // image drawn inside a custom view.
        let markSize = mark.size
        let tinted = IconRenderer.tint(mark, with: ended ? tertiary : primary)
        tinted.draw(in: NSRect(x: Self.markX, y: (midY - markSize.height / 2).rounded(),
                               width: markSize.width, height: markSize.height))

        // State dot, between the mark and the text.
        let d: CGFloat = 7
        dotColor(lit: lit).setFill()
        NSBezierPath(ovalIn: NSRect(x: Self.markX + markSize.width + 6, y: (midY - d / 2).rounded(),
                                    width: d, height: d)).fill()

        let layout = Self.textLayout(content, width: bounds.width, markWidth: markSize.width)
        var x = Self.textX(markWidth: markSize.width)
        draw(content.name, font: Self.nameFont, color: primary, x: x, width: layout.name)
        x += layout.name + Self.gap
        if layout.detail > 0 {
            draw(content.detail, font: Self.detailFont, color: secondary, x: x, width: layout.detail)
        }

        // Right-hand columns: the time right-aligned so the digits line up, the
        // agent left-aligned right after it so the tag reads as belonging to it.
        let agentX = bounds.width - Self.rightPad - Self.agentColumn
        draw(content.agent, font: Self.agentFont, color: tertiary, x: agentX,
             width: min(Self.textWidth(content.agent, Self.agentFont), Self.agentColumn))
        drawRight(content.elapsed, font: Self.elapsedFont, color: tertiary, maxX: agentX - Self.gap,
                  width: Self.elapsedColumn)
        // Context, just left of the time and in the time's type: a quiet figure
        // until it is close to full, then the colour of something to look at.
        if !content.context.isEmpty {
            let color = lit ? secondary : ContextGauge.menuColor(content.contextLevel, fallback: tertiary)
            drawRight(content.context, font: Self.elapsedFont, color: color,
                      maxX: agentX - Self.gap - Self.elapsedColumn - Self.gap,
                      width: Self.contextWidth(content))
        }

        // A view item gets no submenu arrow from the menu; the keystroke info
        // submenu of a permission row still needs one to be found.
        if enclosingMenuItem?.submenu != nil {
            let c = NSBezierPath()
            let x = bounds.width - 13, h: CGFloat = 4
            c.move(to: NSPoint(x: x, y: midY + h))
            c.line(to: NSPoint(x: x + h, y: midY))
            c.line(to: NSPoint(x: x, y: midY - h))
            c.lineWidth = 1.5
            c.lineCapStyle = .round
            c.lineJoinStyle = .round
            secondary.setStroke()
            c.stroke()
        }
    }

    private func dotColor(lit: Bool) -> NSColor {
        switch content.dot {
        case .waiting: return IconRenderer.amberDot
        case .asking:  return IconRenderer.questionDot
        case .working:
            let brand = Agent.byID(content.agentID).brand
            // On the accent-coloured highlight a brand dot can vanish into it.
            return lit ? .selectedMenuItemTextColor : brand
        case .failed:  return .systemRed
        case .quiet:   return lit ? NSColor.selectedMenuItemTextColor.withAlphaComponent(0.6) : .tertiaryLabelColor
        case .ended:   return .quaternaryLabelColor
        }
    }

    private func attrs(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    private func draw(_ s: String, font: NSFont, color: NSColor, x: CGFloat, width: CGFloat) {
        guard !s.isEmpty, width > 0 else { return }
        let h = ceil(font.ascender - font.descender)
        (s as NSString).draw(with: NSRect(x: x, y: (bounds.midY - h / 2).rounded() - font.descender,
                                          width: width, height: h),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                             attributes: attrs(font, color))
    }

    private func drawRight(_ s: String, font: NSFont, color: NSColor, maxX: CGFloat, width: CGFloat) {
        guard !s.isEmpty else { return }
        let w = min(Self.textWidth(s, font), width)
        draw(s, font: font, color: color, x: maxX - w, width: w)
    }

    // MARK: - Clicks

    override func mouseUp(with event: NSEvent) {
        guard let item = enclosingMenuItem, item.isEnabled, let action = item.action else { return }
        // A view item is not dismissed by the menu the way a titled one is.
        item.menu?.cancelTracking()
        NSApp.sendAction(action, to: item.target, from: item)
    }

    // MARK: - Verification

    /// Rows in every state, light and dark, to a PNG — the only way to look at a
    /// menu row without the menu closing on the screenshot. `--render-menu-rows`.
    static func renderForVerification(to url: URL) -> Bool {
        func row(_ state: Session.State, agent: String, project: String, label: String,
                 recap: String = "", minutes: Double) -> Session? {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("agentbar-rows-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = dir.appendingPathComponent("\(project).json")
            let o: [String: Any] = [
                "agent": agent, "state": state.rawValue, "label": label, "project": project,
                "recap": recap, "started": true, "pid": 1,
                "ts": Date().timeIntervalSince1970,
                "started_at": Date().timeIntervalSince1970 - minutes * 60,
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: o),
                  (try? data.write(to: file)) != nil else { return nil }
            return Session(fileURL: file)
        }
        let sessions = [
            row(.permission, agent: "claude", project: "myapp", label: "Bash: git push", minutes: 12),
            row(.question, agent: "claude", project: "docs", label: "❓ Which format?", minutes: 3),
            row(.thinking, agent: "codex", project: "api", label: "Thinking…", minutes: 47),
            row(.thinking, agent: "claude", project: "AgentBar", label: Session.compactingLabel, minutes: 130),
            row(.error, agent: "gemini", project: "site", label: "quota exceeded", minutes: 5),
            row(.done, agent: "copilot", project: "cli-tool",
                label: "", recap: "Renamed the flag and updated every caller, tests pass.", minutes: 0.5),
        ].compactMap { $0 }
        guard sessions.count == 6 else { return false }

        var views: [SessionRowView] = sessions.map {
            SessionRowView(session: $0, mark: MenuBuilder.menuMark(for: $0.agent))
        }
        let ended = SessionRowView(session: sessions[2], mark: MenuBuilder.menuMark(for: Agent.byID("codex")))
        ended.showEnded(sessions[2])
        views.append(ended)
        let lit = SessionRowView(session: sessions[2], mark: MenuBuilder.menuMark(for: Agent.byID("codex")))
        lit.highlightForRendering = true
        views.append(lit)
        let width = views.map { $0.frame.width }.max() ?? minWidth

        let panel = CGFloat(views.count) * height + 12
        let size = NSSize(width: width * 2 + 24, height: panel + 16)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return false }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (i, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            guard let appearance = NSAppearance(named: name) else { continue }
            let origin = CGFloat(i) * (width + 24)
            appearance.performAsCurrentDrawingAppearance {
                let backdrop = name == .aqua ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.16, alpha: 1)
                backdrop.setFill()
                NSBezierPath(roundedRect: NSRect(x: origin, y: 8, width: width, height: panel),
                             xRadius: 8, yRadius: 8).fill()
                for (j, v) in views.enumerated() {
                    v.frame = NSRect(x: 0, y: 0, width: width, height: height)
                    v.appearance = appearance
                    let y = 8 + panel - 6 - CGFloat(j + 1) * height
                    NSGraphicsContext.current?.saveGraphicsState()
                    let t = NSAffineTransform()
                    t.translateX(by: origin, yBy: y)
                    t.concat()
                    v.draw(v.bounds)
                    NSGraphicsContext.current?.restoreGraphicsState()
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }
}

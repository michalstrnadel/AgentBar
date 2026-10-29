import AppKit

/// The Trust Receipt: Your Day as a till slip — what the agents did, what was
/// decided about it and by whom, and what was stopped.
///
/// A section of Your Day, never a thing of its own: it is drawn from the same
/// `DayWrap` the card is, leaves only through the Share menu (**Save Receipt…**,
/// **Copy Receipt**), and goes out share-safe unless Include Project Names is on —
/// the command that was stopped and the file two agents crossed on are names too.
///
/// A thermal printer's shape: 576 px wide (80 mm at 203 dpi), as tall as it has
/// lines, monospaced, dashed rules between the sections and a TOTAL line, on the
/// card's own paper and ink. Every line is measured or absent, as on the card.
/// Deterministic: the same recap draws the same pixels.
enum ReceiptRenderer {
    static let width: CGFloat = 576

    enum Line: Equatable {
        /// Large and centred: the heading.
        case title(String)
        /// Centred, in the body size.
        case center(String)
        /// A label on the left, a figure on the right.
        case pair(String, String)
        /// The same, indented and quieter: the parts of the line above.
        case item(String, String)
        /// Words that wrap at the column, indented.
        case note(String)
        /// A dashed rule between sections.
        case rule
        /// The double-ruled TOTAL.
        case total(String, String)
        case gap
        /// Clawd, small, in his own pixels.
        case clawd
    }

    typealias S = WrapStyle

    // MARK: - What it says

    /// The receipt's lines for a recap. Pure: the test reads these, not pixels.
    static func lines(_ w: DayWrap) -> [Line] {
        var out: [Line] = [.title("AGENTBAR"), .center("TRUST RECEIPT"), .gap,
                           .center(dateLine(w)), .center(w.range.title.uppercased())]
        out.append(.rule)
        guard !w.pending else { return out + [.center("Still adding up."), .rule, .clawd] }
        guard !w.isEmpty else { return out + [.center("Nothing finished \(w.range.phrase)."), .rule, .clawd] }

        // What the agents did.
        out.append(.pair("SESSIONS", S.grouped(w.sessions)))
        if w.timed > 0 { out.append(.pair("AGENT TIME", HistoryDigest.duration(w.agentSeconds))) }
        if let p = w.projects.first { out.append(.pair("TOP PROJECT", p.name)) }
        let r = w.receipt
        if r.toolCalls > 0 {
            out.append(.pair("TOOL CALLS", S.grouped(r.toolCalls)))
            let shown = r.tools.prefix(4)
            for t in shown { out.append(.item(toolName(t.name), S.grouped(t.count))) }
            let rest = r.tools.dropFirst(shown.count)
            if !rest.isEmpty {
                out.append(.item("\(rest.count) other tool\(rest.count == 1 ? "" : "s")",
                                 S.grouped(rest.reduce(0) { $0 + $1.count })))
            }
            if r.toolsMeasured < w.sessions {
                out.append(.note("counted in \(r.toolsMeasured) of \(w.sessions) sessions"))
            }
        }
        if w.changeMeasured > 0, w.linesAdded + w.linesRemoved > 0 {
            out.append(.pair("LINES", "+\(S.grouped(w.linesAdded)) −\(S.grouped(w.linesRemoved))"))
        }

        // What was decided, and by whom. Nobody asked you about the last one.
        let decided = w.waits.answered + w.waits.byRules
        let stopped = w.waits.autoRefused.count + r.claudeStopped
        if decided + stopped > 0 {
            out.append(.rule)
            out.append(.pair("DECISIONS", S.grouped(decided + stopped)))
            if r.approvals > 0 { out.append(.item("approved by you", S.grouped(r.approvals))) }
            if r.denials > 0 { out.append(.item("denied by you", S.grouped(r.denials))) }
            let other = w.waits.answered - r.approvals - r.denials
            if other > 0 { out.append(.item("other answers", S.grouped(other))) }
            if w.waits.byRules > 0 { out.append(.item("by your rules", S.grouped(w.waits.byRules))) }
            if w.waits.autoRefused.count > 0 {
                out.append(.item("stopped by auto mode", S.grouped(w.waits.autoRefused.count)))
            }
            if r.claudeStopped > 0 { out.append(.item("stopped by Claude Code", S.grouped(r.claudeStopped))) }
            if w.waits.waited >= 60 { out.append(.item("agents waited on you", HistoryDigest.duration(w.waits.waited))) }
        }

        // The stopped command that reached furthest — a lower bound when the
        // ledger kept only its start.
        if let k = r.riskiest {
            out.append(.rule)
            out.append(.pair("RISKIEST STOPPED", k.severity == .high ? "HIGH" : k.severity == .medium ? "MEDIUM" : "LOW"))
            out.append(.note(k.command.isEmpty ? "(command not shown)" : "$ " + k.command + (k.cut ? "…" : "")))
            out.append(.note((k.cut ? "reaches at least: " : "reaches: ") + k.reaches.joined(separator: ", ")))
            out.append(.note("stopped by \(k.by)"))
        }

        if let c = w.crossings.last {
            out.append(.rule)
            out.append(.pair("CROSSED PATHS", S.grouped(w.crossings.count)))
            out.append(.note(c.sentence()))
        }

        if r.costMeasured > 0 {
            out.append(.rule)
            out.append(.pair("COST, API PRICES", String(format: "$%.2f", r.cost)))
            if r.costMeasured < w.sessions {
                out.append(.note("measured on \(r.costMeasured) of \(w.sessions) sessions"))
            }
        }

        out.append(.total("TOTAL DECISIONS", S.grouped(decided + stopped)))
        out.append(.clawd)
        out.append(.center("THANK YOU FOR WATCHING"))
        out.append(.center("AgentBar · free and open source"))
        return out
    }

    /// A tool as a person would say it: an MCP tool by its server and name
    /// (`mcp__github__create_issue` → "github · create_issue").
    static func toolName(_ raw: String) -> String {
        let parts = raw.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return raw }
        let server = parts[1], tool = parts[2...].joined(separator: "__")
        return server == tool ? "\(server) (MCP)" : "\(server) · \(tool)"
    }

    private static func dateLine(_ w: DayWrap) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        if w.range == .today {
            f.dateFormat = "EEE d MMM yyyy"
            return f.string(from: Date(timeIntervalSince1970: w.start)).uppercased()
        }
        f.dateFormat = "d MMM"
        let from = f.string(from: Date(timeIntervalSince1970: w.start))
        f.dateFormat = "d MMM yyyy"
        return (from + " – " + f.string(from: Date(timeIntervalSince1970: w.end))).uppercased()
    }

    // MARK: - Drawing

    private static let margin: CGFloat = 36
    private static let body = NSFont.monospacedSystemFont(ofSize: 20, weight: .regular)
    private static let bold = NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold)
    private static let heading = NSFont.monospacedSystemFont(ofSize: 34, weight: .bold)
    private static let lineHeight: CGFloat = 30
    /// Columns of body text across the slip.
    private static var columns: Int {
        Int((width - 2 * margin) / max(1, S.measure("M", body).width))
    }

    /// How tall the slip is for these lines.
    static func height(_ lines: [Line]) -> CGFloat { layout(lines, draw: false) }

    /// Walks the lines, drawing them when `draw` is set; returns the height used.
    @discardableResult
    private static func layout(_ lines: [Line], draw: Bool) -> CGFloat {
        var y: CGFloat = 44
        let right = width - margin
        func put(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, align: S.Align = .left,
                 w: CGFloat = width - 2 * margin) {
            if draw { S.text(s, font, color, x: x, y: y, width: w, align: align) }
        }
        /// A label and a figure on one line: the label gives way when both do not fit.
        func pair(_ label: String, _ value: String, indent: CGFloat, font: NSFont, color: NSColor) {
            let room = columns - Int(indent / max(1, S.measure("M", body).width)) - value.count - 1
            let l = label.count > room ? String(label.prefix(max(1, room - 1))) + "…" : label
            put(l, font, color, x: margin + indent)
            put(value, font, color, x: margin, align: .right)
            y += lineHeight
        }
        func dashes(_ at: CGFloat) {
            guard draw, let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.saveGState()
            ctx.setStrokeColor(S.ink.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [8, 6])
            ctx.move(to: CGPoint(x: margin, y: at))
            ctx.addLine(to: CGPoint(x: right, y: at))
            ctx.strokePath()
            ctx.restoreGState()
        }
        for line in lines {
            switch line {
            case .title(let s):
                put(s, heading, S.ink, x: margin, align: .center)
                y += 48
            case .center(let s):
                put(s, body, S.ink, x: margin, align: .center)
                y += lineHeight
            case .pair(let l, let v):
                pair(l, v, indent: 0, font: bold, color: S.ink)
            case .item(let l, let v):
                pair(l, v, indent: 24, font: body, color: S.secondary)
            case .note(let s):
                for part in wrap(s, columns - 2) {
                    put(part, body, S.secondary, x: margin + 24)
                    y += lineHeight
                }
            case .rule:
                y += 10
                dashes(y)
                y += 22
            case .total(let l, let v):
                y += 12
                if draw {
                    S.fill(CGRect(x: margin, y: y, width: right - margin, height: 2), S.ink)
                    S.fill(CGRect(x: margin, y: y + 6, width: right - margin, height: 2), S.ink)
                }
                y += 20
                put(l, bold, S.ink, x: margin)
                put(v, bold, S.ink, x: margin, align: .right)
                y += lineHeight + 6
                if draw {
                    S.fill(CGRect(x: margin, y: y, width: right - margin, height: 2), S.ink)
                    S.fill(CGRect(x: margin, y: y + 6, width: right - margin, height: 2), S.ink)
                }
                y += 22
            case .gap:
                y += 10
            case .clawd:
                let pose = S.clawdPoses(.think).first ?? ""
                let rows = CGFloat(pose.split(separator: "\n").count)
                let px: CGFloat = 4
                y += 18
                if draw { S.clawd(pose, origin: CGPoint(x: (width - 22 * px) / 2, y: y), pixel: px) }
                y += rows * px + 18
            }
        }
        return ceil(y + 36)
    }

    /// `s` cut into lines of at most `cols` characters, at spaces where it can be.
    static func wrap(_ s: String, _ cols: Int) -> [String] {
        guard cols > 4 else { return [s] }
        var out: [String] = []
        var rest = Substring(s)
        while rest.count > cols {
            let head = rest.prefix(cols)
            let cut = head.lastIndex(of: " ").map { rest.distance(from: rest.startIndex, to: $0) } ?? cols
            // A word that ends exactly at the column needs no earlier cut.
            let n = rest.dropFirst(cols).first == " " ? cols : cut > cols / 3 ? cut : cols
            out.append(String(rest.prefix(n)))
            rest = rest.dropFirst(n).drop { $0 == " " }
        }
        if !rest.isEmpty || out.isEmpty { out.append(String(rest)) }
        return out
    }

    /// The slip as a bitmap, as tall as its lines.
    static func bitmap(_ w: DayWrap) -> NSBitmapImageRep? {
        let lines = lines(w)
        let size = CGSize(width: width, height: height(lines))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width),
                                         pixelsHigh: Int(size.height), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let g = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        let cg = g.cgContext
        WrapExport.drawFlipped(cg, size: size) {
            S.fill(CGRect(origin: .zero, size: size), S.paper)
            layout(lines, draw: true)
        }
        return rep
    }
}

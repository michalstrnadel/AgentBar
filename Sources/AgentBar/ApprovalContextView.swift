import Cocoa

/// Compact, monospaced view of *what* a permission request will do, shown inline
/// under the request row: the full Bash command, an Edit's diff, or a Write
/// preview. Read-only; approving from the bar becomes as informed as the terminal.
/// Content is already capped by the hook; this view further caps lines.
///
/// The diff is a **real** one. It used to show the first three lines of the old
/// text followed by the first three of the new, which for a change in the middle of
/// a function is three identical lines of context printed twice and the edit itself
/// off the bottom — approving something you could not see. `LineDiff` aligns the
/// two sides and this shows only what moved, with a line of context and a marker
/// wherever something was skipped.
final class ApprovalContextView: NSView {
    private enum Kind { case plain, add, del, gap }
    private struct Line {
        let text: String
        let kind: Kind
        /// The characters that differ within a one-line replacement. Everything
        /// else on the line is shared with its counterpart and is drawn dimmer.
        var emphasis: Range<Int>?

        init(text: String, kind: Kind, emphasis: Range<Int>? = nil) {
            self.text = text
            self.kind = kind
            self.emphasis = emphasis
        }
    }

    private let lines: [Line]
    /// Indent that lines the text up with the row above it — 22 under a menu item,
    /// wider on the island where the row starts past the mascot.
    private let leading: CGFloat
    private let lineH: CGFloat = 15
    private static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let charWidth = ("0" as NSString)
        .size(withAttributes: [.font: mono]).width

    init(context: ApprovalRequest.Context, leading: CGFloat = 22) {
        self.lines = Self.lines(for: context)
        self.leading = leading
        super.init(frame: NSRect(x: 0, y: 0, width: 300,
                                 height: CGFloat(max(1, lines.count)) * 15 + 8))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The arguments of a tool the hook carries no structured detail for — an MCP
    /// call, a fetch — read out of its full input, one `key: value` a line. Before
    /// this the card for an MCP call showed its name and nothing it would be told.
    init(arguments pretty: String, leading: CGFloat = 22) {
        self.lines = Self.take(Self.argumentLines(pretty), max: 6, kind: .plain)
        self.leading = leading
        super.init(frame: NSRect(x: 0, y: 0, width: 300,
                                 height: CGFloat(max(1, lines.count)) * 15 + 8))
        autoresizingMask = [.width]
    }

    /// Whether `pretty` holds anything worth a box: not empty, not `{}`.
    static func hasArguments(_ pretty: String) -> Bool {
        let t = pretty.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.isEmpty && t != "{}"
    }

    /// `key: value`, keys in order, each value compact and cut at a line. Input
    /// the hook cut at 4 KB is no longer JSON; then it is shown as it came.
    static func argumentLines(_ pretty: String) -> [String] {
        guard let data = pretty.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return splitNonEmpty(pretty).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        return o.keys.sorted().map { key in
            let v = o[key]!
            var text: String
            if let s = v as? String { text = s }
            else if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) {
                text = String(decoding: d, as: UTF8.self)
            } else { text = "\(v)" }
            text = ApprovalRequest.oneLine(text)
            if text.count > 90 { text = String(text.prefix(89)) + "…" }
            return "\(key): \(text)"
        }
    }

    // MARK: - Content

    /// The lines as text, for tests.
    static func texts(for context: ApprovalRequest.Context) -> [String] { lines(for: context).map(\.text) }

    private static func lines(for context: ApprovalRequest.Context) -> [Line] {
        switch context {
        case .bash(let cmd):
            return take(cmd.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                        max: 5, kind: .plain)
        case .write(let preview, let target):
            var out = take(preview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                           max: 5, kind: .plain)
            // Whether this makes a file or replaces one is the first thing to know.
            if let target { out.insert(Line(text: target.text, kind: .gap), at: 0) }
            return out
        case .diff(let old, let new, let more, let rest, let all):
            // Every edit the hook sent, one after another, under one row budget:
            // a MultiEdit used to show its first edit and "+4 more edits".
            var out: [Line] = []
            if all { out.append(Line(text: "every occurrence in the file", kind: .gap)) }
            let edits = [ApprovalRequest.Context.Edit(old: old, new: new)] + rest
            let budget = rest.isEmpty ? 10 : 16
            var shown = 0
            for (n, e) in edits.enumerated() {
                let left = budget - out.count
                guard n == 0 || left > 2 else { break }
                if edits.count > 1 { out.append(Line(text: "edit \(n + 1) of \(more + 1)", kind: .gap)) }
                out += diffLines(old: e.old, new: e.new, limit: left - (edits.count > 1 ? 1 : 0))
                shown += 1
            }
            let unseen = more + 1 - shown
            if unseen > 0 { out.append(Line(text: "+\(unseen) more edit\(unseen == 1 ? "" : "s")", kind: .plain)) }
            return out.isEmpty ? [Line(text: "(no change)", kind: .plain)] : out
        case .question(let qs):
            // Questions render their own answerable cards; this fallback only
            // shows if one ever lands here (e.g. a future menu path).
            return take(qs.map(\.question), max: 4, kind: .plain)
        case .plan(let text):
            // A taste of the plan; the island card renders the whole thing.
            return take(splitNonEmpty(text), max: 8, kind: .plain)
        }
    }

    private static func diffLines(old: String, new: String, limit: Int) -> [Line] {
        LineDiff.rows(old: splitNonEmpty(old), new: splitNonEmpty(new), context: 1, limit: max(1, limit))
            .map { row -> Line in
                switch row.kind {
                case .add:  return Line(text: row.text, kind: .add, emphasis: row.emphasis)
                case .del:  return Line(text: row.text, kind: .del, emphasis: row.emphasis)
                case .same: return Line(text: row.text, kind: .plain)
                case .gap:  return Line(text: row.text, kind: .gap)
                }
            }
    }

    private static func splitNonEmpty(_ s: String) -> [String] {
        s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// First `max` lines; if truncated, replace the last with an ellipsis marker.
    private static func take(_ all: [String], max: Int, kind: Kind) -> [Line] {
        if all.count <= max { return all.map { Line(text: $0, kind: kind) } }
        var out = all.prefix(max - 1).map { Line(text: $0, kind: kind) }
        out.append(Line(text: "… (+\(all.count - (max - 1)) more lines)", kind: .plain))
        return out
    }

    // MARK: - Drawing

    override func draw(_ dirty: NSRect) {
        var y = bounds.height - lineH - 2
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let columns = Int((bounds.width - leading - 14) / Self.charWidth)
        let starts = Self.windowStarts(lines, columns: columns)
        for (i, line) in lines.enumerated() {
            let (gutter, gutterColor, textColor): (String, NSColor, NSColor)
            switch line.kind {
            case .add:   (gutter, gutterColor, textColor) = ("+", .systemGreen, .labelColor)
            case .del:   (gutter, gutterColor, textColor) = ("−", .systemRed, .secondaryLabelColor)
            case .plain: (gutter, gutterColor, textColor) = (" ", .clear, .secondaryLabelColor)
            // A skipped run is neither content nor a change; it is the seam
            // between two of them, and it should read as the quietest thing here.
            case .gap:   (gutter, gutterColor, textColor) = (" ", .clear, .tertiaryLabelColor)
            }
            if line.kind == .add || line.kind == .del {
                NSAttributedString(string: gutter, attributes: [.font: Self.mono, .foregroundColor: gutterColor])
                    .draw(at: NSPoint(x: leading - 12, y: y))
            }
            let width = bounds.width - leading - 14
            body(line, color: textColor, paragraph: para, start: starts[i])
                .draw(in: NSRect(x: leading, y: y, width: width, height: lineH))
            y -= lineH
        }
    }

    /// The line, with the changed middle of a one-line edit kept at full strength
    /// and the shared ends faded. A renamed variable is then one bright word rather
    /// than two lines that look the same.
    /// How far each line has to be slid for its change to be on screen. A `−`/`+`
    /// pair is slid by the **same** amount: computed independently the two land at
    /// different offsets, and two lines meant to be read column against column stop
    /// lining up, which is most of what makes a diff legible.
    private static func windowStarts(_ lines: [Line], columns: Int) -> [Int] {
        var out = lines.map { LineDiff.windowStart($0.text, emphasis: $0.emphasis,
                                                   width: columns) }
        for i in 0..<max(0, lines.count - 1)
        where lines[i].kind == .del && lines[i + 1].kind == .add
            && lines[i].emphasis != nil && lines[i + 1].emphasis != nil {
            let shared = min(out[i], out[i + 1])
            out[i] = shared
            out[i + 1] = shared
        }
        return out
    }

    private func body(_ line: Line, color: NSColor, paragraph: NSParagraphStyle,
                      start: Int) -> NSAttributedString {
        let (shown, range) = LineDiff.slide(line.text, emphasis: line.emphasis, by: start)
        let text = NSMutableAttributedString(string: shown, attributes: [
            .font: Self.mono, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let chars = Array(shown)
        guard let emphasis = range, !emphasis.isEmpty,
              emphasis.upperBound <= chars.count
        else { return text }
        // The range counts Characters; NSRange counts UTF-16 units. One accented
        // letter or one emoji in the line and the two disagree — quietly wrong at
        // best, out of bounds at worst.
        let head = String(chars[0..<emphasis.lowerBound]).utf16.count
        let middle = String(chars[emphasis.lowerBound..<emphasis.upperBound]).utf16.count
        let total = (shown as NSString).length
        let faded = color.withAlphaComponent(0.45)
        text.addAttribute(.foregroundColor, value: faded, range: NSRange(location: 0, length: head))
        text.addAttribute(.foregroundColor, value: faded,
                          range: NSRange(location: head + middle,
                                         length: max(0, total - head - middle)))
        return text
    }
}

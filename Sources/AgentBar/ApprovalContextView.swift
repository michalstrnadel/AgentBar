import Cocoa

/// Compact, monospaced view of *what* a permission request will do, shown inline
/// under the request row: the full Bash command, an Edit's −old / +new mini-diff, or
/// a Write preview. Read-only; approving from the bar becomes as informed as the
/// terminal. Content is already capped by the hook; this view further caps lines.
final class ApprovalContextView: NSView {
    private enum Kind { case plain, add, del }
    private struct Line { let text: String; let kind: Kind }

    private let lines: [Line]
    private let leading: CGFloat = 22   // align under the "what" row's text
    private let lineH: CGFloat = 15
    private static let mono = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(context: ApprovalRequest.Context) {
        self.lines = Self.lines(for: context)
        super.init(frame: NSRect(x: 0, y: 0, width: 300,
                                 height: CGFloat(max(1, lines.count)) * 15 + 8))
        autoresizingMask = [.width]
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Content

    private static func lines(for context: ApprovalRequest.Context) -> [Line] {
        switch context {
        case .bash(let cmd):
            return take(cmd.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                        max: 5, kind: .plain)
        case .write(let preview):
            return take(preview.split(separator: "\n", omittingEmptySubsequences: false).map(String.init),
                        max: 5, kind: .plain)
        case .diff(let old, let new, let more):
            var out: [Line] = []
            out += take(splitNonEmpty(old), max: 3, kind: .del)
            out += take(splitNonEmpty(new), max: 3, kind: .add)
            if more > 0 { out.append(Line(text: "+\(more) more edit\(more == 1 ? "" : "s")", kind: .plain)) }
            return out.isEmpty ? [Line(text: "(no change)", kind: .plain)] : out
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
        for line in lines {
            let (gutter, gutterColor, textColor): (String, NSColor, NSColor)
            switch line.kind {
            case .add:   (gutter, gutterColor, textColor) = ("+", .systemGreen, .labelColor)
            case .del:   (gutter, gutterColor, textColor) = ("−", .systemRed, .secondaryLabelColor)
            case .plain: (gutter, gutterColor, textColor) = (" ", .clear, .secondaryLabelColor)
            }
            if line.kind != .plain {
                NSAttributedString(string: gutter, attributes: [.font: Self.mono, .foregroundColor: gutterColor])
                    .draw(at: NSPoint(x: leading - 12, y: y))
            }
            NSAttributedString(string: line.text, attributes: [
                .font: Self.mono, .foregroundColor: textColor, .paragraphStyle: para,
            ]).draw(in: NSRect(x: leading, y: y, width: bounds.width - leading - 14, height: lineH))
            y -= lineH
        }
    }
}

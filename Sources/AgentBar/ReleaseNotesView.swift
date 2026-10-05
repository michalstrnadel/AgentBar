import Cocoa

/// One release's notes, drawn: its headings, paragraphs and bullets as the
/// changelog writes them, with **bold**, `code` and links kept. Selectable, so a
/// command in the notes can be copied; links open in the browser.
///
/// A text view rather than a label because only a text view lays out a hanging
/// indent for bullets and follows a link on click. It is fixed to the width it is
/// given and states its own height, measured — the same reason
/// `SettingsChrome.fit` exists: a wrapping view inside two stacks that guesses its
/// height is a view whose last line is cut off.
final class ReleaseNotesView: NSView {
    static let bodySize: CGFloat = 12.5
    /// A faint wash behind `code`, in either appearance. Not a system colour with
    /// its alpha changed: `withAlphaComponent` replaces the alpha rather than
    /// scaling it, and the quaternary label grey came out as a slab.
    static let codeFill = NSColor(name: nil) { a in
        a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.white.withAlphaComponent(0.09) : NSColor.black.withAlphaComponent(0.05)
    }
    static let repoFiles = URL(string: "https://github.com/michalstrnadel/AgentBar/blob/main/")!

    private let text = NSTextView()

    init(_ release: ReleaseNotes.Release, width: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 10))
        translatesAutoresizingMaskIntoConstraints = false
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = .zero
        text.textContainer?.lineFragmentPadding = 0
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        text.isVerticallyResizable = false
        text.linkTextAttributes = [.foregroundColor: NSColor.linkColor,
                                   .cursor: NSCursor.pointingHand]
        text.textStorage?.setAttributedString(Self.render(release.blocks))
        text.setAccessibilityLabel("Release notes for \(release.version)")
        let height = Self.height(of: text, width: width)
        text.frame = NSRect(x: 0, y: 0, width: width, height: height)
        addSubview(text)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            heightAnchor.constraint(equalToConstant: height),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    private static func height(of view: NSTextView, width: CGFloat) -> CGFloat {
        guard let lm = view.layoutManager, let tc = view.textContainer else { return 0 }
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height)
    }

    // MARK: - Rendering

    /// The blocks as one attributed string. Internal so a test can read what a
    /// changelog section turns into without a window.
    static func render(_ blocks: [ReleaseNotes.Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for (i, block) in blocks.enumerated() {
            let first = i == 0
            switch block {
            case .heading(let s):
                let p = paragraph(before: first ? 0 : 10, after: 4)
                out.append(inline(s, size: bodySize, weight: .semibold, color: .labelColor, style: p))
            case .paragraph(let s):
                let p = paragraph(before: first ? 0 : 6, after: 2)
                out.append(inline(s, size: bodySize, weight: .regular, color: .secondaryLabelColor, style: p))
            case .bullet(let s, let level):
                let indent: CGFloat = level == 0 ? 14 : 28
                let p = paragraph(before: first ? 0 : 4, after: 0)
                p.headIndent = indent
                p.firstLineHeadIndent = indent - 12
                p.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                let mark = NSAttributedString(string: (level == 0 ? "•" : "◦") + "\t", attributes: [
                    .font: NSFont.systemFont(ofSize: bodySize),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: p,
                ])
                out.append(mark)
                out.append(inline(s, size: bodySize, weight: .regular, color: .labelColor, style: p))
            }
            if i < blocks.count - 1 { out.append(NSAttributedString(string: "\n")) }
        }
        return out
    }

    private static func paragraph(before: CGFloat, after: CGFloat) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.lineSpacing = 1.5
        return p
    }

    /// Bold, italic, code and links from the changelog's inline Markdown, in this
    /// window's type rather than whatever a generic Markdown renderer picks.
    /// Text that will not parse is shown as written.
    static func inline(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor,
                       style: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: style,
        ]
        guard let parsed = try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSAttributedString(string: s, attributes: base)
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            var attrs = base
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.code) {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular)
                attrs[.backgroundColor] = codeFill
            } else {
                var font = NSFont.systemFont(ofSize: size,
                                             weight: intent.contains(.stronglyEmphasized) ? .semibold : weight)
                if intent.contains(.emphasized) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                attrs[.font] = font
                if intent.contains(.stronglyEmphasized) { attrs[.foregroundColor] = NSColor.labelColor }
            }
            // Only the web: a changelog that linked a file: or custom scheme should
            // not have a click run it.
            // A path is the repository's, as it reads on GitHub.
            if let link = run.link {
                if ["https", "http"].contains(link.scheme?.lowercased() ?? "") {
                    attrs[.link] = link
                } else if link.scheme == nil, !link.relativeString.hasPrefix("/") {
                    attrs[.link] = URL(string: link.relativeString, relativeTo: repoFiles)?.absoluteURL
                }
            }
            out.append(NSAttributedString(string: piece, attributes: attrs))
        }
        return out
    }
}

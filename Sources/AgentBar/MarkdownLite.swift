import Cocoa

/// Just enough Markdown for a plan on the island's dark card: headings, bullets,
/// numbered lists, fenced and inline code, bold. Line-based and dependency-free —
/// a plan is read once and approved, not typeset; anything the subset doesn't
/// know stays visible as the literal text rather than vanishing.
enum MarkdownLite {
    static func render(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (i, sub) in lines.enumerated() {
            let line = String(sub)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inFence.toggle()
                continue // the fence markers themselves are noise
            }
            // The separator carries the base font explicitly: an attribute-less
            // newline measures with AppKit's default font and the box would come
            // out a hair shorter than the field actually renders.
            if i > 0, out.length > 0 {
                out.append(NSAttributedString(string: "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                ]))
            }
            if inFence {
                out.append(NSAttributedString(string: line, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                    .paragraphStyle: indent(14),
                ]))
                continue
            }
            if trimmed.isEmpty { continue } // the \n above already gave the gap
            if let heading = headingLevel(trimmed) {
                out.append(NSAttributedString(string: heading.text, attributes: [
                    .font: NSFont.systemFont(ofSize: heading.level == 1 ? 13 : 12,
                                             weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                    .paragraphStyle: spaced(before: out.length > 0 ? 8 : 0),
                ]))
                continue
            }
            if let bullet = bulletText(trimmed) {
                let prefixed = NSMutableAttributedString(string: "•  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.5),
                    .paragraphStyle: indent(12),
                ])
                prefixed.append(inline(bullet, style: indent(12)))
                out.append(prefixed)
                continue
            }
            out.append(inline(trimmed, style: indent(0)))
        }
        return out
    }

    // MARK: - Line shapes

    private static func headingLevel(_ s: String) -> (level: Int, text: String)? {
        guard s.hasPrefix("#") else { return nil }
        let level = s.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let text = s.dropFirst(level).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }

    private static func bulletText(_ s: String) -> String? {
        for mark in ["- ", "* ", "+ "] where s.hasPrefix(mark) {
            return String(s.dropFirst(mark.count))
        }
        return nil
    }

    // MARK: - Inline runs (`code` and **bold**; the rest passes through)

    private static func inline(_ s: String, style: NSParagraphStyle) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
            .paragraphStyle: style,
        ]
        // Backticks split the line into text/code/text/…; an odd part count means
        // every backtick found its pair. Unpaired ones keep the line literal.
        let parts = s.components(separatedBy: "`")
        guard parts.count > 1, parts.count % 2 == 1 else {
            return bolded(s, base: base, style: style)
        }
        let out = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                out.append(NSAttributedString(string: part, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.9),
                    .paragraphStyle: style,
                ]))
            } else {
                out.append(bolded(part, base: base, style: style))
            }
        }
        return out
    }

    private static func bolded(_ s: String, base: [NSAttributedString.Key: Any],
                               style: NSParagraphStyle) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let parts = s.components(separatedBy: "**")
        // Even count means an unpaired ** — treat the whole thing as plain.
        guard parts.count % 2 == 1, parts.count > 1 else {
            return NSAttributedString(string: s, attributes: base)
        }
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                out.append(NSAttributedString(string: part, attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                    .paragraphStyle: style,
                ]))
            } else {
                out.append(NSAttributedString(string: part, attributes: base))
            }
        }
        return out
    }

    // MARK: - Paragraph styles

    private static func indent(_ head: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.headIndent = head
        p.lineBreakMode = .byWordWrapping
        p.paragraphSpacing = 2
        return p
    }

    private static func spaced(before: CGFloat) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = 3
        p.lineBreakMode = .byWordWrapping
        return p
    }
}

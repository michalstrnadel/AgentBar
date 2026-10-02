import Cocoa

/// The small agent marks the menu draws beside rows — one cap height, one
/// shared box, so every row keeps the same gutter whatever agent it names.
extension MenuBuilder {
    /// Small resting mark used as the item icon in the Open submenu. Every mark is
    /// tight-trimmed to its glyph, normalized to one cap height, then centered on
    /// one shared canvas (sized by the widest glyph) — identical image bounds give
    /// every row the same gutter and title inset, with no per-glyph jitter. Codex
    /// and Copilot use their clean dot-free glyph (the bar sprite carries a
    /// dot-matrix); Cursor and Gemini knock out their full-res app icon so both
    /// read at the same solid weight as the mascots.
    private static let markCapHeight: CGFloat = 13

    private static let knownGlyphs: [(id: String, glyph: NSImage)] = Agent.all.map { agent in
        let template: NSImage
        switch agent.id {
        case "codex":
            template = IconRenderer.decode(codexMascotMarkPNG).map {
                IconRenderer.solidTemplate(IconRenderer.trim($0))
            } ?? trimmedTemplate(for: agent)
        case "copilot":
            template = IconRenderer.decode(copilotMascotMarkPNG).map {
                IconRenderer.adaptiveTemplate(IconRenderer.trim($0))
            } ?? trimmedTemplate(for: agent)
        case "cursor":
            template = IconRenderer.decode(cursorLogoPNG).map {
                IconRenderer.adaptiveTemplate(IconRenderer.trim($0), knockout: true)
            } ?? trimmedTemplate(for: agent)
        case "gemini":
            template = IconRenderer.decode(geminiLogoPNG).map {
                IconRenderer.adaptiveTemplate(IconRenderer.trim($0), knockout: true)
            } ?? trimmedTemplate(for: agent)
        default:
            template = trimmedTemplate(for: agent)
        }
        return (agent.id, capped(template))
    }

    /// The one column every mark is centred in, known agents and generic ones
    /// alike, so a row for an agent AgentBar has never heard of lines its name up
    /// with everybody else's instead of starting a few points to the left.
    private static let markBoxWidth: CGFloat =
        knownGlyphs.map { $0.glyph.size.width }.max() ?? markCapHeight

    private static let menuMarks: [String: NSImage] =
        Dictionary(uniqueKeysWithValues: knownGlyphs.map { ($0.id, boxed($0.glyph)) })

    static func menuMark(for agent: Agent) -> NSImage {
        menuMarks[agent.id] ?? boxed(capped(trimmedTemplate(for: agent)))
    }

    /// Scaled to the shared cap height, width following the mark's own aspect.
    private static func capped(_ template: NSImage) -> NSImage {
        let img = template.copy() as! NSImage
        let scale = markCapHeight / max(img.size.height, 1)
        img.size = NSSize(width: (img.size.width * scale).rounded(), height: markCapHeight)
        return img
    }

    /// Centred in the shared box. A mark wider than the box is shrunk to fit it
    /// rather than spilling into the row's title.
    private static func boxed(_ glyph: NSImage) -> NSImage {
        let box = markBoxWidth
        let w = min(glyph.size.width, box)
        let h = glyph.size.width > box ? markCapHeight * box / glyph.size.width : markCapHeight
        let out = NSImage(size: NSSize(width: box, height: markCapHeight))
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        glyph.draw(in: NSRect(x: ((box - w) / 2).rounded(), y: ((markCapHeight - h) / 2).rounded(),
                              width: w, height: h))
        out.unlockFocus()
        out.isTemplate = true
        return out
    }

    /// Resting template of an agent's sprite, tight-trimmed and re-flagged as template.
    private static func trimmedTemplate(for agent: Agent) -> NSImage {
        let t = IconRenderer.trim(IconRenderer.shared.sprite(for: agent).restingTemplate)
        t.isTemplate = true
        return t
    }
}

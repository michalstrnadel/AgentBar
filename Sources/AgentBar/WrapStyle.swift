import AppKit

/// The recap's look: palettes, type, motion, and the few drawing primitives the
/// card is made of. Kept apart from `WrapRenderer` so the card reads as layout,
/// and so one change to the type or the easing reaches all of them.
///
/// Everything draws into a **flipped** context (y grows downward) in a canvas whose
/// short side is 1080 units: `u` converts. The live player and every export call
/// the same functions, so a shared card is exactly what was on screen.
enum WrapStyle {
    // MARK: - Colour

    static func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                blue: CGFloat(v & 0xff) / 255, alpha: a)
    }

    // The card: paper, ink, and nothing that glows.
    static let paper = hex(0xF7F5F0)
    static let ink = hex(0x1D1D1F)
    static let secondary = hex(0x6E6E73)
    static let tertiary = hex(0xA1A1A6)
    static let hairline = hex(0xE2DED6)
    static let added = hex(0x1E8E3E)
    static let removed = hex(0xC5221F)


    /// An agent's colour as the recap paints it. Cursor and OpenCode wear the
    /// system label colour in the menu bar, which is nothing on a poster, so they
    /// get a fixed one; everyone else keeps their brand.
    static func colour(for agentID: String) -> NSColor {
        switch agentID {
        case "cursor":   return hex(0xE8E8E8)
        case "opencode": return hex(0xF2C14E)
        case "":         return secondary
        default:
            let c = Agent.byID(agentID).brand.usingColorSpace(.sRGB) ?? secondary
            return c
        }
    }

    /// An agent's colour as ink on paper: a brand too pale to read on the card
    /// (Cursor's near-white) falls back to the secondary grey.
    static func onPaper(_ agentID: String) -> NSColor {
        let c = colour(for: agentID).usingColorSpace(.sRGB) ?? secondary
        let lum = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return lum > 0.8 ? secondary : c
    }

    // MARK: - Motion

    static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    static func easeOut(_ x: Double) -> Double { let p = 1 - clamp(x); return 1 - p * p * p }
    /// 0…1 for an element that starts `delay` seconds into the build and takes `dur`.
    static func appear(_ seconds: Double, _ delay: Double, _ dur: Double = 0.7) -> Double {
        clamp((seconds - delay) / dur)
    }

    // MARK: - Type

    static func font(_ size: CGFloat, _ weight: NSFont.Weight = .black, rounded: Bool = false) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        guard rounded, let d = f.fontDescriptor.withDesign(.rounded) else { return f }
        return NSFont(descriptor: d, size: size) ?? f
    }

    enum Align { case left, center, right }

    /// Draws `s` with its top at `y`, and returns its height. Tracking is in
    /// thousandths of an em, as a designer would say it: −40 is tight display type.
    @discardableResult
    static func text(_ s: String, _ font: NSFont, _ color: NSColor, x: CGFloat, y: CGFloat,
                     width: CGFloat, align: Align = .left, tracking: CGFloat = 0,
                     lineHeight: CGFloat = 1.0, alpha: CGFloat = 1) -> CGFloat {
        let p = NSMutableParagraphStyle()
        p.alignment = align == .left ? .left : align == .center ? .center : .right
        p.lineBreakMode = .byWordWrapping
        p.minimumLineHeight = font.pointSize * lineHeight
        p.maximumLineHeight = font.pointSize * lineHeight
        let attr = NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: color.withAlphaComponent(color.alphaComponent * alpha),
            .kern: font.pointSize * tracking / 1000, .paragraphStyle: p,
        ])
        let bounds = attr.boundingRect(with: NSSize(width: width, height: 10_000),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading])
        attr.draw(with: NSRect(x: x, y: y, width: width, height: ceil(bounds.height) + 2),
                  options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    /// Draws an attributed string with its top at `y`, and returns its height.
    @discardableResult
    static func rich(_ s: NSAttributedString, x: CGFloat, y: CGFloat, width: CGFloat,
                     lineHeight: CGFloat = 1.2) -> CGFloat {
        let m = NSMutableAttributedString(attributedString: s)
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        if let f = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            p.minimumLineHeight = f.pointSize * lineHeight
            p.maximumLineHeight = f.pointSize * lineHeight
        }
        m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
        let bounds = m.boundingRect(with: NSSize(width: width, height: 10_000),
                                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        m.draw(with: NSRect(x: x, y: y, width: width, height: ceil(bounds.height) + 2),
               options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(bounds.height)
    }

    static func measure(_ s: String, _ font: NSFont, tracking: CGFloat = 0) -> CGSize {
        NSAttributedString(string: s, attributes: [.font: font, .kern: font.pointSize * tracking / 1000])
            .size()
    }

    /// The largest size up to `max` at which `s` fits on one line in `width`.
    static func fitting(_ s: String, max: CGFloat, width: CGFloat, weight: NSFont.Weight = .black,
                        rounded: Bool = false, tracking: CGFloat = -40) -> NSFont {
        var size = max
        while size > 12 {
            let f = font(size, weight, rounded: rounded)
            if measure(s, f, tracking: tracking).width <= width { return f }
            size *= 0.94
        }
        return font(size, weight, rounded: rounded)
    }

    // MARK: - Numbers

    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// "5h 42m", counting up: minutes are what tick.
    static func duration(_ seconds: TimeInterval, progress: Double = 1) -> String {
        HistoryDigest.duration(seconds * progress < 60 && seconds >= 60 ? 60 : seconds * progress)
    }

    static func shortWait(_ s: TimeInterval) -> String {
        s < 60 ? "\(max(1, Int(s.rounded()))) s" : HistoryDigest.duration(s)
    }

    // MARK: - Shapes

    static func fill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        rect.fill()
    }

    static func circle(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }

    static func pill(_ rect: CGRect, _ color: NSColor, radius: CGFloat? = nil) {
        color.setFill()
        let r = radius ?? min(rect.width, rect.height) / 2
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }

    /// Draws an image into a flipped context the right way up.
    static func image(_ img: NSImage, in rect: CGRect, alpha: CGFloat = 1) {
        img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha,
                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }

    // MARK: - Marks

    /// An agent's mark at poster size, from its source artwork rather than the
    /// 17-point menu bar frames, which would blur at this scale. Clawd is drawn
    /// as pixels by `clawd(…)` instead and returns nil here.
    static func mark(for agentID: String) -> NSImage? {
        if let m = markCache[agentID] { return m }
        let agent = Agent.byID(agentID)
        let image: NSImage?
        switch agent.artwork {
        case .clawd:
            image = nil
        case .frames(let pngs, _):
            image = pngs.first.flatMap(IconRenderer.decode).map(IconRenderer.trim)
        case .markFrames(let pngs, _):
            image = pngs.first.flatMap(IconRenderer.decode).map(IconRenderer.trim)
        case .colorMark(let png), .appIconMark(let png):
            image = IconRenderer.decode(png).map(IconRenderer.trim)
        case .tintedMark(let png):
            image = IconRenderer.decode(png).map { IconRenderer.tint(IconRenderer.trim($0), with: colour(for: agentID)) }
        case .monogram(let letter):
            image = IconRenderer.tint(IconRenderer.monogram(letter, height: 256), with: colour(for: agentID))
        }
        markCache[agentID] = image
        return image
    }

    private static var markCache: [String: NSImage?] = [:]

    /// Clawd, in his own pixels, `pixel` units to a square, with his top-left at
    /// `origin`. `pose` is a `ClawdSceneArt` grid; `bodyOnly` drops the props.
    static func clawd(_ pose: String, origin: CGPoint, pixel: CGFloat, alpha: CGFloat = 1) {
        for (y, line) in pose.split(separator: "\n").enumerated() {
            for (x, mark) in line.enumerated() {
                guard let rgb = ClawdSceneArt.palette[mark] else { continue }
                hex(rgb, alpha).setFill()
                // A hair of overlap so neighbouring squares never show a seam.
                CGRect(x: origin.x + CGFloat(x) * pixel, y: origin.y + CGFloat(y) * pixel,
                       width: pixel + 0.5, height: pixel + 0.5).fill()
            }
        }
    }

    /// Clawd's poses for a scene, or the thinking ones when the scene has none.
    static func clawdPoses(_ scene: ClawdScene) -> [String] {
        scene.reel?.poses ?? ClawdScene.think.reel?.poses ?? []
    }
}

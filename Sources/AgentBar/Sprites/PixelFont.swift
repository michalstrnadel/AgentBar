import Cocoa

/// The island games' lettering: `BreakGameArt.glyphs`, three by five, drawn as
/// filled cells so it stays pixels at any scale. Shared by both games' views.
enum PixelFont {
    /// `s` with its baseline at `y`.
    static func text(_ ctx: CGContext, _ s: String, x: CGFloat, y: CGFloat, pixel: CGFloat, color: NSColor) {
        ctx.setFillColor(color.cgColor)
        var cx = x
        for ch in s {
            for (col, row) in BreakGameArt.cells(ch) {
                ctx.fill(CGRect(x: cx + CGFloat(col) * pixel, y: y + CGFloat(4 - row) * pixel,
                                width: pixel, height: pixel))
            }
            cx += 4 * pixel
        }
    }

    /// `s` centred on `mid`.
    static func banner(_ ctx: CGContext, _ s: String, y: CGFloat, pixel: CGFloat, color: NSColor, mid: CGFloat) {
        text(ctx, s, x: mid - width(s, pixel: pixel) / 2, y: y, pixel: pixel, color: color)
    }

    static func width(_ s: String, pixel: CGFloat) -> CGFloat { BreakGameArt.textWidth(s, pixel: pixel) }

    static func color(_ rgb: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xff) / 255, green: CGFloat(rgb >> 8 & 0xff) / 255,
                blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

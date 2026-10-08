// Draws the background of the DMG window: paper, the AgentBar wordmark in its
// outlined pill (the product page's), a thin arrow from the app to Applications,
// and Clawd peeking up from the bottom edge. How to get past Gatekeeper on the
// first launch is a text file beside it, not small print on the picture.
//
//   swift Scripts/dev/dmg-background.swift OUT_DIR [REPO_ROOT]
//
// Writes background.png (660×440) and background@2x.png; make-dmg.sh joins them
// into one TIFF so Finder picks the sharp one on a Retina screen. Coordinates match
// the icon positions in make-dmg.sh (app at 170, Applications at 490, y 215 from
// the top). Clawd is the app's own sprite, the first frame of its walk.
import AppKit

let size = NSSize(width: 660, height: 440)
let args = CommandLine.arguments.dropFirst()
let out = args.first ?? "."
// `swift file.swift` runs a compiled copy elsewhere, so the repo is passed in.
let root = URL(fileURLWithPath: args.dropFirst().first ?? FileManager.default.currentDirectoryPath)

/// The first walking frame, out of the generated Swift that ships it.
func clawd() -> NSBitmapImageRep? {
    let src = root.appendingPathComponent("Sources/AgentBar/Sprites/CrabFrames.swift")
    guard let text = try? String(contentsOf: src, encoding: .utf8),
          let open = text.range(of: "[\n  \""),
          let close = text.range(of: "\"", range: open.upperBound..<text.endIndex),
          let data = Data(base64Encoded: String(text[open.upperBound..<close.lowerBound]))
    else { return nil }
    return NSBitmapImageRep(data: data)
}

func render(scale: CGFloat) -> Data {
    let px = NSSize(width: size.width * scale, height: size.height * scale)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    // y runs up from the bottom here; the comments say "from the top" where the
    // number comes from make-dmg.sh.
    NSColor(srgbRed: 0.968, green: 0.960, blue: 0.945, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    let ink = NSColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)

    // The wordmark: bold, tight, in a pill with a heavy outline.
    let font = NSFont.systemFont(ofSize: 34, weight: .heavy)
    let word = NSAttributedString(string: "AgentBar", attributes: [.font: font, .foregroundColor: ink,
                                                                   .kern: -1.4])
    let w = word.size()
    let pill = NSRect(x: (size.width - w.width - 44) / 2, y: size.height - 46 - 58, width: w.width + 44, height: 58)
    let outline = NSBezierPath(roundedRect: pill.insetBy(dx: 2.5, dy: 2.5), xRadius: 26.5, yRadius: 26.5)
    outline.lineWidth = 5
    ink.setStroke()
    outline.stroke()
    word.draw(at: NSPoint(x: pill.midX - w.width / 2, y: pill.midY - w.height / 2 + 1))

    // The arrow between the two icons, at icon centre height (215 from the top).
    let y = size.height - 215
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 262, y: y))
    arrow.curve(to: NSPoint(x: 396, y: y + 2), controlPoint1: NSPoint(x: 305, y: y + 9),
                controlPoint2: NSPoint(x: 350, y: y + 8))
    arrow.move(to: NSPoint(x: 383, y: y + 12))
    arrow.line(to: NSPoint(x: 397, y: y + 2))
    arrow.line(to: NSPoint(x: 382, y: y - 6))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    ink.withAlphaComponent(0.45).setStroke()
    arrow.stroke()

    // Clawd, pixel for pixel, peeking up from the bottom edge.
    // Each sprite pixel is filled as a square of its own, so nothing smooths the
    // edges whatever the scale.
    if let crab = clawd() {
        let k: CGFloat = 3
        let cw = CGFloat(crab.pixelsWide) * k, ch = CGFloat(crab.pixelsHigh) * k
        let origin = NSPoint(x: ((size.width - cw) / 2).rounded(), y: (-ch * 0.22).rounded())
        for py in 0..<crab.pixelsHigh {
            for px in 0..<crab.pixelsWide {
                guard let c = crab.colorAt(x: px, y: py), c.alphaComponent > 0.5 else { continue }
                c.withAlphaComponent(1).setFill()
                NSRect(x: origin.x + CGFloat(px) * k,
                       y: origin.y + CGFloat(crab.pixelsHigh - 1 - py) * k,
                       width: k, height: k).fill()
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try! render(scale: 1).write(to: URL(fileURLWithPath: out).appendingPathComponent("background.png"))
try! render(scale: 2).write(to: URL(fileURLWithPath: out).appendingPathComponent("background@2x.png"))
print("wrote \(out)/background.png and background@2x.png")

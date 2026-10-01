// Generates docs/assets/social-preview.png: the 2560x1280 GitHub social banner —
// the app icon on the left, the name, the tagline, and the four agent dots.
// Usage (from repo root):
//   swift Scripts/appicon.swift /tmp/icon_1024.png
//   swift Scripts/demo/social-preview.swift /tmp/icon_1024.png docs/assets/social-preview.png
// The icon argument is the 1024 master, not the 256 README copy.
import AppKit

let W: CGFloat = 2560, H: CGFloat = 1280
let iconPath = CommandLine.arguments[1]
let outPath = CommandLine.arguments[2]

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
// Flipped, so every y below is measured from the top like the design grid.
let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
cg.translateBy(x: 0, y: H)
cg.scaleBy(x: 1, y: -1)
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)

NSGradient(colors: [color(0xFDFBF7), color(0xF3EDE3)])!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

// Icon: the master PNG carries the macOS grid margin and its own shadow.
if let icon = NSImage(contentsOfFile: iconPath) {
    icon.draw(in: NSRect(x: 225, y: 265, width: 750, height: 750), from: .zero,
              operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

func text(_ s: String, _ font: NSFont, _ c: NSColor, x: CGFloat, baseline: CGFloat, kern: CGFloat = 0) {
    let attr = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: c, .kern: kern])
    attr.draw(at: NSPoint(x: x, y: baseline - font.ascender))
}
text("AgentBar", .systemFont(ofSize: 194, weight: .bold), color(0x262421), x: 1049, baseline: 597, kern: -5.5)
text("One approval queue for every AI coding agent.", .systemFont(ofSize: 64, weight: .regular),
     color(0x6D655C), x: 1058, baseline: 724, kern: -0.8)
text("Menu bar or notch · Allow/Deny in one click", .monospacedSystemFont(ofSize: 40, weight: .regular),
     color(0x998C80), x: 1062, baseline: 840)

// Four agent dots, bottom right: Claude, Codex, Copilot, Antigravity.
for (i, hex) in [0xD97757, 0x10A37F, 0x8250DF, 0x4285F4].enumerated() {
    color(UInt32(hex), 0.6).setFill()
    NSBezierPath(ovalIn: NSRect(x: 2330 + CGFloat(i) * 52, y: 1174, width: 20, height: 20)).fill()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)")

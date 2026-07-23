// Renders the AgentBar app icon (1024x1024 master PNG).
// Light ivory squircle, charcoal prompt chevron, and a menu-bar-item pill with the
// four agent status dots — one lit (the session that needs you), three dimmed.
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fatalError("no context")
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let charcoal = rgb(0x262421)
// Agent brand dots: Claude, Codex, Copilot, Antigravity — same hexes as Agents.swift.
let brand: [UInt32] = [0xD97757, 0x10A37F, 0x8250DF, 0x4285F4]

// ---- Light background squircle (Apple grid: 824x824 centered, r ~185) ----
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.clip()
let grad = CGGradient(colorsSpace: srgb,
                      colors: [rgb(0xFDFBF7), rgb(0xF6F1E8), rgb(0xEDE6DA)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S - inset),
                       end: CGPoint(x: S/2, y: inset), options: [])
ctx.restoreGState()

// Hairline edge so the light icon doesn't dissolve on white backgrounds.
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.setStrokeColor(rgb(0x262421, 0.14))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// ---- Charcoal prompt chevron ----
let cx: CGFloat = 512
let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: cx - 118, y: 724))
chevron.addLine(to: CGPoint(x: cx + 86, y: 560))
chevron.addLine(to: CGPoint(x: cx - 118, y: 396))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20,
              color: CGColor(srgbRed: 0.15, green: 0.12, blue: 0.10, alpha: 0.22))
ctx.addPath(chevron)
ctx.setStrokeColor(charcoal)
ctx.setLineWidth(82)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// ---- Menu bar item: pill outline, one lit dot + three dimmed ----
let bar = CGRect(x: cx - 26 - 170, y: 232, width: 340, height: 76)
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: bar, cornerWidth: 38, cornerHeight: 38, transform: nil))
ctx.setStrokeColor(rgb(0x262421, 0.85))
ctx.setLineWidth(14)
ctx.strokePath()
ctx.restoreGState()

let r: CGFloat = 20, gap: CGFloat = 26
let step = r * 2 + gap
var x = bar.midX - (step * 3) / 2
for (i, hex) in brand.enumerated() {
    ctx.setFillColor(i == 0 ? rgb(hex) : rgb(hex, 0.35))
    ctx.fillEllipse(in: CGRect(x: x - r, y: bar.midY - r, width: r * 2, height: r * 2))
    x += step
}

// ---- Write PNG ----
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

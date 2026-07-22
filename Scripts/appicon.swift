// Renders the Claude Status Notifier app icon (1024x1024 master PNG).
// Dark terminal-style squircle with a prompt chevron and a terracotta cursor bar.
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

// ---- Background squircle (Apple grid: 824x824 centered, r ~185) ----
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
let squircle = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let grad = CGGradient(colorsSpace: srgb,
                      colors: [rgb(0x34312D), rgb(0x262421), rgb(0x1B1917)] as CFArray,
                      locations: [0, 0.55, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: S/2, y: S - inset),
                       end: CGPoint(x: S/2, y: inset), options: [])
// Faint top sheen
let sheen = CGGradient(colorsSpace: srgb,
                       colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.07),
                                CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray,
                       locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: S/2, y: S - inset),
                       end: CGPoint(x: S/2, y: S/2 + 100), options: [])
ctx.restoreGState()

// Hairline inner highlight on the squircle edge
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3, dy: 3), cornerWidth: 182, cornerHeight: 182, transform: nil))
ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10))
ctx.setLineWidth(6)
ctx.strokePath()
ctx.restoreGState()

// ---- Prompt chevron (ivory) ----
let cx: CGFloat = 512
let ivory = rgb(0xFAF6F0)

let chevron = CGMutablePath()
chevron.move(to: CGPoint(x: cx - 118, y: 712))
chevron.addLine(to: CGPoint(x: cx + 86, y: 548))
chevron.addLine(to: CGPoint(x: cx - 118, y: 384))

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 26,
              color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.45))
ctx.addPath(chevron)
ctx.setStrokeColor(ivory)
ctx.setLineWidth(82)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// ---- Cursor bar (terracotta, slight glow) ----
let barRect = CGRect(x: cx - 138, y: 246, width: 300, height: 62)
let barPath = CGPath(roundedRect: barRect, cornerWidth: 31, cornerHeight: 31, transform: nil)

// Glow
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 60, color: rgb(0x8250DF, 0.45))
ctx.addPath(barPath)
ctx.setFillColor(rgb(0xD97757))
ctx.fillPath()
ctx.restoreGState()

// Gradient fill on top of the glowed base
ctx.saveGState()
ctx.addPath(barPath)
ctx.clip()
let barGrad = CGGradient(colorsSpace: srgb,
                         colors: [rgb(0xD97757), rgb(0x10A37F), rgb(0x8250DF), rgb(0x4285F4)] as CFArray,
                         locations: [0, 0.34, 0.67, 1])!
ctx.drawLinearGradient(barGrad, start: CGPoint(x: barRect.minX, y: barRect.midY),
                       end: CGPoint(x: barRect.maxX, y: barRect.midY), options: [])
ctx.restoreGState()

// ---- Write PNG ----
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")

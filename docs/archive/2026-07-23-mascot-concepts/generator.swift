// Generates original animated mascots for Codex / Copilot / Antigravity.
// Outputs: transparent frame PNGs (for baking into the app), preview GIFs on
// dark & light menu-bar backgrounds, an actual-size bar mock GIF, and a contact sheet.
// Usage: swift mascots.swift <outDir>
import AppKit
import UniformTypeIdentifiers

let P: CGFloat = 10                    // canvas pixels per design unit
let W = 280, H = 200                   // 28 x 20 units
let outDir = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func makeCtx(_ w: Int = W, _ h: Int = H) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// Unit-space helpers (y up).
func rect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ col: CGColor) {
    c.setFillColor(col)
    c.fill(CGRect(x: x * P, y: y * P, width: w * P, height: h * P))
}
func rrect(_ c: CGContext, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat,
           _ r: CGFloat, _ col: CGColor) {
    c.setFillColor(col)
    let path = CGPath(roundedRect: CGRect(x: x * P, y: y * P, width: w * P, height: h * P),
                      cornerWidth: r * P, cornerHeight: r * P, transform: nil)
    c.addPath(path); c.fillPath()
}
func circle(_ c: CGContext, _ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ col: CGColor) {
    c.setFillColor(col)
    c.fillEllipse(in: CGRect(x: (cx - r) * P, y: (cy - r) * P, width: r * 2 * P, height: r * 2 * P))
}
func poly(_ c: CGContext, _ pts: [(CGFloat, CGFloat)], _ col: CGColor) {
    let path = CGMutablePath()
    path.move(to: CGPoint(x: pts[0].0 * P, y: pts[0].1 * P))
    for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.0 * P, y: p.1 * P)) }
    path.closeSubpath()
    c.setFillColor(col)
    c.addPath(path); c.fillPath()
}

// ============================== CODEX ==============================
// A little walking terminal robot: bright teal body, dark screen (drops out as a
// "hole" in System mode, like the crab's eyes), blinking cursor, antenna.
let codexBody = color(0x14B394)        // brighter than brand #10A37F so the
let codexDarkScreen = color(0x073B30)  // adaptive template keeps the body solid
let codexCursor = color(0xD9FFF2)

func codexFrame(_ f: Int, _ c: CGContext) {
    let n = 10
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi
    let lLift = max(0, sin(t)) * 1.1          // legs alternate smoothly
    let rLift = max(0, -sin(t)) * 1.1
    let bob = abs(sin(t)) * 0.55              // two bounces per cycle = walk
    let ground: CGFloat = 2.5
    let legH: CGFloat = 2.6
    let bodyY = ground + legH - 0.6 + bob

    // legs + feet
    rrect(c, 10.4, ground + lLift, 1.7, legH + 1, 0.5, codexBody)
    rrect(c, 15.9, ground + rLift, 1.7, legH + 1, 0.5, codexBody)
    rrect(c, 9.9, ground + lLift, 2.7, 1.0, 0.4, codexBody)
    rrect(c, 15.4, ground + rLift, 2.7, 1.0, 0.4, codexBody)

    // arms swing opposite to legs
    let swing = sin(t) * 0.5
    rrect(c, 6.4, bodyY + 3.4 + swing, 1.6, 2.6, 0.7, codexBody)
    rrect(c, 20.0, bodyY + 3.4 - swing, 1.6, 2.6, 0.7, codexBody)

    // body + screen
    rrect(c, 8, bodyY, 12, 9.2, 1.8, codexBody)
    rrect(c, 9.7, bodyY + 1.9, 8.6, 5.4, 0.9, codexDarkScreen)

    // prompt ">" + blinking cursor
    let sx = 10.7, sy = bodyY + 3.4
    poly(c, [(sx, sy + 2.2), (sx + 1.3, sy + 1.3), (sx, sy + 0.4),
             (sx, sy + 1.0), (sx + 0.5, sy + 1.3), (sx, sy + 1.6)], codexCursor)
    if f % n < n / 2 + 1 {
        rect(c, sx + 2.0, sy + 0.4, 1.3, 1.9, codexCursor)
    }

    // antenna with pulsing tip
    rect(c, 13.7, bodyY + 9.0, 0.6, 1.9, codexBody)
    circle(c, 14.0, bodyY + 11.5, 0.85, color(0x14B394, 0.55 + 0.45 * (0.5 + 0.5 * sin(t * 2))))
}

// ============================== COPILOT ==============================
// A purple paper plane in a gentle wave flight — the "pilot" — with a fading trail.
func copilotFrame(_ f: Int, _ c: CGContext) {
    let n = 10
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi
    let dy = sin(t) * 1.7
    let rot = sin(t + .pi / 2) * 9 * .pi / 180

    // trail dashes drifting left, fading with distance
    let phase = CGFloat(f % n) / CGFloat(n) * 3.4
    for i in 0..<3 {
        let x = 8.5 - CGFloat(i) * 3.4 - phase
        if x < 0.5 { continue }
        let a = 0.42 - CGFloat(i) * 0.12 - phase * 0.04
        rrect(c, x, 9.6 + dy * CGFloat(0.35 - Double(i) * 0.12), 2.0, 0.8, 0.4,
              color(0x8250DF, max(0.06, a)))
    }

    c.saveGState()
    c.translateBy(x: 16.5 * P, y: (10 + dy) * P)
    c.rotate(by: rot)
    func rpoly(_ pts: [(CGFloat, CGFloat)], _ col: CGColor) {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: pts[0].0 * P, y: pts[0].1 * P))
        for p in pts.dropFirst() { path.addLine(to: CGPoint(x: p.0 * P, y: p.1 * P)) }
        path.closeSubpath()
        c.setFillColor(col); c.addPath(path); c.fillPath()
    }
    // upper wing (light), lower fold (mid), belly fin (deep = template hole edge)
    rpoly([(8.2, 0.4), (-7.6, 5.4), (-3.6, 0.9)], color(0xB18EF2))
    rpoly([(8.2, 0.4), (-3.6, 0.9), (-5.4, -2.2)], color(0x9468E8))
    rpoly([(-3.6, 0.9), (-4.4, -4.6), (-5.4, -2.2)], color(0x5B32AF))
    c.restoreGState()
}

// ============================== ANTIGRAVITY ==============================
// A weightless astronaut drifting up and down with twinkling stars.
func antigravityFrame(_ f: Int, _ c: CGContext) {
    let n = 14
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi
    let dy = sin(t) * 1.9
    let rot = sin(t + .pi / 3) * 8 * .pi / 180

    // stars: 4-point sparkles blinking on offsets
    let stars: [(CGFloat, CGFloat, Int, CGFloat)] = [(5.5, 15, 0, 0.9), (23, 12.5, 5, 0.7),
                                                     (7, 4.5, 9, 0.6), (21.5, 4, 12, 0.8)]
    for (sx, sy, ph, s) in stars {
        let k = (f + ph) % n
        guard k < n / 2 else { continue }
        let a = 0.35 + 0.6 * sin(CGFloat(k) / CGFloat(n / 2) * .pi)
        let white = color(0xEAF2FF, a)
        rect(c, sx - s * 0.15, sy - s, s * 0.3, s * 2, white)
        rect(c, sx - s, sy - s * 0.15, s * 2, s * 0.3, white)
    }

    c.saveGState()
    c.translateBy(x: 14 * P, y: (9.6 + dy) * P)
    c.rotate(by: rot)
    func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat, _ col: CGColor) {
        let path = CGPath(roundedRect: CGRect(x: x * P, y: y * P, width: w * P, height: h * P),
                          cornerWidth: r * P, cornerHeight: r * P, transform: nil)
        c.setFillColor(col); c.addPath(path); c.fillPath()
    }
    func cc(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ col: CGColor) {
        c.setFillColor(col)
        c.fillEllipse(in: CGRect(x: (cx - r) * P, y: (cy - r) * P, width: r * 2 * P, height: r * 2 * P))
    }
    let suit = color(0x74A7F8)
    let suitDeep = color(0x4285F4)
    let kick = sin(t + .pi / 2) * 0.5

    // backpack
    rr(-5.3, -2.2, 1.8, 4.6, 0.6, suitDeep)
    // legs drift opposite each other
    rr(-1.8, -6.4 - kick, 1.9, 3.2, 0.8, suit)
    rr(0.6, -6.4 + kick, 1.9, 3.2, 0.8, suit)
    // torso
    rr(-3.4, -4.2, 6.8, 5.6, 1.6, suit)
    rr(-2.2, -3.4, 4.4, 1.4, 0.6, suitDeep)   // belt detail
    // arms float out
    rr(-5.6, -0.6 + kick * 0.6, 2.4, 1.7, 0.8, suit)
    rr(3.2, -0.6 - kick * 0.6, 2.4, 1.7, 0.8, suit)
    // helmet + visor + glint
    cc(0, 3.4, 4.3, color(0xF2F6FE))
    rr(-2.6, 2.0, 5.2, 3.0, 1.4, color(0x0B2A5E))
    cc(1.4, 4.1, 0.55, color(0xDCE9FF, 0.95))
    c.restoreGState()
}

// ============================== OUTPUT ==============================
struct Mascot {
    let id: String
    let frames: Int
    let delay: Double
    let draw: (Int, CGContext) -> Void
}
let mascots = [
    Mascot(id: "codex", frames: 10, delay: 0.09, draw: codexFrame),
    Mascot(id: "copilot", frames: 10, delay: 0.09, draw: copilotFrame),
    Mascot(id: "antigravity", frames: 14, delay: 0.10, draw: antigravityFrame),
]

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}

func writeGIF(_ imgs: [CGImage], _ path: String, delay: Double) {
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                               UTType.gif.identifier as CFString, imgs.count, nil)!
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
        [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for img in imgs {
        CGImageDestinationAddImage(dest, img, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFUnclampedDelayTime: delay,
             kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    CGImageDestinationFinalize(dest)
}

func composite(_ frame: CGImage, bg: CGColor, w: Int, h: Int,
               spriteH: CGFloat, yOffset: CGFloat = 0) -> CGImage {
    let c = makeCtx(w, h)
    c.setFillColor(bg)
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let scale = spriteH / CGFloat(H)
    let sw = CGFloat(W) * scale, sh = CGFloat(H) * scale
    c.interpolationQuality = .high
    c.draw(frame, in: CGRect(x: (CGFloat(w) - sw) / 2, y: (CGFloat(h) - sh) / 2 + yOffset,
                             width: sw, height: sh))
    return c.makeImage()!
}

let darkBar = color(0x23252B)
let lightBar = color(0xE9E4DC)

var sheetFrames: [(String, [CGImage])] = []
for m in mascots {
    let dir = "\(outDir)/frames/\(m.id)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var raw: [CGImage] = []
    for f in 0..<m.frames {
        let c = makeCtx()
        m.draw(f, c)
        let img = c.makeImage()!
        raw.append(img)
        writePNG(img, "\(dir)/f\(String(format: "%02d", f)).png")
    }
    sheetFrames.append((m.id, raw))
    // big previews
    writeGIF(raw.map { composite($0, bg: darkBar, w: 300, h: 220, spriteH: 200) },
             "\(outDir)/\(m.id)_dark.gif", delay: m.delay)
    writeGIF(raw.map { composite($0, bg: lightBar, w: 300, h: 220, spriteH: 200) },
             "\(outDir)/\(m.id)_light.gif", delay: m.delay)
    // actual-size bar mock (17pt sprite @2x = 34px, bar 48px tall @2x)
    writeGIF(raw.map { composite($0, bg: darkBar, w: 140, h: 48, spriteH: 40) },
             "\(outDir)/\(m.id)_bar.gif", delay: m.delay)
}

// contact sheet for review: all frames, dark bg
let cols = mascots.map { $0.frames }.max()!
let cell = 150
let sheet = makeCtx(cols * cell, mascots.count * cell)
sheet.setFillColor(darkBar)
sheet.fill(CGRect(x: 0, y: 0, width: cols * cell, height: mascots.count * cell))
for (row, entry) in sheetFrames.enumerated() {
    for (i, img) in entry.1.enumerated() {
        let y = (mascots.count - 1 - row) * cell
        sheet.interpolationQuality = .high
        sheet.draw(img, in: CGRect(x: i * cell + 5, y: y + 20, width: cell - 10,
                                   height: Int(Double(cell - 10) * 200.0 / 280.0)))
    }
}
writePNG(sheet.makeImage()!, "\(outDir)/sheet.png")
print("done: \(outDir)")

// ---- System-mode preview: replicate IconRenderer.adaptiveTemplate, tint per bar ----
func templated(_ src: CGImage, ink: (CGFloat, CGFloat, CGFloat)) -> CGImage {
    let pw = src.width, ph = src.height
    let c = makeCtx(pw, ph)
    c.draw(src, in: CGRect(x: 0, y: 0, width: pw, height: ph))
    let px = c.data!.bindMemory(to: UInt8.self, capacity: pw * ph * 4)
    let darkCut = 0.30, bodyLevel = 0.54, gamma = 1.3
    for i in 0..<(pw * ph) {
        let off = i * 4
        let rawA = px[off + 3]
        guard rawA > 0 else { continue }
        let af = Double(rawA) / 255
        let r = Double(px[off]) / (255 * af), g = Double(px[off + 1]) / (255 * af)
        let b = Double(px[off + 2]) / (255 * af)
        let lum = 0.299 * r + 0.587 * g + 0.114 * b
        var a = 0.0
        if lum >= darkCut {
            let t = min(1, (lum - darkCut) / (bodyLevel - darkCut))
            a = Double(rawA) * pow(t, gamma)
        }
        px[off] = UInt8(ink.0 * 255 * CGFloat(a / 255))
        px[off + 1] = UInt8(ink.1 * 255 * CGFloat(a / 255))
        px[off + 2] = UInt8(ink.2 * 255 * CGFloat(a / 255))
        px[off + 3] = UInt8(a)
    }
    return c.makeImage()!
}

for (id, raw) in sheetFrames {
    let m = mascots.first { $0.id == id }!
    writeGIF(raw.map { composite(templated($0, ink: (1, 1, 1)), bg: darkBar,
                                 w: 300, h: 220, spriteH: 200) },
             "\(outDir)/\(id)_tmpl_dark.gif", delay: m.delay)
    writeGIF(raw.map { composite(templated($0, ink: (0.1, 0.1, 0.1)), bg: lightBar,
                                 w: 300, h: 220, spriteH: 200) },
             "\(outDir)/\(id)_tmpl_light.gif", delay: m.delay)
}
print("templates done")

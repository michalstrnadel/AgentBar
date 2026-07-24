// v2 mascots: official-identity animations.
//  - antigravity: faithful pixel-art rainbow arch (traced from the real logo) with a
//    traveling hue/brightness wave — the logo's own animated character.
//  - codex: OpenAI knot (existing tinted mark) + a dot-matrix shimmer that spells
//    "codex" in braille, echoing the Codex CLI thinking indicator.
// Usage: swift mascots2.swift <outDir> <LogoAssets.swift path>
import AppKit
import UniformTypeIdentifiers

let P: CGFloat = 5
let outDir = CommandLine.arguments[1]
let logoAssetsPath = CommandLine.arguments[2]
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func makeCtx(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

// ============================ ANTIGRAVITY ============================
// Grid traced from the official pixel arch (top row first, nil = transparent).
let arch: [[UInt32?]] = [
    [nil, nil, nil, nil, nil, 0xE69B4D, 0xE2804D, nil, nil, nil, nil, nil, nil],
    [nil, nil, nil, nil, 0xD7B753, 0xE99B4D, 0xE4814E, 0xE0694E, nil, nil, nil, nil, nil],
    [nil, nil, nil, 0xAAC560, 0xB8B859, 0xD9A156, 0xE7864E, 0xE7794D, 0xDF6653, nil, nil, nil, nil],
    [nil, nil, nil, 0x99C765, 0x88B66F, 0xC69C60, 0xE1855A, 0xD37460, 0xD26064, nil, nil, nil, nil],
    [nil, nil, 0x91C367, 0x8AC36F, 0x75AB95, 0x6F95B4, 0x867BB0, 0x7A76C0, 0x9668A8, 0x986699, nil, nil, nil],
    [nil, nil, 0x95C76A, 0x75B98B, 0x5F9ADA, nil, nil, 0x5E83DE, 0x7775CA, 0x8E6DB3, nil, nil, nil],
    [nil, nil, 0x80C489, 0x68B0AE, nil, nil, nil, nil, 0x5F85E4, 0x747AD4, nil, nil, nil],
    [nil, 0x88C79D, 0x7DBBD4, 0x68AAD9, nil, nil, nil, nil, 0x598DF3, 0x5F86EA, 0x707EDB, nil, nil],
    [nil, 0x87C8A9, 0x7EB7F1, nil, nil, nil, nil, nil, nil, 0x558AF3, 0x5E86ED, nil, nil],
    [0x80BAF0, 0x7EB7F1, nil, nil, nil, nil, nil, nil, nil, nil, 0x5487F1, 0x5789F4, nil],
]
let archCols = 13, archRows = 10

func shifted(_ hex: UInt32, hue dh: CGFloat, brightness db: CGFloat) -> CGColor {
    let c = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        .usingColorSpace(.sRGB)!
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
    let out = NSColor(hue: (h + dh).truncatingRemainder(dividingBy: 1) < 0
                        ? (h + dh + 1).truncatingRemainder(dividingBy: 1)
                        : (h + dh).truncatingRemainder(dividingBy: 1),
                      saturation: s, brightness: max(0, min(1, b + db)), alpha: 1)
    return out.cgColor
}

let AGW = 26, AGH = 18   // units
func antigravityFrame(_ f: Int, _ n: Int) -> CGImage {
    let c = makeCtx(AGW * Int(P), AGH * Int(P))
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi
    let cellU: CGFloat = 1.55
    let x0 = (CGFloat(AGW) - CGFloat(archCols) * cellU) / 2
    let y0 = (CGFloat(AGH) - CGFloat(archRows) * cellU) / 2
    for (ry, row) in arch.enumerated() {
        for (cx, cell) in row.enumerated() {
            guard let hex = cell else { continue }
            // wave travels along the arch left→right
            let phase = CGFloat(cx) * 0.55 - t * 2
            let dh = 0.045 * sin(phase)
            let db = 0.10 * sin(phase + .pi / 3)
            c.setFillColor(shifted(hex, hue: dh, brightness: db))
            let y = y0 + CGFloat(archRows - 1 - ry) * cellU
            c.fill(CGRect(x: (x0 + CGFloat(cx) * cellU) * P, y: y * P,
                          width: cellU * P + 0.5, height: cellU * P + 0.5))
        }
    }
    return c.makeImage()!
}

// ============================== CODEX ==============================
// Load the knot from the app's LogoAssets.swift and tint it brand teal.
let assets = try! String(contentsOfFile: logoAssetsPath, encoding: .utf8)
func extractB64(_ name: String) -> String {
    let marker = "let \(name) = \""
    let start = assets.range(of: marker)!.upperBound
    let end = assets.range(of: "\"", range: start..<assets.endIndex)!.lowerBound
    return String(assets[start..<end])
}
let knotRaw = NSImage(data: Data(base64Encoded: extractB64("codexLogoPNG"))!)!

func tinted(_ src: NSImage, _ col: NSColor) -> NSImage {
    let out = NSImage(size: src.size)
    out.lockFocus()
    src.draw(in: NSRect(origin: .zero, size: src.size))
    col.set()
    NSRect(origin: .zero, size: src.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}
let knot = tinted(knotRaw, NSColor(srgbRed: 0.078, green: 0.702, blue: 0.580, alpha: 1)) // #14B394

// Even 10x3 dot-matrix with a diagonal activity wave sweeping left→right —
// a regular "processing" shimmer (the braille word looked top-heavy in the bar).
let dotCols = 10, dotRows = 3

let CXW = 42, CXH = 20
func codexFrame(_ f: Int, _ n: Int) -> CGImage {
    let c = makeCtx(CXW * Int(P), CXH * Int(P))
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi

    // knot at left, vertically centered, gentle pulse of scale
    let knotU: CGFloat = 13
    let pulse = 1 + 0.02 * sin(t)
    let kw = knotU * pulse, kx = 1 + (knotU - kw) / 2, ky = (CGFloat(CXH) - kw) / 2
    NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
    c.interpolationQuality = .high
    knot.draw(in: NSRect(x: kx * P, y: ky * P, width: kw * P, height: kw * P))
    NSGraphicsContext.current = nil

    let pitch: CGFloat = 2.3
    let x0 = knotU + 4.2
    let y0 = (CGFloat(CXH) - CGFloat(dotRows - 1) * pitch) / 2
    for colI in 0..<dotCols {
        for rowI in 0..<dotRows {
            let cx = x0 + CGFloat(colI) * pitch
            let cy = y0 + CGFloat(rowI) * pitch
            let phase = CGFloat(colI) * 0.6 + CGFloat(rowI) * 0.25 - t * 2
            let w = max(0, sin(phase))
            let r: CGFloat = 0.55 + 0.23 * w
            c.setFillColor(color(0x14B394, 0.22 + 0.78 * w))
            c.fillEllipse(in: CGRect(x: (cx - r) * P, y: (cy - r) * P,
                                     width: r * 2 * P, height: r * 2 * P))
        }
    }
    return c.makeImage()!
}

// ============================== OUTPUT ==============================
func writePNG(_ img: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
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
func composite(_ frame: CGImage, bg: CGColor, w: Int, h: Int, spriteH: CGFloat) -> CGImage {
    let c = makeCtx(w, h)
    c.setFillColor(bg)
    c.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let scale = spriteH / CGFloat(frame.height)
    let sw = CGFloat(frame.width) * scale, sh = CGFloat(frame.height) * scale
    c.interpolationQuality = .high
    c.draw(frame, in: CGRect(x: (CGFloat(w) - sw) / 2, y: (CGFloat(h) - sh) / 2,
                             width: sw, height: sh))
    return c.makeImage()!
}
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

let darkBar = color(0x23252B), lightBar = color(0xE9E4DC)

struct Out { let id: String; let frames: [CGImage]; let delay: Double }
let outs = [
    Out(id: "antigravity2", frames: (0..<16).map { antigravityFrame($0, 16) }, delay: 0.09),
    Out(id: "codex2", frames: (0..<14).map { codexFrame($0, 14) }, delay: 0.09),
]
for o in outs {
    let dir = "\(outDir)/frames/\(o.id)"
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (i, img) in o.frames.enumerated() {
        writePNG(img, "\(dir)/f\(String(format: "%02d", i)).png")
    }
    let w = o.frames[0].width * 220 / o.frames[0].height
    writeGIF(o.frames.map { composite($0, bg: darkBar, w: w, h: 220, spriteH: 200) },
             "\(outDir)/\(o.id)_dark.gif", delay: o.delay)
    writeGIF(o.frames.map { composite($0, bg: lightBar, w: w, h: 220, spriteH: 200) },
             "\(outDir)/\(o.id)_light.gif", delay: o.delay)
    writeGIF(o.frames.map { composite(templated($0, ink: (1, 1, 1)), bg: darkBar, w: w, h: 220, spriteH: 200) },
             "\(outDir)/\(o.id)_tmpl_dark.gif", delay: o.delay)
    writeGIF(o.frames.map { composite(templated($0, ink: (0.1, 0.1, 0.1)), bg: lightBar, w: w, h: 220, spriteH: 200) },
             "\(outDir)/\(o.id)_tmpl_light.gif", delay: o.delay)
    let bw = o.frames[0].width * 40 / o.frames[0].height + 60
    writeGIF(o.frames.map { composite($0, bg: darkBar, w: bw, h: 48, spriteH: 40) },
             "\(outDir)/\(o.id)_bar.gif", delay: o.delay)
}
print("done v2")

let copilotHead: [[UInt32?]] = [
    [nil, nil, nil, nil, nil, nil, nil, nil, nil, 0xCA9FF0, 0xD09AF9, 0xD099F9, 0xCF9AF9, 0xCF9AF9, 0xCF9AF9, 0xCF9BF7, nil, nil, nil, nil, nil, nil, nil, nil, nil, nil],
    [nil, nil, nil, nil, nil, 0x0D1D33, 0x0D1D33, 0x0C1D35, 0xB9A4F9, 0xBBA3F9, 0xB9A4F9, 0xBBA3F9, 0xC79DF9, 0xB9A4F9, 0xB9A4F9, 0xB9A4F9, 0xB9A4F9, 0x0B1D36, 0x0B1D36, 0x0B1E36, nil, nil, nil, nil, nil, nil],
    [nil, nil, nil, nil, 0x7FB4F6, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0xAB9CF9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7CB4F9, 0x7FB3F7, nil, nil, nil, nil, nil],
    [nil, nil, nil, nil, 0x77ADF9, 0x77ADF7, 0x0E1216, 0x0F1014, 0x0E1015, 0x0E1015, 0x5794ED, 0x78AEF9, 0x5D98EB, 0x77ADF9, 0x77ACF9, 0x0E1114, 0x0E1113, 0x0E1114, 0x0E1113, 0x08112B, 0x78AEF9, 0x78AEF9, nil, nil, nil, nil],
    [nil, nil, nil, 0x5591E7, 0x71A2F8, 0x090D22, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x051530, 0x71A2F8, 0x6198F4, 0x71A2F8, 0x0D1117, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0B101C, 0x2353CB, 0x71A2F8, nil, nil, nil, nil],
    [nil, nil, nil, 0x5692E9, 0x71A1F8, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x72A2F8, 0x6299F7, 0x72A3F8, 0x0D1117, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x224FDD, 0x72A1F8, nil, nil, nil, nil],
    [nil, nil, nil, 0x5894ED, 0x6C9AF7, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x6C9AF8, 0x4174E2, 0x6C9AF7, 0x0D1216, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x2251DC, 0x6C9AF6, nil, nil, nil, nil],
    [nil, nil, nil, 0x5B98F6, 0x658CF6, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x668CF6, 0x658CF6, 0x234FD5, 0x658DF5, 0x668CF6, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x08102E, 0x628CF4, 0x658CF6, nil, nil, nil, nil],
    [nil, nil, 0x7D6BCF, 0x7C68DA, 0x3E75EB, 0x4074EF, 0x4272F5, 0x4272F5, 0x4271F6, 0x4272F5, 0x4272F6, 0x214EDE, 0x05175B, 0x4170F6, 0x4272F6, 0x4272F6, 0x4272F6, 0x4272F6, 0x4272F6, 0x4272F5, 0x4272F5, 0x9B7CF7, 0x9A7EF6, nil, nil, nil],
    [0x7E73C2, 0x7C6EC8, 0x7766DB, 0x8A75EE, 0x3D75ED, 0x4074EF, 0x4272F6, 0x4272F6, 0x4272F6, 0x4272F6, 0x4272F6, 0x214FDE, 0x05143D, 0x4072F6, 0x4271F6, 0x4271F6, 0x4271F6, 0x4271F6, 0x4271F6, 0x4271F6, 0x4272F6, 0x9275F6, 0x9077F3, 0x8172D3, 0x7E70C2, nil],
    [0x8C76F7, 0x8C76F7, 0x7466DD, 0x8C76F7, 0x0D1115, 0x0D1017, 0x0D1017, 0x0D1017, 0x0D1017, 0x0D1017, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1114, 0x8C76F6, 0x8C76F7, 0x8C76F7, 0x8C76F7, nil],
    [0x7F6FF7, 0x7F6FF7, 0x6F64DD, 0x7F6FF7, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x122218, 0xADECB6, 0x0D1115, 0x0D1115, 0x0D1115, 0xAEE6BD, 0x14271B, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x7F70F6, 0x7F6FF7, 0x7F6FF7, 0x7F6FF7, 0x7F6FF7],
    [0x7F6FF7, 0x7F6FF7, 0x6963D9, 0x806EF7, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0xABECB4, 0xA6F1AE, 0x0D1115, 0x0D1115, 0x0D1115, 0xA6F1AE, 0xA7F0AE, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x7F70F6, 0x7F6FF7, 0x7F6FF7, 0x7F6FF7, 0x7F6FF7],
    [0x615CD5, 0x615CD5, 0x615BD3, 0x706CF7, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0xABECB6, 0xA6F1AE, 0x0D1115, 0x0D1115, 0x0D1115, 0xA6F0AF, 0xA7F0AE, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x6F6BF7, 0x605BD8, 0x6E6AF5, 0x6E6AF5, 0x6E6AF5],
    [0x605CD6, 0x605CD6, 0x605CD6, 0x6E6AF6, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0xABECB4, 0xA6F1AE, 0x0D1115, 0x0D1115, 0x0D1115, 0xA6F1AE, 0xA7F0AC, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x6E6BF5, 0x605CD8, 0x6D6BF6, 0x6D6BF6, 0x6D6BF6],
    [0x3E4CB6, 0x3E4CB6, 0x3E4CB6, 0x4E64F6, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x4E64F4, 0x3E4CB6, 0x3E4CB6, 0x3E4CB6, nil],
    [nil, nil, 0x203A93, 0x3D61F6, 0x3E61F6, 0x0F1119, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0D1115, 0x0E1117, 0x3D5FED, 0x3E61F6, 0x1E3B99, 0x0D1C45, nil, nil],
    [nil, nil, 0x233B8C, 0x4260E8, 0x3D61F1, 0x335DF5, 0x3260F4, 0x3260F4, 0x3260F4, 0x3260F4, 0x3260F5, 0x3260F5, 0x325FF4, 0x3260F4, 0x3260F4, 0x3260F5, 0x3260F5, 0x325FF4, 0x3260F4, 0x335EF2, 0x325EF6, 0x4163E9, 0x213B90, 0x0F193E, nil, nil],
    [nil, nil, nil, nil, 0x1E3B99, 0x325FF5, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, 0x315EF6, nil, nil, nil, nil, nil],
    [nil, nil, nil, nil, nil, nil, nil, nil, nil, 0x0A1634, 0x0A1634, 0x0A1634, 0x0A1632, 0x0A1634, 0x0A1634, 0x0A1634, 0x0F1221, nil, nil, nil, nil, nil, nil, nil, nil, nil],
]

// Copilot pixel head: faithful grid from the official pixel-art mascot.
// Animation: weightless bob + goggle glint sweep + breathing vents.
import AppKit
import UniformTypeIdentifiers

let P: CGFloat = 5
let outDir = "final"
let srgb2 = CGColorSpace(name: CGColorSpace.sRGB)!
func makeCtx(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb2, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func col(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func lum(_ hex: UInt32) -> Double {
    (0.299 * Double((hex >> 16) & 0xFF) + 0.587 * Double((hex >> 8) & 0xFF)
     + 0.114 * Double(hex & 0xFF)) / 255
}
func lighten(_ hex: UInt32, _ f: CGFloat) -> CGColor {
    let r = min(255, CGFloat((hex >> 16) & 0xFF) + 255 * f)
    let g = min(255, CGFloat((hex >> 8) & 0xFF) + 255 * f)
    let b = min(255, CGFloat(hex & 0xFF) + 255 * f)
    return CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: 1)
}

let rows = copilotHead.count, cols = copilotHead[0].count
// braille copilot: c=1,4 o=1,3,5 p=1,2,3,4 i=2,4 l=1,2,3 o=1,3,5 t=2,3,4,5
let brailleWord: [[Int]] = [[1,4], [1,3,5], [1,2,3,4], [2,4], [1,2,3], [1,3,5], [2,3,4,5]]
let CW = 64, CH = 23
func headFrame(_ f: Int, _ n: Int) -> CGImage {
    let c = makeCtx(CW * Int(P), CH * Int(P))
    let t = CGFloat(f) / CGFloat(n) * 2 * .pi
    let cellU: CGFloat = 0.92
    let bob = sin(t) * 0.9
    let x0: CGFloat = 1
    let y0 = (CGFloat(CH) - CGFloat(rows) * cellU) / 2 + bob
    // glint sweep position in grid columns, one pass per loop with a pause
    let sweep = (CGFloat(f) / CGFloat(n)) * CGFloat(cols + 16) - 6
    for (ry, row) in copilotHead.enumerated() {
        for (cx, cell) in row.enumerated() {
            guard let hex = cell else { continue }
            let l = lum(hex)
            var fill = col(hex)
            if l < 0.16 {                      // goggle lenses & dark details
                let d = abs(CGFloat(cx) - CGFloat(ry) * 0.35 - sweep)
                if d < 1.6, ry < 9 { fill = lighten(0x1B3C74, (1.6 - d) * 0.16) }
            } else if hex >> 16 >= 0xA0, (hex >> 8) & 0xFF >= 0xE0 {  // green vents
                fill = lighten(hex, 0.06 * sin(t * 2))
            }
            c.setFillColor(fill)
            let y = y0 + CGFloat(rows - 1 - ry) * cellU
            c.fill(CGRect(x: (x0 + CGFloat(cx) * cellU) * P, y: y * P,
                          width: cellU * P + 0.5, height: cellU * P + 0.5))
        }
    }
    // dot-matrix "copilot" in brand purple, shimmer wave like the Codex mark
    let pitch: CGFloat = 1.9, gap: CGFloat = 1.4
    var dx = x0 + CGFloat(cols) * cellU + 2.6
    let rowsY: [CGFloat] = [3, 2, 1].map { (CGFloat(CH) - 3 * pitch) / 2 + (CGFloat($0) - 0.5) * pitch }
    for (ci, dots) in brailleWord.enumerated() {
        for slot in 1...6 {
            let colI = slot <= 3 ? 0 : 1
            let rowI = (slot - 1) % 3
            let cx = dx + CGFloat(colI) * pitch
            let cy = rowsY[rowI]
            let active = dots.contains(slot)
            let phase = (CGFloat(ci) * 2 + CGFloat(colI)) * 0.5 - t * 2
            let r: CGFloat = active ? 0.68 : 0.44
            let fill: CGColor
            if active {
                let a = 0.45 + 0.55 * max(0, sin(phase))
                fill = col(0x9A6FF0, 0.35 + 0.65 * a)
            } else {
                fill = col(0x8B939C, 0.16)
            }
            c.setFillColor(fill)
            c.fillEllipse(in: CGRect(x: (cx - r) * P, y: (cy - r) * P,
                                     width: r * 2 * P, height: r * 2 * P))
        }
        dx += pitch + gap + pitch
    }
    return c.makeImage()!
}

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
        let l = 0.299 * r + 0.587 * g + 0.114 * b
        var a = 0.0
        if l >= darkCut {
            let tt = min(1, (l - darkCut) / (bodyLevel - darkCut))
            a = Double(rawA) * pow(tt, gamma)
        }
        px[off] = UInt8(ink.0 * 255 * CGFloat(a / 255))
        px[off + 1] = UInt8(ink.1 * 255 * CGFloat(a / 255))
        px[off + 2] = UInt8(ink.2 * 255 * CGFloat(a / 255))
        px[off + 3] = UInt8(a)
    }
    return c.makeImage()!
}

let darkBar = col(0x23252B), lightBar = col(0xE9E4DC)
let n = 16
let frames = (0..<n).map { headFrame($0, n) }
let dir = "\(outDir)/frames/copilot2"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for (i, img) in frames.enumerated() {
    writePNG(img, "\(dir)/f\(String(format: "%02d", i)).png")
}
let w = frames[0].width * 220 / frames[0].height
writeGIF(frames.map { composite($0, bg: darkBar, w: w, h: 220, spriteH: 200) },
         "\(outDir)/copilot2_dark.gif", delay: 0.09)
writeGIF(frames.map { composite($0, bg: lightBar, w: w, h: 220, spriteH: 200) },
         "\(outDir)/copilot2_light.gif", delay: 0.09)
writeGIF(frames.map { composite(templated($0, ink: (1,1,1)), bg: darkBar, w: w, h: 220, spriteH: 200) },
         "\(outDir)/copilot2_tmpl_dark.gif", delay: 0.09)
writeGIF(frames.map { composite(templated($0, ink: (0.1,0.1,0.1)), bg: lightBar, w: w, h: 220, spriteH: 200) },
         "\(outDir)/copilot2_tmpl_light.gif", delay: 0.09)
writeGIF(frames.map { composite($0, bg: darkBar, w: 140, h: 48, spriteH: 40) },
         "\(outDir)/copilot2_bar.gif", delay: 0.09)
print("copilot head done")

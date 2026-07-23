// Brand marks for Cursor and Gemini menu icons. Solid alpha shapes (tinted at runtime
// by IconRenderer via .tintedMark). Gemini = its four-point spark; Cursor = a pointer.
import AppKit
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
func ctx(_ n: Int) -> CGContext {
    CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func writePNG(_ img: CGImage, _ path: String) {
    try! NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: path))
}
let N = 256, ink = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)

// ---- Gemini: four-point spark (concave star), the real mark shape ----
do {
    let c = ctx(N); let cx = Double(N)/2, cy = Double(N)/2, R = Double(N)*0.46, r = Double(N)*0.06
    let p = CGMutablePath()
    // 8 vertices: outer points at N/E/S/W, inner control near center → concave curves
    let pts: [(Double, Double)] = [(cx, cy+R), (cx+r, cy+r), (cx+R, cy), (cx+r, cy-r),
                                   (cx, cy-R), (cx-r, cy-r), (cx-R, cy), (cx-r, cy+r)]
    p.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for k in 1..<pts.count {
        let prev = pts[k-1], cur = pts[k]
        // quadratic toward center makes the concave "sparkle" waist
        p.addQuadCurve(to: CGPoint(x: cur.0, y: cur.1),
                       control: CGPoint(x: cx + (prev.0+cur.0)/2 - cx*1, y: cy))
    }
    // simpler & reliable: rebuild as straight concave star
    let p2 = CGMutablePath()
    p2.move(to: CGPoint(x: pts[0].0, y: pts[0].1))
    for k in 1..<pts.count { p2.addLine(to: CGPoint(x: pts[k].0, y: pts[k].1)) }
    p2.closeSubpath()
    c.setFillColor(ink); c.addPath(p2); c.fillPath()
    writePNG(c.makeImage()!, "cursor_gemini_gemini.png")
}

// ---- Cursor: classic pointer arrow ----
do {
    let c = ctx(N)
    let p = CGMutablePath()
    // arrow cursor pointing up-left, centered-ish
    let s = Double(N)
    let pts: [(Double, Double)] = [
        (0.30, 0.90), (0.30, 0.16), (0.82, 0.52), (0.55, 0.55),
        (0.70, 0.82), (0.60, 0.88), (0.45, 0.60), (0.30, 0.90)]
    p.move(to: CGPoint(x: pts[0].0*s, y: pts[0].1*s))
    for k in 1..<pts.count { p.addLine(to: CGPoint(x: pts[k].0*s, y: pts[k].1*s)) }
    p.closeSubpath()
    c.setFillColor(ink); c.addPath(p); c.fillPath()
    writePNG(c.makeImage()!, "cursor_gemini_cursor.png")
}
print("marks written")

// Generates docs/assets/demo-claude-codex.gif: a staged macOS desktop (Sequoia-style
// gradient wallpaper, translucent menu bar, dock) where the crab works -> needs
// approval -> inline Allow -> resumes -> Codex takes over. Mascot frames are read
// straight from the shipped sprite sources, so regenerating after a sprite change
// keeps the GIF in sync.
// Usage (from repo root):
//   swift Scripts/demo/demo-gif.swift \
//     Sources/AgentBar/Sprites/CrabFrames.swift \
//     Sources/AgentBar/Sprites/CodexFrames.swift \
//     docs/assets/app-icon.png docs/assets/demo-claude-codex.gif [framedump-dir]
import AppKit
import UniformTypeIdentifiers

let W: CGFloat = 1200, H: CGFloat = 640
let barH: CGFloat = 48
let crabSrc = CommandLine.arguments[1]
let codexSrc = CommandLine.arguments[2]
let appIconPath = CommandLine.arguments[3]
let outPath = CommandLine.arguments[4]
let dumpDir: String? = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : nil

func loadFrames(_ path: String) -> [NSImage] {
    let src = try! String(contentsOfFile: path, encoding: .utf8)
    var out: [NSImage] = []
    var range = src.startIndex..<src.endIndex
    while let q1 = src.range(of: "\"", range: range) {
        guard let q2 = src.range(of: "\"", range: q1.upperBound..<src.endIndex) else { break }
        let s = String(src[q1.upperBound..<q2.lowerBound])
        if s.count > 200, let d = Data(base64Encoded: s), let img = NSImage(data: d) {
            out.append(img)
        }
        range = q2.upperBound..<src.endIndex
    }
    return out
}
let crab = loadFrames(crabSrc)
let codex = loadFrames(codexSrc)
let appIcon = NSImage(contentsOfFile: appIconPath)
precondition(crab.count >= 10 && codex.count >= 10)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let amber = rgb(0xF2BA2E)
let amberText = rgb(0x9A6B00)
let teal = rgb(0x14B394)
let brand: [NSColor] = [rgb(0xD97757), rgb(0x10A37F), rgb(0x8250DF), rgb(0x4285F4)]
let ink = rgb(0x1D1D1F), sub = rgb(0x7A756E)

func text(_ s: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular,
          mono: Bool = false) -> NSAttributedString {
    let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}

func symbolImage(_ name: String, pt: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight == .semibold ? .semibold : .regular)
    let img = base.withSymbolConfiguration(cfg) ?? base
    let tinted = NSImage(size: img.size)
    tinted.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}

func drawSymbol(_ name: String, midX: CGFloat, midY: CGFloat, pt: CGFloat, color: NSColor) -> CGFloat {
    guard let img = symbolImage(name, pt: pt, color: color) else { return 0 }
    let s = img.size
    img.draw(in: NSRect(x: midX - s.width / 2, y: midY - s.height / 2,
                        width: s.width, height: s.height))
    return s.width
}

// ---------------------------------------------------------------- wallpaper
func drawWallpaper() {
    let grad = NSGradient(colorsAndLocations:
        (rgb(0x6FA8DC), 0.0), (rgb(0x8E9EE0), 0.30),
        (rgb(0xB48BD6), 0.58), (rgb(0xE39BB5), 0.82), (rgb(0xF2BE9A), 1.0))!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)

    // soft light blobs, macOS-wallpaper style
    let blobs: [(CGFloat, CGFloat, CGFloat, NSColor)] = [
        (260, 520, 340, rgb(0xFFFFFF, 0.20)),
        (900, 140, 420, rgb(0xFFD9A0, 0.22)),
        (620, 420, 300, rgb(0xC9A6F2, 0.18)),
    ]
    for (cx, cy, r, c) in blobs {
        let g = NSGradient(colorsAndLocations: (c, 0.0), (c.withAlphaComponent(0), 1.0))!
        g.draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0,
               toCenter: NSPoint(x: cx, y: cy), radius: r, options: [])
    }
}

// ---------------------------------------------------------------- dock
func drawDock() {
    let iconS: CGFloat = 60, gap: CGFloat = 16, pad: CGFloat = 14
    let tiles: [(String, UInt32, UInt32)] = [
        ("safari", 0x39A0F5, 0x1263D6),
        ("message.fill", 0x5CE065, 0x27A845),
        ("envelope.fill", 0x53B9F5, 0x1D6FD6),
        ("music.note", 0xF56AA2, 0xE0356B),
    ]
    let n = CGFloat(tiles.count + 1)
    let dockW = pad * 2 + n * iconS + (n - 1) * gap
    let dock = NSRect(x: (W - dockW) / 2, y: 14, width: dockW, height: iconS + pad * 2)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.set()
    rgb(0xFFFFFF, 0.34).setFill()
    rounded(dock, 24).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    rgb(0xFFFFFF, 0.45).setStroke()
    let border = rounded(dock, 24); border.lineWidth = 1.5; border.stroke()

    var x = dock.minX + pad
    let y = dock.minY + pad
    for (sym, top, bottom) in tiles {
        let tile = NSRect(x: x, y: y, width: iconS, height: iconS)
        NSGraphicsContext.current?.saveGraphicsState()
        let ts = NSShadow()
        ts.shadowBlurRadius = 6
        ts.shadowOffset = NSSize(width: 0, height: -3)
        ts.shadowColor = NSColor.black.withAlphaComponent(0.25)
        ts.set()
        NSGradient(starting: rgb(top), ending: rgb(bottom))!
            .draw(in: rounded(tile, 14), angle: -90)
        NSGraphicsContext.current?.restoreGraphicsState()
        _ = drawSymbol(sym, midX: tile.midX, midY: tile.midY, pt: 30, color: .white)
        x += iconS + gap
    }
    // AgentBar's own app icon closes the dock row; the PNG carries the macOS
    // icon-grid margin, so overscan it to visually match the bare tiles
    if let icon = appIcon {
        let tile = NSRect(x: x, y: y, width: iconS, height: iconS).insetBy(dx: -7, dy: -7)
        NSGraphicsContext.current?.saveGraphicsState()
        let ts = NSShadow()
        ts.shadowBlurRadius = 6
        ts.shadowOffset = NSSize(width: 0, height: -3)
        ts.shadowColor = NSColor.black.withAlphaComponent(0.25)
        ts.set()
        icon.draw(in: tile)
        NSGraphicsContext.current?.restoreGraphicsState()
    }
}

enum Phase { case working, approval, hover, clicked, resumed, codexWork }
func phase(for f: Int) -> Phase {
    switch f {
    case 0..<20:  return .working
    case 20..<38: return .approval
    case 38..<50: return .hover
    case 50..<56: return .clicked
    case 56..<72: return .resumed
    default:      return .codexWork
    }
}
func smooth(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

func renderFrame(_ f: Int) -> CGImage {
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    let p = phase(for: f)
    let pending = (p == .approval || p == .hover || p == .clicked)
    let isCodex = (p == .codexWork)

    drawWallpaper()
    drawDock()

    // ---- Menu bar: translucent light, thin, over the wallpaper ----
    let barY = H - barH
    rgb(0xF4F1EE, 0.72).setFill()
    NSRect(x: 0, y: barY, width: W, height: barH).fill()
    rgb(0x000000, 0.10).setFill()
    NSRect(x: 0, y: barY - 1, width: W, height: 1).fill()

    let barTextY = barY + 10
    // left: Apple logo + app menus
    var lx: CGFloat = 26
    _ = drawSymbol("apple.logo", midX: lx + 10, midY: barY + barH / 2, pt: 22, color: ink)
    lx += 38
    let finder = text("Finder", 25, ink, weight: .bold)
    finder.draw(at: NSPoint(x: lx, y: barTextY)); lx += finder.size().width + 30
    for m in ["File", "Edit", "View", "Go"] {
        let t = text(m, 25, ink)
        t.draw(at: NSPoint(x: lx, y: barTextY))
        lx += t.size().width + 30
    }

    // right: clock, control-center, battery, wi-fi (right to left)
    var rx = W - 24
    let clock = text("Thu 24 Jul   9:41", 25, ink, weight: .medium)
    rx -= clock.size().width
    clock.draw(at: NSPoint(x: rx, y: barTextY))
    rx -= 30
    _ = drawSymbol("switch.2", midX: rx, midY: barY + barH / 2, pt: 20, color: ink)
    rx -= 44
    if symbolImage("battery.75percent", pt: 24, color: ink) != nil {
        _ = drawSymbol("battery.75percent", midX: rx, midY: barY + barH / 2, pt: 24, color: ink)
    } else {
        _ = drawSymbol("battery.75", midX: rx, midY: barY + barH / 2, pt: 24, color: ink)
    }
    rx -= 46
    _ = drawSymbol("wifi", midX: rx, midY: barY + barH / 2, pt: 21, color: ink)
    rx -= 40

    // ---- AgentBar status item (menu open -> highlighted pill) ----
    var itemW: CGFloat
    let mascot: NSImage
    let mh: CGFloat
    let label: NSAttributedString
    if isCodex {
        mascot = codex[f % codex.count]; mh = 34
        label = text("Codex", 24, ink, weight: .medium)
    } else {
        mascot = crab[f % crab.count]; mh = 38
        label = pending ? text("needs approval", 24, amberText, weight: .medium)
                        : text("Crunching…", 24, ink, weight: .medium)
    }
    let mw = mh * mascot.size.width / mascot.size.height
    itemW = 14 + mw + 10 + label.size().width + 16
    let pill = NSRect(x: rx - itemW, y: barY + 3, width: itemW, height: barH - 6)
    rgb(0x000000, 0.14).setFill()
    rounded(pill, 8).fill()
    mascot.draw(in: NSRect(x: pill.minX + 14, y: barY + (barH - mh) / 2 - 1, width: mw, height: mh))
    label.draw(at: NSPoint(x: pill.minX + 14 + mw + 10, y: barTextY))
    if !isCodex && pending {
        amber.setFill()
        NSBezierPath(ovalIn: NSRect(x: pill.minX + 10 + mw, y: barY + barH - 18,
                                    width: 12, height: 12)).fill()
    }

    // ---- Dropdown panel, anchored under the status item ----
    let panelH: CGFloat = pending ? 408 : 298
    let panelW: CGFloat = 600
    let panel = NSRect(x: min(pill.maxX + 6, W - 30) - panelW, y: barY - 8 - panelH,
                       width: panelW, height: panelH)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 26
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
    shadow.set()
    rgb(0xF2F1F3, 0.97).setFill()
    rounded(panel, 14).fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    rgb(0xFFFFFF, 0.5).setStroke()
    let pb = rounded(panel, 14); pb.lineWidth = 1; pb.stroke()

    let px = panel.minX
    var y = panel.maxY - 46
    text("Sessions", 22, rgb(0xA5A09A), weight: .semibold).draw(at: NSPoint(x: px + 28, y: y))
    y -= 52

    var allowRect = NSRect.zero
    if isCodex {
        teal.setFill()
        NSBezierPath(ovalIn: NSRect(x: px + 34, y: y + 8, width: 14, height: 14)).fill()
        text("api · main", 26, ink, weight: .medium).draw(at: NSPoint(x: px + 62, y: y))
        text("  Running command", 22, sub).draw(at: NSPoint(x: px + 230, y: y + 2))
        text("CODEX", 17, rgb(0xB6B1AA), weight: .semibold, mono: true).draw(at: NSPoint(x: px + 496, y: y + 5))
        y -= 46
        rgb(0xC9C4BC).setFill()
        NSBezierPath(ovalIn: NSRect(x: px + 34, y: y + 8, width: 14, height: 14)).fill()
        text("myapp · main", 26, ink, weight: .medium).draw(at: NSPoint(x: px + 62, y: y))
        text("  Done", 22, sub).draw(at: NSPoint(x: px + 250, y: y + 2))
        text("CLAUDE", 17, rgb(0xB6B1AA), weight: .semibold, mono: true).draw(at: NSPoint(x: px + 490, y: y + 5))
        y -= 44
    } else {
        let dotColor: NSColor = pending ? amber : brand[0]
        dotColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: px + 34, y: y + 8, width: 14, height: 14)).fill()
        text("myapp · main", 26, ink, weight: .medium).draw(at: NSPoint(x: px + 62, y: y))
        text(pending ? "  needs approval" : "  Running command", 22, sub)
            .draw(at: NSPoint(x: px + 240, y: y + 2))
        text("CLAUDE", 17, rgb(0xB6B1AA), weight: .semibold, mono: true).draw(at: NSPoint(x: px + 490, y: y + 5))
        y -= 46

        if pending {
            text("Bash: git push origin main", 21, sub, mono: true).draw(at: NSPoint(x: px + 80, y: y))
            y -= 56
            var bx: CGFloat = px + 56
            let labels = [("✓ Allow", true), ("✓ Always", false), ("✕ Deny", false), ("⌨ Terminal", false)]
            for (label, isAllow) in labels {
                let wBtn = CGFloat(28 + label.count * 12)
                let r = NSRect(x: bx, y: y - 4, width: wBtn, height: 40)
                let hovered = isAllow && (p == .hover || p == .clicked)
                (p == .clicked && isAllow ? rgb(0xC9C4BC) : (hovered ? rgb(0xDCD7CF) : NSColor.white)).setFill()
                rounded(r, 9).fill()
                rgb(0x000000, 0.12).setStroke()
                let path = rounded(r, 9); path.lineWidth = 1.5; path.stroke()
                text(label, 19, ink).draw(at: NSPoint(x: bx + 14, y: y + 4))
                if isAllow { allowRect = r }
                bx += wBtn + 10
            }
            y -= 52
        }

        rgb(0xC9C4BC).setFill()
        NSBezierPath(ovalIn: NSRect(x: px + 34, y: y + 8, width: 14, height: 14)).fill()
        text("api · main", 26, ink, weight: .medium).draw(at: NSPoint(x: px + 62, y: y))
        text("CODEX", 17, rgb(0xB6B1AA), weight: .semibold, mono: true).draw(at: NSPoint(x: px + 496, y: y + 5))
        y -= 44
    }

    rgb(0x000000, 0.10).setFill()
    NSRect(x: px + 24, y: y + 16, width: panel.width - 48, height: 1.5).fill()
    text("Open", 26, ink).draw(at: NSPoint(x: px + 34, y: y - 30))
    text("›", 26, sub).draw(at: NSPoint(x: px + 556, y: y - 30))
    y -= 74
    text("Quit", 26, ink).draw(at: NSPoint(x: px + 34, y: y))
    text("⌘Q", 24, sub).draw(at: NSPoint(x: px + 536, y: y))

    // ---- Cursor ----
    if pending || p == .resumed {
        let start = NSPoint(x: min(pill.maxX + 60, W - 40), y: 170)
        let target = allowRect == .zero ? NSPoint(x: panel.midX, y: panel.midY)
                                        : NSPoint(x: allowRect.midX, y: allowRect.midY - 6)
        var pos = target
        if p == .approval {
            let t = smooth(CGFloat(f - 20) / 18)
            pos = NSPoint(x: start.x + (target.x - start.x) * t,
                          y: start.y + (target.y - start.y) * t)
        } else if p == .resumed {
            let t = smooth(min(1, CGFloat(f - 56) / 14))
            pos = NSPoint(x: target.x + (start.x - target.x) * t,
                          y: target.y + (start.y - target.y) * t)
        }
        let cur = NSBezierPath()
        cur.move(to: pos)
        cur.line(to: NSPoint(x: pos.x, y: pos.y - 30))
        cur.line(to: NSPoint(x: pos.x + 7, y: pos.y - 22))
        cur.line(to: NSPoint(x: pos.x + 13, y: pos.y - 34))
        cur.line(to: NSPoint(x: pos.x + 18, y: pos.y - 31))
        cur.line(to: NSPoint(x: pos.x + 12, y: pos.y - 20))
        cur.line(to: NSPoint(x: pos.x + 21, y: pos.y - 20))
        cur.close()
        NSColor.white.setStroke()
        cur.lineWidth = 3
        cur.stroke()
        NSColor.black.setFill()
        cur.fill()
    }

    img.unlockFocus()
    var rect = NSRect(x: 0, y: 0, width: W, height: H)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

let frames = 116
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [
    kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in 0..<frames {
    let cg = renderFrame(f)
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFUnclampedDelayTime: 0.085,
        kCGImagePropertyGIFDelayTime: 0.085]] as CFDictionary)
    if let dir = dumpDir, [10, 30, 45, 60, 90].contains(f) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(dir)/frame-\(f).png"))
    }
}
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")

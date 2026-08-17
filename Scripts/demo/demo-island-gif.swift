// Generates docs/assets/demo-island.gif: the same staged desktop as the menu-bar
// demo, but in Dynamic Island mode — the pill under the notch says approve?, the
// panel inflates out of the notch on hover (hero row, permission card, mini-diff),
// one click on Allow, and the pill flashes ✓ Allowed on the way out. Mascot frames
// are read straight from the shipped sprite sources, so regenerating after a sprite
// change keeps the GIF in sync.
// Usage (from repo root):
//   swift Scripts/demo/demo-island-gif.swift \
//     Sources/AgentBar/Sprites/CrabFrames.swift \
//     docs/assets/app-icon.png docs/assets/demo-island.gif [framedump-dir]
import AppKit
import UniformTypeIdentifiers

let W: CGFloat = 1200, H: CGFloat = 640
let barH: CGFloat = 48
let crabSrc = CommandLine.arguments[1]
let appIconPath = CommandLine.arguments[2]
let outPath = CommandLine.arguments[3]
let dumpDir: String? = CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil

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
let appIcon = NSImage(contentsOfFile: appIconPath)
precondition(crab.count >= 10)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let amber = rgb(0xF2BA2E)
let green = rgb(0x59D973)
let blue = rgb(0x73B8FF)
let claudeBrand = rgb(0xE08B6D)
let codexBrand = rgb(0x2EC9A7)
let ink = rgb(0x1D1D1F)

func text(_ s: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular,
          mono: Bool = false) -> NSAttributedString {
    let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                 : NSFont.systemFont(ofSize: size, weight: weight)
    return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
}
func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
}
/// Rounded below, square above — the island shape, flush with the notch.
func flushTop(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: r.minX, y: r.maxY))
    p.line(to: NSPoint(x: r.minX, y: r.minY + radius))
    p.appendArc(withCenter: NSPoint(x: r.minX + radius, y: r.minY + radius), radius: radius,
                startAngle: 180, endAngle: 270, clockwise: false)
    p.line(to: NSPoint(x: r.maxX - radius, y: r.minY))
    p.appendArc(withCenter: NSPoint(x: r.maxX - radius, y: r.minY + radius), radius: radius,
                startAngle: 270, endAngle: 0, clockwise: false)
    p.line(to: NSPoint(x: r.maxX, y: r.maxY))
    p.close()
    return p
}

func symbolImage(_ name: String, pt: CGFloat, color: NSColor) -> NSImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: .regular)
    let img = base.withSymbolConfiguration(cfg) ?? base
    let tinted = NSImage(size: img.size)
    tinted.lockFocus()
    img.draw(in: NSRect(origin: .zero, size: img.size))
    color.set()
    NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    return tinted
}
func drawSymbol(_ name: String, midX: CGFloat, midY: CGFloat, pt: CGFloat, color: NSColor) {
    guard let img = symbolImage(name, pt: pt, color: color) else { return }
    let s = img.size
    img.draw(in: NSRect(x: midX - s.width / 2, y: midY - s.height / 2,
                        width: s.width, height: s.height))
}

func drawWallpaper() {
    let grad = NSGradient(colorsAndLocations:
        (rgb(0x6FA8DC), 0.0), (rgb(0x8E9EE0), 0.30),
        (rgb(0xB48BD6), 0.58), (rgb(0xE39BB5), 0.82), (rgb(0xF2BE9A), 1.0))!
    grad.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)
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
        NSGradient(starting: rgb(top), ending: rgb(bottom))!
            .draw(in: rounded(tile, 14), angle: -90)
        drawSymbol(sym, midX: tile.midX, midY: tile.midY, pt: 30, color: .white)
        x += iconS + gap
    }
    if let icon = appIcon {
        icon.draw(in: NSRect(x: x, y: y, width: iconS, height: iconS).insetBy(dx: -7, dy: -7))
    }
}

// The bar carries no AgentBar status item on purpose: this is Island mode.
func drawMenuBarWithNotch() {
    let barY = H - barH
    rgb(0xF4F1EE, 0.72).setFill()
    NSRect(x: 0, y: barY, width: W, height: barH).fill()
    rgb(0x000000, 0.10).setFill()
    NSRect(x: 0, y: barY - 1, width: W, height: 1).fill()

    let barTextY = barY + 10
    var lx: CGFloat = 26
    drawSymbol("apple.logo", midX: lx + 10, midY: barY + barH / 2, pt: 22, color: ink)
    lx += 38
    let finder = text("Finder", 25, ink, weight: .bold)
    finder.draw(at: NSPoint(x: lx, y: barTextY)); lx += finder.size().width + 30
    for m in ["File", "Edit", "View", "Go"] {
        let t = text(m, 25, ink)
        t.draw(at: NSPoint(x: lx, y: barTextY))
        lx += t.size().width + 30
    }
    var rx = W - 24
    let clock = text("Tue 29 Jul   9:41", 25, ink, weight: .medium)
    rx -= clock.size().width
    clock.draw(at: NSPoint(x: rx, y: barTextY))
    rx -= 30
    drawSymbol("switch.2", midX: rx, midY: barY + barH / 2, pt: 20, color: ink)
    rx -= 44
    drawSymbol(symbolImage("battery.75percent", pt: 24, color: ink) != nil
               ? "battery.75percent" : "battery.75",
               midX: rx, midY: barY + barH / 2, pt: 24, color: ink)
    rx -= 46
    drawSymbol("wifi", midX: rx, midY: barY + barH / 2, pt: 21, color: ink)

    // The notch itself: black, hanging into the bar, rounded below.
    let notch = NSRect(x: (W - 300) / 2, y: barY, width: 300, height: barH)
    NSColor.black.setFill()
    flushTop(notch, 14).fill()
}

func chip(_ s: String, tint: NSColor, at x: CGFloat, y: CGFloat) -> CGFloat {
    let t = text(s, 18, tint, weight: .semibold, mono: true)
    let w = t.size().width + 18
    rgb(0xFFFFFF, 0.11).setFill()
    rounded(NSRect(x: x, y: y, width: w, height: 30), 8).fill()
    t.draw(at: NSPoint(x: x + 9, y: y + 4))
    return w
}
/// Chips laid right-to-left from a trailing edge; returns nothing, draws in order.
func chipsRight(_ items: [(String, NSColor)], trailing: CGFloat, y: CGFloat, elapsed: String?) {
    var x = trailing
    if let e = elapsed {
        let t = text(e, 18, rgb(0xFFFFFF, 0.45), weight: .medium, mono: true)
        x -= t.size().width
        t.draw(at: NSPoint(x: x, y: y + 4))
        x -= 12
    }
    for (s, tint) in items.reversed() {
        let t = text(s, 18, tint, weight: .semibold, mono: true)
        let w = t.size().width + 18
        x -= w
        rgb(0xFFFFFF, 0.11).setFill()
        rounded(NSRect(x: x, y: y, width: w, height: 30), 8).fill()
        t.draw(at: NSPoint(x: x + 9, y: y + 4))
        x -= 10
    }
}

enum Phase {
    case working, attention, expand, open, clicked, collapse, flash, resumed
    // Second act: Claude asks a question, one tap on an option answers it.
    case attention2, expand2, openQ, clickedQ, collapse2, flashQ, resumed2
}
func phase(for f: Int) -> Phase {
    switch f {
    case 0..<16:    return .working
    case 16..<30:   return .attention
    case 30..<38:   return .expand
    case 38..<58:   return .open
    case 58..<62:   return .clicked
    case 62..<69:   return .collapse
    case 69..<86:   return .flash
    case 86..<98:   return .resumed
    case 98..<112:  return .attention2
    case 112..<120: return .expand2
    case 120..<142: return .openQ
    case 142..<146: return .clickedQ
    case 146..<153: return .collapse2
    case 153..<170: return .flashQ
    default:        return .resumed2
    }
}
func smooth(_ t: CGFloat) -> CGFloat { t * t * (3 - 2 * t) }

// Geometry shared by pill and panel — both hang flush off the notch's bottom edge.
let topY = H - barH                 // bottom edge of the bar/notch
let pillH: CGFloat = 56
let panelW: CGFloat = 920, panelH: CGFloat = 456

func pillWidth(_ p: Phase) -> CGFloat {
    switch p {
    case .flash, .flashQ: return 250
    case .attention, .expand, .attention2, .expand2: return 260
    default: return 300
    }
}

/// The expanded panel's content, drawn into `panel` (alpha-composited by caller).
/// The layout is the reference card's: hero row, Permission Request, mini-diff,
/// Deny / Allow. Fixed offsets from the top so nothing can spill past the bottom.
func drawPanelContent(_ panel: NSRect, p: Phase, f: Int) -> NSRect {
    let pad: CGFloat = 28
    let x = panel.minX + pad
    let top = panel.maxY

    // ---- hero box ----
    let hero = NSRect(x: x, y: top - 132, width: panel.width - pad * 2, height: 104)
    rgb(0xFFFFFF, 0.055).setFill()
    rounded(hero, 20).fill()
    let mascot = crab[f % crab.count]
    let mh: CGFloat = 44
    let mw = mh * mascot.size.width / mascot.size.height
    mascot.draw(in: NSRect(x: hero.minX + 20, y: hero.maxY - mh - 16, width: mw, height: mh))
    let tx = hero.minX + 20 + mw + 18
    text("auth-api · main", 26, .white, weight: .semibold)
        .draw(at: NSPoint(x: tx, y: hero.maxY - 42))
    let you = NSMutableAttributedString()
    you.append(text("You: ", 21, rgb(0xFFFFFF, 0.4)))
    you.append(text("fix the auth bug in middleware", 21, rgb(0xFFFFFF, 0.6)))
    you.draw(at: NSPoint(x: tx, y: hero.maxY - 71))
    let status = NSMutableAttributedString()
    status.append(text("needs approval", 22, amber, weight: .medium))
    status.append(text("  Edit: src/auth/middleware.ts", 21, rgb(0xFFFFFF, 0.55)))
    status.draw(at: NSPoint(x: tx, y: hero.maxY - 99))
    chipsRight([("Claude", claudeBrand), ("opus-5", rgb(0xFFFFFF, 0.85)), ("Warp", .white)],
               trailing: hero.maxX - 16, y: hero.maxY - 46, elapsed: "28m")

    // ---- permission card ----
    let head = NSMutableAttributedString()
    head.append(text("● ", 17, amber))
    head.append(text("Permission Request", 21, rgb(0xFFFFFF, 0.55), weight: .semibold))
    head.draw(at: NSPoint(x: x + 20, y: top - 166))
    let tool = NSMutableAttributedString()
    tool.append(text("⚠︎ Edit", 23, rgb(0xFF9F0A), weight: .semibold, mono: true))
    tool.append(text("  src/auth/middleware.ts", 23, rgb(0xFFFFFF, 0.92), mono: true))
    tool.draw(at: NSPoint(x: x + 20, y: top - 204))

    let box = NSRect(x: x + 20, y: top - 348, width: panel.width - pad * 2 - 40, height: 132)
    rgb(0xFFFFFF, 0.06).setFill()
    rounded(box, 12).fill()
    var ly = box.maxY - 34
    let lines: [(String, String, NSColor, NSColor)] = [
        ("−", "  jwt.verify(token);", rgb(0xFF6B60), rgb(0xFFFFFF, 0.5)),
        ("+", "  if (!token) throw new", green, rgb(0xFFFFFF, 0.92)),
        ("+", "    AuthError('missing');", green, rgb(0xFFFFFF, 0.92)),
        ("+", "  return jwt.verify(token);", green, rgb(0xFFFFFF, 0.92)),
    ]
    for (gutter, code, gc, cc) in lines {
        text(gutter, 20, gc, mono: true).draw(at: NSPoint(x: box.minX + 14, y: ly))
        text(code, 20, cc, mono: true).draw(at: NSPoint(x: box.minX + 40, y: ly))
        ly -= 28
    }
    let counts = NSMutableAttributedString()
    counts.append(text("+3", 19, green, weight: .semibold, mono: true))
    counts.append(text("  −1", 19, rgb(0xFF6B60), weight: .semibold, mono: true))
    counts.draw(at: NSPoint(x: x + 20, y: top - 378))
    text("⋯", 26, rgb(0xFFFFFF, 0.55), weight: .semibold)
        .draw(at: NSPoint(x: panel.maxX - pad - 24, y: top - 380))

    // ---- Deny / Allow ----
    let btnW = (panel.width - pad * 2 - 40 - 16) / 2
    let deny = NSRect(x: x + 20, y: top - 438, width: btnW, height: 50)
    let allow = NSRect(x: deny.maxX + 16, y: top - 438, width: btnW, height: 50)
    rgb(0xFFFFFF, 0.10).setFill()
    rounded(deny, 14).fill()
    text("Deny", 23, .white, weight: .semibold)
        .draw(at: NSPoint(x: deny.midX - 28, y: deny.minY + 12))
    (p == .clicked ? rgb(0xD8D8D8) : NSColor.white).setFill()
    rounded(allow, 14).fill()
    text("Allow", 23, .black, weight: .semibold)
        .draw(at: NSPoint(x: allow.midX - 30, y: allow.minY + 12))
    return allow
}

/// Second act's panel: the question card — hero row, "● Auth" header, the
/// question, three tappable options, the quiet defer link. Returns the rect of
/// the option the cursor goes for.
func drawQuestionContent(_ panel: NSRect, p: Phase, f: Int) -> NSRect {
    let pad: CGFloat = 28
    let x = panel.minX + pad
    let top = panel.maxY

    // ---- hero box ----
    let hero = NSRect(x: x, y: top - 132, width: panel.width - pad * 2, height: 104)
    rgb(0xFFFFFF, 0.055).setFill()
    rounded(hero, 20).fill()
    let mascot = crab[f % crab.count]
    let mh: CGFloat = 44
    let mw = mh * mascot.size.width / mascot.size.height
    mascot.draw(in: NSRect(x: hero.minX + 20, y: hero.maxY - mh - 16, width: mw, height: mh))
    let tx = hero.minX + 20 + mw + 18
    text("auth-api · main", 26, .white, weight: .semibold)
        .draw(at: NSPoint(x: tx, y: hero.maxY - 42))
    let you = NSMutableAttributedString()
    you.append(text("You: ", 21, rgb(0xFFFFFF, 0.4)))
    you.append(text("add authentication to the API", 21, rgb(0xFFFFFF, 0.6)))
    you.draw(at: NSPoint(x: tx, y: hero.maxY - 71))
    let status = NSMutableAttributedString()
    status.append(text("Claude asks", 22, blue, weight: .medium))
    status.append(text("  Which auth strategy?", 21, rgb(0xFFFFFF, 0.55)))
    status.draw(at: NSPoint(x: tx, y: hero.maxY - 99))
    chipsRight([("Claude", claudeBrand), ("opus-5", rgb(0xFFFFFF, 0.85)), ("Warp", .white)],
               trailing: hero.maxX - 16, y: hero.maxY - 46, elapsed: "31m")

    // ---- question card ----
    let head = NSMutableAttributedString()
    head.append(text("● ", 17, blue))
    head.append(text("Auth", 21, rgb(0xFFFFFF, 0.55), weight: .semibold))
    head.draw(at: NSPoint(x: x + 20, y: top - 166))
    text("Which auth strategy should the new API use?", 25, .white, weight: .medium)
        .draw(at: NSPoint(x: x + 20, y: top - 202))

    let options: [(String, String)] = [
        ("JWT tokens", "Stateless, works across services"),
        ("Server sessions", "Simple, revocable, needs sticky state"),
        ("OAuth via provider", ""),
    ]
    var clicked = NSRect.zero
    var oy = top - 222
    for (i, opt) in options.enumerated() {
        let h: CGFloat = opt.1.isEmpty ? 46 : 66
        let box = NSRect(x: x + 20, y: oy - h, width: panel.width - pad * 2 - 40, height: h)
        let hot = i == 0 && (p == .clickedQ || p == .flashQ)
        rgb(0xFFFFFF, hot ? 0.16 : 0.07).setFill()
        rounded(box, 12).fill()
        text(opt.0, 22, rgb(0xFFFFFF, 0.92), weight: .semibold)
            .draw(at: NSPoint(x: box.minX + 18, y: box.maxY - 32))
        if !opt.1.isEmpty {
            text(opt.1, 19, rgb(0xFFFFFF, 0.55))
                .draw(at: NSPoint(x: box.minX + 18, y: box.maxY - 58))
        }
        if i == 0 { clicked = box }
        oy = box.minY - 8
    }
    text("Answer in terminal", 19, rgb(0xFFFFFF, 0.5))
        .draw(at: NSPoint(x: x + 20, y: oy - 26))
    text("⋯", 26, rgb(0xFFFFFF, 0.55), weight: .semibold)
        .draw(at: NSPoint(x: panel.maxX - pad - 24, y: oy - 28))
    return clicked
}

func renderFrame(_ f: Int) -> CGImage {
    let img = NSImage(size: NSSize(width: W, height: H))
    img.lockFocus()
    let p = phase(for: f)

    drawWallpaper()
    drawDock()
    drawMenuBarWithNotch()

    var allowRect = NSRect.zero
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 22
    shadow.shadowOffset = NSSize(width: 0, height: -8)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

    switch p {
    case .expand, .collapse, .expand2, .collapse2:
        // The shape inflates out of the notch (and folds back into it): width and
        // height interpolate around the centre, content fades in with the growth.
        let t: CGFloat
        switch p {
        case .expand:    t = smooth(CGFloat(f - 30) / 7)
        case .collapse:  t = smooth(1 - CGFloat(f - 62) / 6)
        case .expand2:   t = smooth(CGFloat(f - 112) / 7)
        default:         t = smooth(1 - CGFloat(f - 146) / 6)
        }
        let w = pillWidth(.attention) + (panelW - pillWidth(.attention)) * t
        let h = pillH + (panelH - pillH) * t
        let r = NSRect(x: (W - w) / 2, y: topY - h, width: w, height: h)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        flushTop(r, 26).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        if t > 0.55, let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            flushTop(r, 26).addClip()
            cg.setAlpha((t - 0.55) / 0.45)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            let full = NSRect(x: (W - panelW) / 2, y: topY - panelH,
                              width: panelW, height: panelH)
            if p == .expand2 || p == .collapse2 {
                _ = drawQuestionContent(full, p: p, f: f)
            } else {
                _ = drawPanelContent(full, p: p, f: f)
            }
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
    case .open, .clicked, .openQ, .clickedQ:
        let r = NSRect(x: (W - panelW) / 2, y: topY - panelH, width: panelW, height: panelH)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        flushTop(r, 26).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        allowRect = p == .openQ || p == .clickedQ
            ? drawQuestionContent(r, p: p, f: f)
            : drawPanelContent(r, p: p, f: f)
    default:
        let w = pillWidth(p)
        let r = NSRect(x: (W - w) / 2, y: topY - pillH, width: w, height: pillH)
        NSGraphicsContext.current?.saveGraphicsState()
        shadow.set()
        NSColor.black.setFill()
        flushTop(r, 26).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        if p == .flash || p == .flashQ {
            let t = text(p == .flash ? "✓ Allowed" : "✓ Answered", 25, green, weight: .semibold)
            t.draw(at: NSPoint(x: r.midX - t.size().width / 2,
                               y: r.midY - t.size().height / 2))
        } else {
            let mascot = crab[f % crab.count]
            let mh: CGFloat = 36
            let mw = mh * mascot.size.width / mascot.size.height
            let label: NSAttributedString =
                p == .attention || p == .expand
                ? text("approve?", 23, rgb(0xFFFFFF, 0.9), weight: .medium, mono: true)
                : p == .attention2 || p == .expand2
                ? text("answer?", 23, rgb(0xFFFFFF, 0.9), weight: .medium, mono: true)
                : text(p == .resumed ? "Pondering…" : p == .resumed2 ? "Simmering…" : "Weaving…", 23,
                       rgb(0xFFFFFF, 0.9), weight: .medium, mono: true)
            let badge = text("2", 19, rgb(0xFFFFFF, 0.65), weight: .semibold, mono: true)
            let badgeW = badge.size().width + 18
            let content = mw + 14 + label.size().width + 14 + badgeW
            var cx = r.midX - content / 2
            mascot.draw(in: NSRect(x: cx, y: r.midY - mh / 2, width: mw, height: mh))
            cx += mw + 14
            label.draw(at: NSPoint(x: cx, y: r.midY - label.size().height / 2))
            cx += label.size().width + 14
            rgb(0xFFFFFF, 0.12).setFill()
            rounded(NSRect(x: cx, y: r.midY - 15, width: badgeW, height: 30), 8).fill()
            badge.draw(at: NSPoint(x: cx + 9, y: r.midY - badge.size().height / 2))
        }
    }

    // ---- Cursor: flies in during attention, lands on Allow (act 1) or the
    // first option (act 2), leaves after ----
    if p != .working, p != .resumed, p != .resumed2 {
        let start = NSPoint(x: W - 140, y: 150)
        let pillPt = NSPoint(x: W / 2 + 40, y: topY - pillH - 6)
        let secondAct = [Phase.attention2, .expand2, .openQ, .clickedQ, .collapse2, .flashQ].contains(p)
        let allowPt = allowRect == .zero
            ? (secondAct ? NSPoint(x: W / 2, y: topY - 250)
                         : NSPoint(x: W / 2 + 240, y: topY - panelH + 130))
            : NSPoint(x: allowRect.midX, y: allowRect.midY + 16)
        var pos: NSPoint
        switch p {
        case .attention, .attention2:
            let t = smooth(CGFloat(f - (p == .attention ? 16 : 98)) / 13)
            pos = NSPoint(x: start.x + (pillPt.x - start.x) * t,
                          y: start.y + (pillPt.y - start.y) * t)
        case .expand, .expand2:
            let t = smooth(CGFloat(f - (p == .expand ? 30 : 112)) / 7)
            pos = NSPoint(x: pillPt.x + (allowPt.x - pillPt.x) * t,
                          y: pillPt.y + (allowPt.y - pillPt.y) * t)
        case .open, .openQ:
            let t = smooth(min(1, CGFloat(f - (p == .open ? 38 : 120)) / 10))
            pos = NSPoint(x: pillPt.x + (allowPt.x - pillPt.x) * min(1, 0.4 + t),
                          y: pillPt.y + (allowPt.y - pillPt.y) * min(1, 0.4 + t))
        case .clicked, .clickedQ:
            pos = allowPt
        default: // collapse/flash of either act — fly out, then stay gone
            let t = smooth(min(1, CGFloat(f - (secondAct ? 146 : 62)) / 16))
            if t >= 1 { pos = NSPoint(x: -100, y: -100) }
            else {
                pos = NSPoint(x: allowPt.x + (start.x - allowPt.x) * t,
                              y: allowPt.y + (start.y - allowPt.y) * t)
            }
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

let frames = 180
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outPath) as CFURL,
                                           UTType.gif.identifier as CFString, frames, nil)!
CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [
    kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
for f in 0..<frames {
    let cg = renderFrame(f)
    CGImageDestinationAddImage(dest, cg, [kCGImagePropertyGIFDictionary: [
        kCGImagePropertyGIFUnclampedDelayTime: 0.085,
        kCGImagePropertyGIFDelayTime: 0.085]] as CFDictionary)
    if let dir = dumpDir, [8, 24, 34, 48, 60, 66, 76, 94, 105, 116, 130, 144, 150, 160, 175].contains(f) {
        let rep = NSBitmapImageRep(cgImage: cg)
        try? rep.representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: "\(dir)/frame-\(f).png"))
    }
}
CGImageDestinationFinalize(dest)
print("wrote \(outPath)")

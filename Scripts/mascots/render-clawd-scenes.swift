// Renders Clawd's working scenes — the very poses and rhythms the app plays,
// read from Sources/AgentBar — into the README's GIF and a showcase for sharing.
// Pixel-exact: every pose is drawn at a whole number of pixels per art pixel,
// never resampled.
//
// Build & run (from repo root):
//   swiftc -target arm64-apple-macos12.0 \
//     $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") \
//     Scripts/mascots/render-clawd-scenes.swift -o /tmp/render-clawd-scenes
//   /tmp/render-clawd-scenes <outDir>
//
// Writes:
//   <outDir>/clawd-scenes.gif     every scene at once, island-style pills (README)
//   <outDir>/showcase/f0000.png…  1280×720 frames, one scene after another; make
//                                 the shareable video and GIF from them with ffmpeg
//                                 (docs/clawd-scenes.md has the two commands)
import AppKit
import ImageIO
import UniformTypeIdentifiers

@main
enum RenderClawdScenes {
    /// The order a viewer meets them in, and what each says beside the mascot.
    static let cast: [(scene: ClawdScene, word: String, caption: String)] = [
        (.think, "Thinking", "a turn starts, or Claude goes quiet"),
        (.read, "Reading", "Read"),
        (.search, "Searching", "Grep · Glob"),
        (.type, "Editing", "Edit · Write"),
        (.hammer, "Running command", "Bash"),
        (.web, "Browsing web", "WebFetch · WebSearch"),
        (.delegate, "Delegating", "a subagent"),
        (.compact, "Compacting", "the context is summarised"),
        (.walk, "Using tool", "any other tool"),
    ]
    static let fps = 12.5

    static func main() {
        let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        _ = NSApplication.shared
        writeGrid(to: out.appendingPathComponent("clawd-scenes.gif"))
        writeShowcase(to: out.appendingPathComponent("showcase"))
    }

    // MARK: - Frames of a scene

    /// One loop of `scene`, `pixel` points to an art pixel.
    static func loop(_ scene: ClawdScene, pixel: CGFloat) -> [NSImage] {
        let width = CGFloat(ClawdSceneArt.columns) * pixel
        guard let reel = scene.reel else {
            // The walk is the GIF's frames, 36 px tall on a 12-row grid: 3 px a pixel.
            return clawdCrabFramePNGs.compactMap(IconRenderer.decode).map { frame in
                canvas(NSSize(width: width, height: CGFloat(ClawdSceneArt.rows) * pixel)) {
                    let scale = pixel / 3
                    frame.draw(in: NSRect(x: 0, y: 0, width: frame.size.width * scale,
                                          height: frame.size.height * scale))
                }
            }
        }
        let poses = reel.poses.map { ClawdSceneArt.image($0, pixel: pixel, canvasWidth: width) }
        return reel.rhythm.map { poses[$0] }
    }

    // MARK: - README grid

    static func writeGrid(to url: URL) {
        let pixel: CGFloat = 4, columns = 3, gap: CGFloat = 14, margin: CGFloat = 20
        let pill = NSSize(width: 360, height: 76)
        let rows = (cast.count + columns - 1) / columns
        let size = NSSize(width: margin * 2 + CGFloat(columns) * pill.width + CGFloat(columns - 1) * gap,
                          height: margin * 2 + CGFloat(rows) * pill.height + CGFloat(rows - 1) * gap)
        let loops = cast.map { loop($0.scene, pixel: pixel) }
        let count = 150   // 12 s; long enough for every scene's slow beat to come round
        let frames = (0..<count).map { t in
            canvas(size) {
                NSColor(white: 0.11, alpha: 1).setFill()
                NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 18, yRadius: 18).fill()
                for (i, member) in cast.enumerated() {
                    let col = i % columns, row = i / columns
                    let origin = NSPoint(x: margin + CGFloat(col) * (pill.width + gap),
                                         y: size.height - margin - CGFloat(row + 1) * pill.height - CGFloat(row) * gap)
                    drawPill(at: origin, size: pill, mascot: loops[i][t % loops[i].count], word: member.word)
                }
            }
        }
        writeGIF(frames, to: url)
    }

    static func drawPill(at origin: NSPoint, size: NSSize, mascot: NSImage, word: String) {
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: origin, size: size),
                     xRadius: size.height / 2, yRadius: size.height / 2).fill()
        let m = NSPoint(x: origin.x + 26, y: origin.y + (size.height - mascot.size.height) / 2)
        mascot.draw(at: m, from: .zero, operation: .sourceOver, fraction: 1)
        let text = NSAttributedString(string: "\(word)…", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 20, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        text.draw(at: NSPoint(x: m.x + mascot.size.width + 16,
                              y: origin.y + (size.height - text.size().height) / 2))
    }

    // MARK: - Showcase

    static func writeShowcase(to dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = NSSize(width: 1280, height: 720)
        let pixel: CGFloat = 14
        var index = 0
        func emit(_ image: NSImage) {
            let name = String(format: "f%04d.png", index)
            try? png(image).write(to: dir.appendingPathComponent(name))
            index += 1
        }
        // Each scene for two loops and never under 2.8 s, so the slow ones get
        // their page turn or their puff of air in.
        for member in cast {
            let frames = loop(member.scene, pixel: pixel)
            let length = max(frames.count * 2, 35)
            for t in 0..<length {
                emit(showcaseFrame(size: size, mascot: frames[t % frames.count],
                                   word: member.word, caption: member.caption))
            }
        }
        // A closing card holds for 2.4 s.
        let card = canvas(size) {
            background(size)
            centred("Clawd shows what Claude is doing.", y: 410, size: 46, weight: .bold, in: size)
            centred("\(cast.count) scenes, picked live from what the session reports.",
                    y: 344, size: 25, weight: .regular, in: size, alpha: 0.6)
            centred("AgentBar · github.com/michalstrnadel/AgentBar", y: 244, size: 25,
                    weight: .semibold, in: size, color: NSColor(srgbRed: 0.84, green: 0.47, blue: 0.34, alpha: 1))
        }
        for _ in 0..<30 { emit(card) }
    }

    static func showcaseFrame(size: NSSize, mascot: NSImage, word: String, caption: String) -> NSImage {
        canvas(size) {
            background(size)
            centred("AgentBar", y: 632, size: 22, weight: .semibold, in: size, alpha: 0.45)
            mascot.draw(at: NSPoint(x: ((size.width - mascot.size.width) / 2).rounded(), y: 270),
                        from: .zero, operation: .sourceOver, fraction: 1)
            centred("\(word)…", y: 166, size: 48, weight: .bold, in: size, mono: true)
            centred(caption, y: 112, size: 25, weight: .regular, in: size, alpha: 0.55)
        }
    }

    static func background(_ size: NSSize) {
        NSColor(white: 0.07, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
    }

    static func centred(_ string: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, in canvas: NSSize,
                        alpha: CGFloat = 1, color: NSColor = .white, mono: Bool = false) {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                        : NSFont.systemFont(ofSize: size, weight: weight)
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color.withAlphaComponent(alpha),
        ])
        text.draw(at: NSPoint(x: ((canvas.width - text.size().width) / 2).rounded(), y: y))
    }

    // MARK: - Plumbing

    /// A bitmap at exactly `size` pixels, drawn without smoothing.
    static func canvas(_ size: NSSize, _ body: () -> Void) -> NSImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .none
        body()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    static func png(_ image: NSImage) -> Data {
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first!
        return rep.representation(using: .png, properties: [:])!
    }

    static func writeGIF(_ frames: [NSImage], to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         frames.count, nil) else { return }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFDelayTime: 1 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        for frame in frames {
            guard let cg = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            CGImageDestinationAddImage(dest, cg, frameProps)
        }
        CGImageDestinationFinalize(dest)
    }
}

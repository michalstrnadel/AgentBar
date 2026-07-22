import Cocoa

/// Turns an Agent's artwork into ready-to-draw menu bar frames, in both color modes.
/// All decoding/processing happens once per agent and is cached.
final class IconRenderer {
    struct Sprite {
        let colorFrames: [NSImage]     // Color mode animation
        let templateFrames: [NSImage]  // System mode animation (monochrome adaptive)
        let fps: Double
        var restingColor: NSImage { colorFrames[0] }
        var restingTemplate: NSImage { templateFrames[0] }
    }

    static let shared = IconRenderer()
    private var cache: [String: Sprite] = [:]

    func sprite(for agent: Agent) -> Sprite {
        if let s = cache[agent.id] { return s }
        let s = build(agent)
        cache[agent.id] = s
        return s
    }

    private func build(_ agent: Agent) -> Sprite {
        switch agent.artwork {
        case .frames(let pngs, let fps):
            let frames = pngs.compactMap(Self.decode).map { Self.fit($0, height: 17) }
            let color = frames
            let template = frames.map(Self.adaptiveTemplate)
            return Sprite(colorFrames: color, templateFrames: template, fps: fps)

        case .tintedMark(let png):
            let mark = Self.fit(Self.trim(Self.decode(png) ?? NSImage()), height: 15)
            let tinted = Self.tint(mark, with: agent.brand)
            let ink = Self.solidTemplate(mark)
            return Sprite(colorFrames: Self.bobFrames(tinted),
                          templateFrames: Self.bobFrames(ink),
                          fps: 8)

        case .colorMark(let png):
            let mark = Self.fit(Self.trim(Self.decode(png) ?? NSImage()), height: 15)
            return Sprite(colorFrames: Self.bobFrames(mark),
                          templateFrames: Self.bobFrames(Self.adaptiveTemplate(mark)),
                          fps: 8)
        }
    }

    // MARK: - Building blocks

    static func decode(_ base64: String) -> NSImage? {
        guard let data = Data(base64Encoded: base64), let img = NSImage(data: data) else { return nil }
        return img
    }

    /// Crop transparent margins so differently-padded source canvases all behave the same.
    static func trim(_ src: NSImage) -> NSImage {
        guard let bmp = bitmap(src) else { return src }
        let pw = bmp.pixelsWide, ph = bmp.pixelsHigh
        var minX = pw, minY = ph, maxX = -1, maxY = -1
        for y in 0..<ph {
            for x in 0..<pw where (bmp.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return src }
        let rect = NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let cg = bmp.cgImage?.cropping(to: rect) else { return src }
        return NSImage(cgImage: cg, size: NSSize(width: rect.width / 2, height: rect.height / 2))
    }

    /// Scale to a menu-bar-friendly point height, preserving aspect.
    static func fit(_ src: NSImage, height: CGFloat) -> NSImage {
        guard src.size.height > 0 else { return src }
        let scale = height / src.size.height
        let size = NSSize(width: (src.size.width * scale).rounded(), height: height)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        src.draw(in: NSRect(origin: .zero, size: size))
        out.unlockFocus()
        return out
    }

    /// Recolor every opaque pixel with one color (for monochrome brand marks).
    static func tint(_ src: NSImage, with color: NSColor) -> NSImage {
        let out = NSImage(size: src.size)
        out.lockFocus()
        src.draw(in: NSRect(origin: .zero, size: src.size))
        color.set()
        NSRect(origin: .zero, size: src.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    /// A plain template: alpha kept, ink black, drawn by macOS in the bar's color.
    static func solidTemplate(_ src: NSImage) -> NSImage {
        let out = tint(src, with: .black)
        out.isTemplate = true
        return out
    }

    /// Template that preserves a colorful sprite's depth by mapping brightness to opacity:
    /// bright body stays solid ink, darker shading goes gray, darkest details (eyes,
    /// outlines) drop out as transparent holes. Ported from AI Status Notifier's
    /// crab renderer; thresholds tuned against the crab sprite.
    static func adaptiveTemplate(_ src: NSImage) -> NSImage {
        guard let bmp = bitmap(src), let cgSrc = bmp.cgImage else { return src }
        let pw = bmp.pixelsWide, ph = bmp.pixelsHigh
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8,
                                  bytesPerRow: pw * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return src }
        ctx.draw(cgSrc, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let raw = ctx.data else { return src }
        let px = raw.bindMemory(to: UInt8.self, capacity: pw * ph * 4)

        let darkCut = 0.30, bodyLevel = 0.54, gamma = 1.3
        for i in 0..<(pw * ph) {
            let off = i * 4
            let rawA = px[off + 3]
            guard rawA > 0 else { continue }
            let af = Double(rawA) / 255
            let r = Double(px[off]) / (255 * af)
            let g = Double(px[off + 1]) / (255 * af)
            let b = Double(px[off + 2]) / (255 * af)
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            px[off] = 0; px[off + 1] = 0; px[off + 2] = 0
            if lum < darkCut {
                px[off + 3] = 0
            } else {
                let t = min(1, (lum - darkCut) / (bodyLevel - darkCut))
                px[off + 3] = UInt8(max(0, min(255, Double(rawA) * pow(t, gamma))))
            }
        }
        guard let outCG = ctx.makeImage() else { return src }
        let img = NSImage(cgImage: outCG, size: src.size)
        img.isTemplate = true
        return img
    }

    /// Gentle vertical bob for single-image mascots: same mark drawn at sine offsets.
    static func bobFrames(_ mark: NSImage) -> [NSImage] {
        let steps = 6
        let amplitude: CGFloat = 1.5
        let canvas = NSSize(width: mark.size.width, height: mark.size.height + amplitude * 2)
        return (0..<steps).map { i in
            let phase = Double(i) / Double(steps) * 2 * .pi
            let dy = amplitude + CGFloat(sin(phase)) * amplitude
            let out = NSImage(size: canvas)
            out.lockFocus()
            mark.draw(in: NSRect(x: 0, y: dy, width: mark.size.width, height: mark.size.height))
            out.unlockFocus()
            out.isTemplate = mark.isTemplate
            return out
        }
    }

    /// Amber badge for "awaiting permission", composited onto any frame.
    static func withPermissionDot(_ src: NSImage) -> NSImage {
        let dot: CGFloat = 7
        let size = NSSize(width: src.size.width + dot / 2, height: max(src.size.height, 18))
        let out = NSImage(size: size)
        out.lockFocus()
        src.draw(in: NSRect(x: 0, y: (size.height - src.size.height) / 2,
                            width: src.size.width, height: src.size.height))
        NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: size.width - dot, y: size.height - dot,
                                    width: dot, height: dot)).fill()
        out.unlockFocus()
        out.isTemplate = false // the dot must stay amber even in System mode
        return out
    }

    private static func bitmap(_ src: NSImage) -> NSBitmapImageRep? {
        guard let tiff = src.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}

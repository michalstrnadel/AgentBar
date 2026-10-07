import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The card leaving the app: a PNG (portrait or square), or the card building
/// itself as a short MP4 or a looping GIF. Every frame comes from `WrapRenderer`,
/// so what is shared is exactly what was on screen.
enum WrapExport {
    enum Shape { case story, square
        var pixels: CGSize { self == .story ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
    }

    /// How long a moving export runs: the build, then the finished card held long
    /// enough to read before it loops.
    static let movingSeconds: Double = 6

    // MARK: - Still

    static func card(_ wrap: DayWrap, shape: Shape) -> NSBitmapImageRep? {
        WrapRenderer.bitmap(at: 0, wrap: wrap, pixels: shape.pixels, still: true)
    }

    static func png(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }

    // MARK: - Moving

    /// The card building, as an H.264 MP4 at 30 fps. `progress` is called on the
    /// calling queue with 0…1.
    static func writeMP4(_ wrap: DayWrap, to url: URL, shape: Shape = .story, fps: Int = 30,
                         progress: (Double) -> Void = { _ in }) throws {
        let size = shape.pixels
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000,
                                              AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ExportError("the video writer did not start") }
        writer.startSession(atSourceTime: .zero)

        let total = Int(movingSeconds * Double(fps))
        for n in 0..<total {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            guard let pool = adaptor.pixelBufferPool else { throw ExportError("no pixel buffer pool") }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let pb = buffer else { throw ExportError("no pixel buffer") }
            CVPixelBufferLockBaseAddress(pb, [])
            if let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: Int(size.width),
                                   height: Int(size.height), bitsPerComponent: 8,
                                   bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                       | CGBitmapInfo.byteOrder32Little.rawValue) {
                drawFlipped(ctx, size: size) {
                    WrapRenderer.draw(at: Double(n) / Double(fps), wrap: wrap, size: size, in: ctx)
                }
            }
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
            if n % 15 == 0 { progress(Double(n) / Double(total)) }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? ExportError("the video did not finish") }
        progress(1)
    }

    /// The card building, as a looping GIF: 540 × 960 at 15 fps — a size a post
    /// will take. Past the build every frame is the same, so the hold is one frame
    /// shown for as long, not dozens of copies.
    static func writeGIF(_ wrap: DayWrap, to url: URL, shape: Shape = .story,
                         progress: (Double) -> Void = { _ in }) throws {
        let size = CGSize(width: shape.pixels.width / 2, height: shape.pixels.height / 2)
        let fps = 15.0
        let building = Int(WrapRenderer.buildSeconds * fps)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         building + 1, nil)
        else { throw ExportError("the GIF could not be created") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        func frame(_ delay: Double) -> CFDictionary {
            [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay,
                                             kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary
        }
        for n in 0...building {
            let last = n == building
            guard let rep = WrapRenderer.bitmap(at: Double(n) / fps, wrap: wrap, pixels: size, still: last)
            else { continue }
            dither(rep)
            guard let cg = rep.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, frame(last ? movingSeconds - WrapRenderer.buildSeconds : 1 / fps))
            progress(Double(n + 1) / Double(building + 1))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError("the GIF could not be written") }
    }

    /// A GIF has 256 colours, and a fading element passes through more than that:
    /// quantised as they are, its edges come out as steps. A fixed 4 × 4 ordered
    /// pattern of ±3 levels breaks the steps up into a grain the eye reads as a
    /// fade — and, being fixed, it does not crawl from frame to frame as noise would.
    static func dither(_ rep: NSBitmapImageRep) {
        guard let data = rep.bitmapData, rep.bitsPerSample == 8, rep.samplesPerPixel >= 3 else { return }
        let bayer: [Int] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let spp = rep.samplesPerPixel, row = rep.bytesPerRow
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let d = (bayer[(y & 3) * 4 + (x & 3)] - 8) * 3 / 8
                let p = data + y * row + x * spp
                for c in 0..<3 { p[c] = UInt8(clamping: Int(p[c]) + d) }
            }
        }
    }

    /// Runs `body` with `ctx` flipped (y down) and set as the current AppKit context.
    static func drawFlipped(_ ctx: CGContext, size: CGSize, _ body: () -> Void) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    struct ExportError: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    // MARK: - Verification

    /// The card in both shapes, its share-safe twin, a strip of moments from the
    /// build, and the window, into `dir`. Offscreen: nothing opens.
    static func renderForVerification(to dir: URL, range: DayWrap.Range, demo: Bool, frames: Bool,
                                      video: Bool = false) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrap = demo ? WrapDemo.wrap(range)
            : DayWrap.load(range)
        var ok = true
        func write(_ rep: NSBitmapImageRep?, _ name: String) {
            guard let rep, let data = png(rep) else { ok = false; return }
            ok = (try? data.write(to: dir.appendingPathComponent(name))) != nil && ok
        }
        for shape in [Shape.story, .square] {
            let name = shape == .story ? "story" : "square"
            write(card(wrap, shape: shape), "card-\(name).png")
            write(card(wrap.shareSafe(), shape: shape), "card-\(name)-shared.png")
        }
        if frames {
            for t in [0.2, 0.5, 0.9, 1.3, 1.8, 2.4] {
                write(WrapRenderer.bitmap(at: t, wrap: wrap, pixels: CGSize(width: 540, height: 960)),
                      String(format: "build-%.1fs.png", t))
            }
        }
        if video {
            do {
                // The made-up day's names are nobody's; a real day's leave as they would.
                let moving = demo ? wrap : wrap.shareSafe()
                try writeMP4(moving, to: dir.appendingPathComponent("card.mp4"))
                try writeGIF(moving, to: dir.appendingPathComponent("card.gif"))
            } catch {
                FileHandle.standardError.write(Data("video: \(error)\n".utf8))
                ok = false
            }
        }
        ok = WrapWindow.shared.renderForVerification(wrap, to: dir.appendingPathComponent("window.png")) && ok
        return ok
    }
}

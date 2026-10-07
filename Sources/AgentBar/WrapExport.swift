import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// The recap leaving the app: a card as PNG (portrait or square), the whole story
/// as an MP4 or a GIF. Every frame comes from `WrapRenderer`, so what is shared is
/// exactly what played.
enum WrapExport {
    enum Shape { case story, square
        var pixels: CGSize { self == .story ? CGSize(width: 1080, height: 1920) : CGSize(width: 1080, height: 1080) }
    }

    /// Crossfade between slides, in seconds. Short: a cut on a beat with the edge
    /// taken off, not a dissolve anyone notices.
    static let fade: Double = 0.3

    /// The story at `t` seconds: the slide that is playing, with the next one fading
    /// in over its last moments.
    static func drawStory(at t: Double, slides: [WrapSlide], wrap: DayWrap, size: CGSize,
                          in ctx: CGContext, still: Bool = false) {
        guard !slides.isEmpty else { return }
        let d = WrapRenderer.slideSeconds
        let i = min(slides.count - 1, max(0, Int(t / d)))
        let s = t - Double(i) * d
        WrapRenderer.draw(slides[i], at: s, global: t, wrap: wrap, size: size, in: ctx, still: still)
        if i + 1 < slides.count, s > d - fade {
            let a = WrapStyle.easeInOut((s - (d - fade)) / fade)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(a))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            WrapRenderer.draw(slides[i + 1], at: 0, global: t, wrap: wrap, size: size, in: ctx)
            ctx.endTransparencyLayer()
            ctx.restoreGState()
        }
    }

    static func duration(of slides: [WrapSlide]) -> Double {
        Double(slides.count) * WrapRenderer.slideSeconds
    }

    // MARK: - Still

    static func card(_ wrap: DayWrap, shape: Shape) -> NSBitmapImageRep? {
        WrapRenderer.bitmap(.card, at: 0, wrap: wrap, pixels: shape.pixels, still: true)
    }

    static func png(_ rep: NSBitmapImageRep) -> Data? {
        rep.representation(using: .png, properties: [:])
    }

    // MARK: - Moving

    /// The whole story as an H.264 MP4, 1080 × 1920 at 30 fps. `progress` is called
    /// on the calling queue with 0…1.
    static func writeMP4(_ wrap: DayWrap, to url: URL, fps: Int = 30,
                         progress: (Double) -> Void = { _ in }) throws {
        let slides = WrapRenderer.slides(for: wrap)
        let size = Shape.story.pixels
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000,
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

        let total = Int(duration(of: slides) * Double(fps))
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
                    drawStory(at: Double(n) / Double(fps), slides: slides, wrap: wrap, size: size, in: ctx)
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

    /// The story as a looping GIF, smaller and slower than the video: 540 × 960 at
    /// 12 fps, three seconds a slide, so it stays a size a post will take.
    static func writeGIF(_ wrap: DayWrap, to url: URL, progress: (Double) -> Void = { _ in }) throws {
        let slides = WrapRenderer.slides(for: wrap)
        let size = CGSize(width: 540, height: 960)
        let fps = 12.0, perSlide = 3.0
        let framesPerSlide = Int(perSlide * fps)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString,
                                                         slides.count * framesPerSlide, nil)
        else { throw ExportError("the GIF could not be created") }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for (k, slide) in slides.enumerated() {
            for n in 0..<framesPerSlide {
                // The slide's own clock runs at the video's pace over its first
                // `perSlide` seconds — every entrance plays, just less of the hold.
                let s = Double(n) / fps * (WrapRenderer.slideSeconds / perSlide) * 0.85
                guard let rep = WrapRenderer.bitmap(slide, at: s, global: Double(k) * perSlide + Double(n) / fps,
                                                    wrap: wrap, pixels: size),
                      let cg = rep.cgImage else { continue }
                CGImageDestinationAddImage(dest, cg, frameProps)
            }
            progress(Double(k + 1) / Double(slides.count))
        }
        guard CGImageDestinationFinalize(dest) else { throw ExportError("the GIF could not be written") }
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

    /// Every slide as a still, both cards, and — with `frames` — a strip of moments
    /// from each slide's animation, into `dir`. Offscreen: nothing opens.
    static func renderForVerification(to dir: URL, range: DayWrap.Range, demo: Bool, frames: Bool) -> Bool {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let wrap = demo ? WrapDemo.wrap(range)
            : DayWrap.make(range, history: HistoryStore.read(), ledger: DecisionLedger.read())
        var ok = true
        let slides = WrapRenderer.slides(for: wrap)
        for (i, slide) in slides.enumerated() {
            guard let rep = WrapRenderer.bitmap(slide, at: 0, wrap: wrap, pixels: Shape.story.pixels, still: true),
                  let data = png(rep) else { ok = false; continue }
            ok = (try? data.write(to: dir.appendingPathComponent(String(format: "%02d-%@.png", i, slide.rawValue)))) != nil && ok
            guard frames else { continue }
            for t in [0.3, 0.8, 1.5, 3.0] {
                if let rep = WrapRenderer.bitmap(slide, at: t, wrap: wrap, pixels: CGSize(width: 540, height: 960)),
                   let data = png(rep) {
                    try? data.write(to: dir.appendingPathComponent(String(format: "%02d-%@-%.1fs.png", i, slide.rawValue, t)))
                }
            }
        }
        for shape in [Shape.story, .square] {
            guard let rep = card(wrap.shareSafe(), shape: shape), let data = png(rep) else { ok = false; continue }
            ok = (try? data.write(to: dir.appendingPathComponent("card-\(shape == .story ? "story" : "square")-shared.png"))) != nil && ok
        }
        return ok
    }
}

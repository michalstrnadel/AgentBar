import Cocoa

/// Finds a sprite's eyes and redraws the sprite with them moved or shut — what lets
/// Clawd glance at the pointer without a second set of hand-drawn frames.
///
/// The eyes are read off the artwork rather than written down as coordinates: two
/// small dark islands fully inside the body. Coordinates would be right for exactly
/// the frame they were measured on and silently wrong the day the sprite is
/// regenerated; a search that finds nothing simply turns the gaze off. Only Clawd
/// is asked. The other marks either have no eyes (the Codex knot, the Antigravity
/// arch, every logo) or, like Copilot's goggles, have eyes that are a face's worth
/// of shading rather than two pixels — moving those would smear the art, not
/// animate it.
enum MascotEyes {
    /// A rectangle in bitmap pixels, inclusive, y down (the way `colorAt` counts).
    struct PixelBox: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
    }

    struct Eyes {
        /// What has to be painted over to make the drawn eyes disappear —
        /// a pixel wider than the eyes, so the antialiased rim goes with them.
        let cover: [NSRect]
        /// The eyes themselves, rim and all, to be drawn back at an offset.
        let ink: [NSRect]
    }

    /// The 4-connected islands of `isDark` in a `width` × `height` grid. Pure, so
    /// the search can be tested on a grid drawn in the test itself.
    static func islands(width: Int, height: Int, isDark: (Int, Int) -> Bool) -> [PixelBox] {
        var seen = [Bool](repeating: false, count: width * height)
        var out: [PixelBox] = []
        for y in 0..<height {
            for x in 0..<width where !seen[y * width + x] && isDark(x, y) {
                var box = PixelBox(minX: x, minY: y, maxX: x, maxY: y)
                var stack = [(x, y)]
                seen[y * width + x] = true
                while let (cx, cy) = stack.popLast() {
                    box.minX = min(box.minX, cx); box.maxX = max(box.maxX, cx)
                    box.minY = min(box.minY, cy); box.maxY = max(box.maxY, cy)
                    for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
                    where nx >= 0 && ny >= 0 && nx < width && ny < height
                        && !seen[ny * width + nx] && isDark(nx, ny) {
                        seen[ny * width + nx] = true
                        stack.append((nx, ny))
                    }
                }
                out.append(box)
            }
        }
        return out
    }

    /// Exactly two islands, each small, neither touching the canvas edge: a pair of
    /// eyes. Anything else — one blob, a dark outline, a dozen specks — is art this
    /// was never meant for, and the answer is no eyes rather than a guess.
    static func looksLikeEyes(_ boxes: [PixelBox], width: Int, height: Int) -> Bool {
        guard boxes.count == 2 else { return false }
        return boxes.allSatisfy { b in
            b.minX > 0 && b.minY > 0 && b.maxX < width - 1 && b.maxY < height - 1
                && b.width * 5 <= width && b.height * 3 <= height
        }
    }

    /// Clawd's eyes in a full-colour frame, in the image's points. Run once per
    /// frame and cached by the caller; it reads every pixel.
    static func find(in image: NSImage) -> Eyes? {
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff)
        else { return nil }
        let pw = bmp.pixelsWide, ph = bmp.pixelsHigh
        guard pw > 2, ph > 2 else { return nil }
        func lum(_ x: Int, _ y: Int) -> Double? {
            guard let c = bmp.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                  c.alphaComponent > 0.5 else { return nil }
            return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
        }
        // Loose, so the antialiased rim counts as eye: Clawd's body sits near
        // 0.56, his eyes near 0, and the rim anywhere between.
        let loose = islands(width: pw, height: ph) { x, y in (lum(x, y) ?? 1) < 0.45 }
        guard looksLikeEyes(loose, width: pw, height: ph) else { return nil }
        // Painting out takes one pixel more each way — what is left of a rim
        // that blended past the threshold reads as a ghost of the old eye
        // beside the new one. The eyes are well inside the body, so the margin
        // only ever covers body.
        let cover = loose.map {
            PixelBox(minX: $0.minX - 1, minY: $0.minY - 1, maxX: $0.maxX + 1, maxY: $0.maxY + 1)
        }
        let sx = image.size.width / CGFloat(pw), sy = image.size.height / CGFloat(ph)
        func rect(_ b: PixelBox) -> NSRect {
            NSRect(x: CGFloat(b.minX) * sx, y: CGFloat(ph - 1 - b.maxY) * sy,
                   width: CGFloat(b.width) * sx, height: CGFloat(b.height) * sy)
        }
        return Eyes(cover: cover.map(rect), ink: loose.map(rect))
    }

    /// `image` with its eyes painted out and drawn back `pupil` points over —
    /// closed to their bottom row when `closed`.
    ///
    /// Nothing is painted in a colour of its own. Over each eye goes a patch of
    /// the body from just below it, and the eye goes back as the eye's own
    /// pixels: a filled colour sampled from the bitmap came out a shade off once
    /// colour management had been through it, a visible square on the crab's
    /// face, while pixels copied from the same image cannot disagree with it. It
    /// also makes the template (System colour) case the same code — there the
    /// body is ink and the eyes are holes, and copying a hole moves the hole.
    static func redraw(_ image: NSImage, eyes: Eyes, pupil: MascotPersonality.Pupil,
                       closed: Bool) -> NSImage {
        let out = NSImage(size: image.size, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: image.size))
            for r in eyes.cover {
                image.draw(in: r, from: r.offsetBy(dx: 0, dy: -r.height),
                           operation: .copy, fraction: 1)
            }
            for r in eyes.ink {
                var from = r
                // Pixel art closes an eye by keeping its bottom row.
                if closed { from.size.height = max(r.height / 3, 0.5) }
                let to = from.offsetBy(dx: CGFloat(pupil.dx), dy: CGFloat(pupil.dy))
                image.draw(in: to, from: from, operation: .copy, fraction: 1)
            }
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }
}

// MARK: - Wave

/// Clawd's hello: his right claw raised and lowered a couple of times, drawn from
/// the resting frame rather than from a second set of hand-drawn frames — there is
/// no wave in the walk cycle, and the walk is all the artwork there is.
///
/// Found the way the eyes are: read off the artwork, never written down. The body
/// is the run of columns that are mostly ink top to bottom; the claw is whatever
/// ink sits to the right of it, which on Clawd is the arm band sticking out of his
/// side. Anything else — no ink out there, ink reaching half the height (that is
/// body, not an arm), nothing above it to lift into — and there is no wave.
extension MascotEyes {
    struct Claw: Equatable {
        /// The stub to the right of the body, in bitmap pixels, y down.
        let stub: PixelBox
        /// The last column of the body — the shoulder the claw turns about.
        let shoulder: Int
        let pixelsWide: Int
        let pixelsHigh: Int

        /// How far the tip goes up at the top of the wave, in pixels: the stub's
        /// own height, so it reads as the arm turned up rather than nudged, and
        /// never past the top of the canvas.
        var lift: Int { min(stub.minY, max(2, stub.height)) }
    }

    /// The right claw in a grid. Pure, so the search can be tested on a grid drawn
    /// in the test itself. `isInk` should count faint pixels too: whatever is left
    /// behind when the stub moves reads as a ghost of the old arm, and the body's
    /// antialiased rim, faint top to bottom, is what keeps that rim with the body.
    static func clawStub(width: Int, height: Int,
                         isInk: (Int, Int) -> Bool) -> (shoulder: Int, stub: PixelBox)? {
        guard width > 2, height > 2 else { return nil }
        // The body: the widest run of columns inked for at least half the height.
        let tall = (0..<width).map { x in
            (0..<height).reduce(0) { $0 + (isInk(x, $1) ? 1 : 0) } * 2 >= height
        }
        var best: ClosedRange<Int>?
        var start: Int?
        for x in 0...width {
            if x < width, tall[x] { if start == nil { start = x }; continue }
            if let s = start {
                if x - s > best?.count ?? 0 { best = s...(x - 1) }
                start = nil
            }
        }
        guard let body = best, body.upperBound < width - 2 else { return nil }
        var box: PixelBox?
        for x in (body.upperBound + 1)..<width {
            for y in 0..<height where isInk(x, y) {
                if var b = box {
                    b.minX = min(b.minX, x); b.maxX = max(b.maxX, x)
                    b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                    box = b
                } else {
                    box = PixelBox(minX: x, minY: y, maxX: x, maxY: y)
                }
            }
        }
        guard let stub = box, stub.minX == body.upperBound + 1, stub.width >= 2,
              stub.height * 2 < height, stub.minY >= 2
        else { return nil }
        return (body.upperBound, stub)
    }

    /// The right claw of `image`, or nil when there is no claw to wave.
    static func findClaw(in image: NSImage) -> Claw? {
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff)
        else { return nil }
        let pw = bmp.pixelsWide, ph = bmp.pixelsHigh
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bmp.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        guard let found = clawStub(width: pw, height: ph, isInk: { alpha($0, $1) > 0.02 })
        else { return nil }
        return Claw(stub: found.stub, shoulder: found.shoulder, pixelsWide: pw, pixelsHigh: ph)
    }

    /// `image` with the claw turned up by `fraction` of `claw.lift`: each column of
    /// the stub goes up by its share of the lift, nothing at the shoulder and all
    /// of it at the tip, so the arm angles up from the body instead of sliding up
    /// its side. Like `redraw`, nothing is painted in a colour of its own — the
    /// stub is cleared and its own pixels go back higher up — so the template
    /// image is the same code.
    static func raise(_ image: NSImage, claw: Claw, by fraction: Double) -> NSImage {
        let sx = image.size.width / CGFloat(claw.pixelsWide)
        let sy = image.size.height / CGFloat(claw.pixelsHigh)
        let s = claw.stub
        let out = NSImage(size: image.size, flipped: false) { _ in
            image.draw(in: NSRect(origin: .zero, size: image.size))
            let y = CGFloat(claw.pixelsHigh - 1 - s.maxY) * sy
            let stub = NSRect(x: CGFloat(s.minX) * sx, y: y,
                              width: CGFloat(s.width) * sx, height: CGFloat(s.height) * sy)
            NSColor.clear.set()
            stub.fill(using: .copy)
            for i in 0..<s.width {
                let share = Double(i + 1) / Double(s.width)
                let up = (Double(claw.lift) * fraction * share).rounded()
                let column = NSRect(x: CGFloat(s.minX + i) * sx, y: y,
                                    width: sx, height: stub.height)
                image.draw(in: column.offsetBy(dx: 0, dy: CGFloat(up) * sy), from: column,
                           operation: .copy, fraction: 1)
            }
            return true
        }
        out.isTemplate = image.isTemplate
        return out
    }

    /// Half up, up, half, up, half, and back to `image` itself: two waves in six
    /// frames. Nil when the art has no claw to wave — `claw` is found on `image`
    /// unless the caller already has it (the template frame is searched as the
    /// colour one, whose ink it shares).
    static func waveFrames(of image: NSImage, claw: Claw? = nil) -> [NSImage]? {
        guard let claw = claw ?? findClaw(in: image) else { return nil }
        let half = raise(image, claw: claw, by: 0.5)
        let up = raise(image, claw: claw, by: 1)
        return [half, up, half, up, half, image]
    }
}

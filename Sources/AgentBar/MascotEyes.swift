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

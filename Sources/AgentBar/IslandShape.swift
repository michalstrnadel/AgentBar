import CoreGraphics

/// The island's outline, as a path the content view masks itself with.
///
/// Rounded below, always. On top it depends on what it hangs from: off a notch the
/// top edge is square, so the panel and the menu bar strip meet without a seam; on
/// a display with nothing to be continuous with, the top corners round like the
/// bottom ones.
///
/// The open panel on a notched display adds the one thing a square top corner gets
/// wrong: hardware never meets an edge at a right angle. The notch flows into the
/// bezel through a small concave fillet, and a black rectangle hanging off the
/// menu bar with sharp shoulders reads as a window parked under it rather than as
/// part of the same machine. So the open panel grows an *ear* at each top corner —
/// a quarter-circle web that curves the panel's side into the edge it hangs from.
///
/// The ears live outside the body, not carved out of it: the panel's frame widens by
/// one ear on each side (`panelWidth`) so the rows keep exactly the width they were
/// laid out for. Everything in that widened frame outside the path is transparent,
/// and the content view refuses hits there, so the strips beside the body stay the
/// desktop's to click.
///
/// The collapsed pill never gets ears. It is deliberately narrower than the notch —
/// the notch's own bottom corners curve inward, and anything sticking past that
/// curve shows up as little horns on the real screen. The ear therefore grows with
/// the panel's *height* (`ear(full:height:collapsedHeight:)`): nothing at pill
/// height, full size a couple of dozen points later. That one rule is what lets a
/// single frame animation carry the whole shape — the ears unfurl as the panel
/// opens and fold away as it closes, on the same curve, without a second clock.
enum IslandShape {
    /// The fillet's radius. Small on purpose: big enough to read as a curve at a
    /// glance, small enough that the strip it adds beside the panel stays a sliver.
    static let earWidth: CGFloat = 12

    /// How wide the panel's frame must be for a body of `body` points with ears of
    /// `ear` on either side. The body keeps its width; the frame pays for the ears.
    static func panelWidth(body: CGFloat, ear: CGFloat) -> CGFloat {
        body + 2 * max(0, ear)
    }

    /// The ear the current height earns. Zero at (or under) the collapsed height,
    /// growing half a point per point of height after it, capped at `full`. The
    /// ramp is steep enough that any real open panel — the shortest is a header and
    /// a footer — has its full ears, and gentle enough that the first frames of an
    /// opening don't sprout them out of a pill-shaped panel.
    static func ear(full: CGFloat, height: CGFloat, collapsedHeight: CGFloat) -> CGFloat {
        guard full > 0 else { return 0 }
        return min(full, max(0, height - collapsedHeight) / 2)
    }

    /// The outline for a frame of `size`, in unflipped (y-up) coordinates — the
    /// content view's own, and its backing layer's.
    ///
    /// `ear` is only honoured with `flushTop`: a floating bar has no edge for an ear
    /// to flow into. Both radii are clamped so a frame caught mid-animation at an
    /// odd size still gets a well-formed path rather than arcs that overlap.
    static func path(in size: CGSize, corner: CGFloat, ear: CGFloat, flushTop: Bool) -> CGPath {
        let w = max(0, size.width), h = max(0, size.height)
        let e = flushTop ? min(max(0, ear), w / 4, max(0, h - corner)) : 0
        let bodyW = w - 2 * e
        // A flush top only needs the corner to fit below the ear; a floating one
        // rounds both ends of the same side.
        let r = max(0, min(corner, bodyW / 2, flushTop ? h - e : h / 2))
        let p = CGMutablePath()
        // Tangent arcs throughout: each corner is "turn from this line onto that
        // one", which keeps the path correct without reasoning about arc direction.
        p.move(to: CGPoint(x: w / 2, y: h))
        if flushTop {
            p.addLine(to: CGPoint(x: w, y: h))
            // Right ear: from the far top corner, curving down onto the body's side.
            if e > 0 {
                p.addArc(tangent1End: CGPoint(x: w - e, y: h),
                         tangent2End: CGPoint(x: w - e, y: 0), radius: e)
            }
        } else {
            p.addArc(tangent1End: CGPoint(x: w, y: h),
                     tangent2End: CGPoint(x: w, y: 0), radius: r)
        }
        p.addArc(tangent1End: CGPoint(x: w - e, y: 0),
                 tangent2End: CGPoint(x: e, y: 0), radius: r)
        p.addArc(tangent1End: CGPoint(x: e, y: 0),
                 tangent2End: CGPoint(x: e, y: h), radius: r)
        if flushTop {
            // Left ear: up the body's side, curving out onto the top edge.
            if e > 0 {
                p.addArc(tangent1End: CGPoint(x: e, y: h),
                         tangent2End: CGPoint(x: 0, y: h), radius: e)
            } else {
                p.addLine(to: CGPoint(x: 0, y: h))
            }
        } else {
            p.addArc(tangent1End: CGPoint(x: 0, y: h),
                     tangent2End: CGPoint(x: w, y: h), radius: r)
        }
        p.closeSubpath()
        return p
    }
}

import Cocoa

/// Geometry and motion: where the pill and the open panel sit, how big they are,
/// and how they get from one shape to the other — and off the screen and back.
extension IslandController {
    /// The way out: a short fade while the pill rises a few points into the notch,
    /// the reverse of how `layout` brings it back. Snapping it off read as a glitch —
    /// the pill is in the corner of the eye all day, and a thing that vanishes there
    /// without moving looks like something broke. Under Reduce Motion it only
    /// fades: the slide is the motion, the fade is just the pill being gone.
    ///
    /// `after` is a fold still playing (see `rebuild`): the fade waits it out
    /// rather than racing it for the frame. `hiding` is set from the start, so a
    /// tick in between does not start a second exit, and an un-hide in between
    /// bumps the turn and the waiting fade never runs.
    func hide(animated: Bool, after delay: TimeInterval = 0) {
        guard panel.isVisible, !hiding else { return }
        visibilityTurn += 1
        // Nothing on its way out takes a click: one landing on the fading panel
        // would be lost on the content underneath.
        panel.ignoresMouseEvents = true
        guard animated else {
            panel.orderOut(nil)
            panel.alphaValue = 1
            return
        }
        let turn = visibilityTurn
        hiding = true
        let fade = { [weak self] in
            guard let self, self.visibilityTurn == turn else { return }
            var to = self.panel.frame
            if !self.reduceMotion { to.origin.y += Self.hideSlide }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().alphaValue = 0
                self.panel.animator().setFrame(to, display: true)
            }, completionHandler: { [weak self] in
                // Asked back while fading: `layout` already took the panel over.
                guard let self, self.visibilityTurn == turn else { return }
                self.hiding = false
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            })
        }
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fade)
        } else {
            fade()
        }
    }

    func layout(animated: Bool = false, force: Bool = false) {
        guard let screen = IslandGeometry.screen, !hidden else { return }
        // Held still under the caret. Store ticks keep arriving while a note is
        // typed; they are picked up the moment it is sent or dropped.
        if composing != nil, mode == .expanded, lastLaidMode == .expanded, !force { return }
        content.flushTop = IslandGeometry.notch(on: screen) != nil
        let modeChanged = mode != lastLaidMode
        let target: NSRect
        switch mode {
        case .collapsed:
            content.topInset = 0
            // The pill is the notch's chin: one fixed width, always. Sizing it to
            // the content made it resize with every rotating verb and every
            // working↔done flip — a constant wobble in the corner of the eye that
            // read as the island opening and closing all day. Slightly narrower
            // than the notch itself: the physical island's bottom corners curve
            // inward, and a pill matching it to the point leaves little ears
            // sticking past the curve on the real screen.
            let w = IslandGeometry.notch(on: screen).map { $0.width - 10 } ?? 200
            pill.configure(mark: flash == nil ? personality.decorate(mark) : nil, text: pillText,
                           count: flash == nil ? visibleSessions.count : 0,
                           height: Self.pillHeight,
                           width: w - IslandContentView.hPad * 2, tint: flash?.tint)
            content.setFooter(nil)
            content.setRows([pill], resetScroll: true)
            target = IslandGeometry.frame(width: w, height: Self.pillHeight, on: screen)
        case .expanded:
            content.topInset = 10
            // The footer is pinned, not stacked: with the panel clamped at the
            // screen edge the way into Settings and Quit has to stay reachable.
            content.setFooter(footer())
            content.setRows(rows(), resetScroll: modeChanged)
            // The panel is sized to its content; when that outgrows the screen it
            // clamps here and the content view scrolls the overflow into reach.
            let maxHeight = screen.visibleFrame.height - 24
            // Off a notch the frame pays for the ears on both sides, so the body —
            // and every row laid out at `expandedWidth` — keeps its width. On a plain
            // screen edge there is nothing to flow into and the frame stays as it was.
            let ear = content.flushTop ? IslandShape.earWidth : 0
            target = IslandGeometry.frame(width: IslandShape.panelWidth(body: Self.expandedWidth,
                                                                        ear: ear),
                                          height: min(content.contentHeight, maxHeight),
                                          on: screen)
        }
        lastLaidMode = mode
        // Coming back from hidden — or caught halfway out — is its own animation:
        // the hide played backwards, dropping out of the notch as it fades in.
        let appearing = !panel.isVisible || hiding
        let still = reduceMotion
        if appearing {
            visibilityTurn += 1
            hiding = false
        }
        if animated, appearing {
            if !panel.isVisible {
                var from = target
                if !still { from.origin.y += Self.hideSlide }
                panel.setFrame(from, display: false)
                panel.alphaValue = 0
            }
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().alphaValue = 1
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in self?.panel.invalidateShadow() })
        } else if animated, panel.isVisible {
            // One animation carries the whole shape: the frame is the only thing that
            // moves, and the outline — corners, ears — is recut from it on every step
            // (`IslandContentView.layout`), so there is no second clock to drift out
            // of step with it. Slow enough to read as one shape inflating out of the
            // notch, quick enough not to gate the click that follows.
            //
            // Opening overshoots by a hair and settles, the way a thing with a little
            // mass does; it is what makes the panel read as springing *out of* the
            // notch rather than being drawn there. Closing does not: a shape that
            // bounces on its way back into the notch looks like it missed. Same-shape
            // refreshes (a row added, a card answered) only morph the size, and take
            // less — they keep the plain settle, because a panel that wobbles every
            // time a session ticks would never hold still. Under Reduce Motion the
            // opening settles plainly too: the overshoot is the one part of it that
            // is there for character rather than to show where the panel came from.
            let opening = modeChanged && mode == .expanded && !still
            let closing = modeChanged && mode == .collapsed
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = opening ? 0.4 : closing ? Self.closeDuration : 0.22
                ctx.timingFunction = opening
                    ? CAMediaTimingFunction(controlPoints: 0.32, 1.22, 0.42, 1.0)
                    : closing
                    ? CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.2, 1.0)
                    : CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
                ctx.allowsImplicitAnimation = true
                self.panel.animator().setFrame(target, display: true)
            }, completionHandler: { [weak self] in
                // The window shadow is shaped from the rendered content; after an
                // animated resize it has to be recut or it keeps the old outline.
                self?.panel.invalidateShadow()
            })
            if modeChanged { content.fadeRowsIn(duration: 0.34) }
        } else {
            panel.setFrame(target, display: true)
            panel.invalidateShadow()
            panel.alphaValue = 1
        }
        content.alphaValue = 1
        panel.orderFront(nil)
        content.needsDisplay = true
    }
}

import Cocoa

/// When the island is on screen at all, and whether it is open: the pointer poll,
/// the hover dwell and grace timers, the peek that summons a hidden pill, and
/// the fade on the way out. Every other part of the controller asks `rebuild`;
/// only this file decides what it answers.
extension IslandController {
    /// The single source of hover truth, read from geometry eight times a second.
    /// The island is the pill and the notch strip above it; being anywhere on the
    /// open panel keeps it open. Two guards carry the whole interaction: opening
    /// needs a fresh arrival (a pointer parked at the top since forever doesn't
    /// mean "open"), and the dwell in hover() filters drive-bys. The pill's fixed
    /// width matters here too — edges that never move can't sweep across a
    /// stationary pointer and fake an arrival.
    ///
    /// It keeps running while the pill is hidden, because that is how a hidden pill
    /// comes back: the same fresh arrival in the notch strip that would open a
    /// visible one first summons it (`peeking`), and if the pointer stays, the dwell
    /// opens it as usual. A pointer parked up there while the pill went away is not
    /// an arrival and summons nothing. Only the strip counts while hidden — the
    /// panel's frame is wherever the pill last was, and nothing is drawn there.
    func checkPointer() {
        guard Presentation.current.showsIsland, let screen = IslandGeometry.screen else { return }
        // Away is read here and nowhere else on a clock: the poll is already running,
        // and coming back has to be felt on the first touch, not on the next store
        // tick — which, with every session quiet, may never come.
        let hideWhenAway = IslandVisibility.Prefs.hideWhenAway
        let nowAway = IslandVisibility.away(hideWhenAway: hideWhenAway,
                                            idleSeconds: hideWhenAway ? InputIdle.seconds() : 0)
        if nowAway != away {
            away = nowAway
            rebuild(animated: true)
        }
        guard flash == nil else { personality.rest(); return }
        let shown = panel.isVisible && !hiding
        let mouse = NSEvent.mouseLocation
        // The eyes ride this same poll rather than a loop of their own, and only
        // look from a pill that is on screen and showing its mark.
        let looking = shown && mode == .collapsed && !hidden
        if personality.look(pointer: mouse, from: looking ? pill.markCenterOnScreen : nil),
           mode == .collapsed {
            pill.update(mark: personality.decorate(mark))
        }
        let inside = NSMouseInRect(mouse, IslandGeometry.hoverZone(on: screen), false)
            || (shown && NSMouseInRect(mouse, panel.frame, false))
        if !inside { lastAway = Date() }
        if inside != hovered {
            if inside, mode == .collapsed, Date().timeIntervalSince(lastAway) > 1.0 { return }
            hover(inside)
        }
    }

    /// Opt-in, twice: with nothing running, or with nobody at the keyboard, the pill
    /// slips away entirely. The decision itself is `IslandVisibility`'s; this only
    /// gathers what it is made from. Honoured in island-only mode too, now that a
    /// fresh arrival at the notch summons the pill back — before the peek, hiding the
    /// app's sole surface would have left Settings unreachable. A flash ("✓ Allowed"
    /// just as the last session ends) finishes before the exit, and a pending request
    /// keeps the pill up whatever the switches say.
    private var wantsHidden: Bool {
        let hideWhenAway = IslandVisibility.Prefs.hideWhenAway
        return !IslandVisibility.shows(.init(
            presentation: .current,
            hasSessions: !sessions.isEmpty,
            hasRequests: !requests.isEmpty,
            open: wantsExpanded || composing != nil || breakShown
                || UserDefaults.standard.bool(forKey: "islandExpandDebug"),
            flashing: flash != nil,
            peeking: peeking,
            hideWhenEmpty: IslandVisibility.Prefs.hideWhenEmpty,
            hideWhenAway: hideWhenAway,
            idleSeconds: hideWhenAway ? InputIdle.seconds() : 0))
    }

    func rebuild(animated: Bool = false) {
        // No fullscreen exception. Hiding there was in the plan and it was wrong:
        // a fullscreen terminal is where the agents actually run, so that is the one
        // place the island must not disappear from.
        guard Presentation.current.showsIsland, IslandGeometry.screen != nil,
              !wantsHidden
        else {
            // A hidden panel can't hear the pointer leave — clear the hover
            // intent the way stop() does, or the next un-hide opens expanded
            // on its own.
            expandWork?.cancel()
            collapseWork?.cancel()
            wantsExpanded = false
            hovered = false
            peeking = false
            // Open when the hide came — the pointer left a peek with nothing
            // running, which in island-only mode is the way to Settings, so it
            // happens every time. Fading the whole open slab where it stands
            // ghosts a panel-sized shape over the screen; fold it into the pill
            // first, the way it always closes, and leave from there.
            let fold = animated && panel.isVisible && !hiding && lastLaidMode == .expanded
            if fold {
                mode = .collapsed
                panel.ignoresMouseEvents = true
                layout(animated: true)
            }
            hidden = true
            hide(animated: animated, after: fold ? Self.closeDuration : 0)
            return
        }
        hidden = false

        // Only the pointer opens the panel. Even a pending approval stays a pill —
        // an island that unfolds over the screen on its own is in the way, which is
        // the opposite of the point. The pill says what is waiting; hovering acts.
        // (`islandExpandDebug` holds it open, for screenshots and layout work.)
        let held = UserDefaults.standard.bool(forKey: "islandExpandDebug")
        mode = (wantsExpanded || held || composing != nil || breakShown) ? .expanded : .collapsed
        // The collapsed pill is click-through: it floats over whatever the frontmost
        // window keeps at its top edge (tab strips, toolbars), and a pill that eats
        // those clicks is worse than no pill. Only the open panel takes the mouse.
        panel.ignoresMouseEvents = mode == .collapsed && !held
        layout(animated: animated)
    }

    func hover(_ inside: Bool) {
        hovered = inside
        collapseWork?.cancel()
        expandWork?.cancel()
        if inside {
            // A hidden pill answers the arrival first: back on screen now, so the
            // pointer has something to dwell on; the dwell below opens it as usual.
            if !peeking {
                let wasHidden = hidden
                peeking = true
                if wasHidden { rebuild(animated: true) }
            }
            // Hover intent, not hover: the pill sits where window title bars get
            // clicked and where a Cmd-Tab flick crosses, and a panel that unfolds
            // for every drive-by looks like a bug. A short dwell filters those out
            // without being felt by anyone who actually aims at it.
            guard !wantsExpanded else { return }
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.hovered else { return }
                self.wantsExpanded = true
                self.rebuild(animated: true)
            }
            expandWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
            return
        }
        // A moment's grace on the way out, so crossing a gap between subviews — or
        // the panel shrinking out from under the pointer — doesn't snap it shut.
        let work = DispatchWorkItem { [weak self] in
            // A note half typed is not abandoned by the pointer drifting off.
            guard let self, !self.hovered, self.composing == nil, !self.breakShown else { return }
            self.wantsExpanded = false
            self.peeking = false
            self.rebuild(animated: true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

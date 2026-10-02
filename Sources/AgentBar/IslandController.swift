import Cocoa

/// The island surface: a small pill under the notch that says what the agents are
/// doing, and opens into the full session list — with the pending approval
/// answerable in place — when the user puts the pointer on it. It only ever grows
/// on purpose; nothing unfolds over the screen on its own.
final class IslandController: NSObject {
    /// The pill is on screen by default — it is the app's presence, the way the menu
    /// bar mark is. With nothing running it is just the mark; work adds a line of
    /// text. Two opt-in switches can send it away (`IslandVisibility`); the pointer
    /// can always bring it back.
    private enum Mode {
        case collapsed
        case expanded
    }

    private let panel = IslandPanel()
    private let content = IslandContentView()
    private let pill = IslandPillView()
    private let mascot: MascotDriver
    /// The island's own touches on the mascot — gaze, pokes, the finish sparkle.
    /// Fed from here and drawn only here; the menu bar never sees them.
    private let personality = IslandMascot()

    private var sessions: [Session] = []
    private var requests: [ApprovalRequest] = []
    private var mode: Mode = .collapsed
    private var hovered = false
    /// The debounced intent behind `mode`. Only the dwell and grace timers (and an
    /// answer) may flip this — `rebuild` runs on every store tick, roughly once a
    /// second while an agent works, and deciding the shape from the instantaneous
    /// hover state there bypassed both timers: a pointer grazing an edge snapped
    /// the panel open and shut in rhythm with the ticks.
    private var wantsExpanded = false
    private var tracking: NSTrackingArea?
    private var collapseWork: DispatchWorkItem?
    private var expandWork: DispatchWorkItem?
    private var flashWork: DispatchWorkItem?
    /// The pointer poll that owns hover truth. Tracking-area events can't: while
    /// collapsed the panel is click-through (no events at all), and a Space switch
    /// slides the panel under a pointer without ever crossing an edge.
    private var pointerTimer: Timer?
    /// Slow refresh of an open panel so elapsed labels keep counting.
    private var elapsedTimer: Timer?
    /// Last moment the pointer was seen away from the island. Opening requires a
    /// fresh *arrival* — a pointer parked at the top of the screen to be out of
    /// the way must not open anything, no matter how long it sits there. Starts
    /// in the distant past so a pointer already lying there when the app launches
    /// counts as parked, not as arriving.
    private var lastAway = Date.distantPast
    /// A just-given answer, echoed in the pill for a beat — "✓ Allowed" — before
    /// the island goes back to reporting.
    private var flash: (text: String, tint: NSColor)?
    /// What the last layout pass drew, so a mode change can animate differently
    /// from a same-shape refresh.
    private var lastLaidMode: Mode?
    /// The request whose card has its note field open, if any. While set, the
    /// panel takes keys, stays open when the pointer leaves, and does not re-set its
    /// rows: `setRows` detaches every view, and a detached field loses its caret and
    /// whatever was half typed into it.
    private var composing: String?
    /// The app that had the keyboard when a note was opened.
    private var keysCameFrom: NSRunningApplication?
    /// A fresh arrival at the notch asked for the pill while it was hidden. Set with
    /// the hover, cleared only by the grace timer on the way out — the same timer
    /// that closes an open panel — so a pointer crossing a gap doesn't make the pill
    /// blink, and the exit is exactly as forgiving as the collapse.
    private var peeking = false
    /// The last answer to "is the user away", as the pointer poll saw it. Only its
    /// changes matter: they are what tells the island to re-evaluate, because with
    /// every session quiet nothing else would tick.
    private var away = false
    /// What `rebuild` last decided. `layout` has callers that are not `rebuild` — the
    /// mascot's rotating verb, above all — and before this every one of them ended
    /// in `orderFront`, which would pull a hidden pill straight back on screen.
    private var hidden = false
    /// A fade-out is running. The panel is still visible, so this is the only way to
    /// tell a pill on its way out from one that is staying.
    private var hiding = false
    /// Bumped by every show and hide, so a fade-out that finishes after the pill was
    /// asked back can tell it has been overtaken and leave the panel on screen.
    private var visibilityTurn = 0

    private static let expandedWidth: CGFloat = 460
    /// Deliberately small. The collapsed island is a glance, not a panel — anything
    /// taller starts covering the screen for no gain.
    private static let pillHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 8
    /// Beyond this the panel would run down the screen; the rest are summarised.
    private static let maxRows = 6
    /// How far the pill rises into the notch as it fades away, and drops out of it
    /// coming back. A few points is enough to read as *going somewhere* rather than
    /// switching off; under a real notch the top of the travel is hidden anyway.
    private static let hideSlide: CGFloat = 6
    /// How long the open panel takes to fold back into the pill — `layout`'s
    /// closing pass, and what `hide` waits out when it has to fold first.
    private static let closeDuration: TimeInterval = 0.3

    /// Read fresh on every hide and every layout, the way `IslandMascot.plays` is:
    /// the user can flip it in System Settings while the pill is up, and the next
    /// move should already respect it.
    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    init(mascot: MascotDriver) {
        self.mascot = mascot
        super.init()
        panel.contentView = content
        content.autoresizingMask = [.width, .height]
        // The ears (`IslandShape`) are measured from the pill's height up, so the
        // pill itself never has any — see `layout` for why it must not.
        content.earWidth = IslandShape.earWidth
        content.collapsedHeight = Self.pillHeight
        content.onHover = { [weak self] inside in
            guard let self else { return }
            // Leaving the panel upward into the notch strip is still "on the
            // island" — the poll owns that zone; only real departures count.
            if !inside, let screen = IslandGeometry.screen,
               NSMouseInRect(NSEvent.mouseLocation, IslandGeometry.hoverZone(on: screen), false) {
                return
            }
            self.hover(inside)
        }
        // The panel is always dark, whatever the system is set to. Without this the
        // reused approval strip and mini-diff render for a light background and go
        // nearly invisible on it.
        panel.appearance = NSAppearance(named: .darkAqua)
    }

    func start() {
        // Here rather than at launch: the switch only ever did nothing in
        // island-only mode, so the question is asked the first time the island is
        // actually up, in whichever mode that is.
        IslandVisibility.Prefs.migrate(presentation: .current)
        // Switching desktop or plugging a display changes where the panel belongs,
        // and nothing session-side would trigger a re-layout.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(surroundingsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        pointerTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) {
            [weak self] _ in self?.checkPointer()
        }
        // Elapsed labels ("28m") are computed at row build; with the panel held
        // open over quiet sessions nothing else would rebuild them, so a slow
        // tick keeps the numbers honest. Collapsed panels skip it — the pill
        // carries no elapsed and the store's own ticks cover everything else.
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.mode == .expanded, self.flash == nil else { return }
            self.layout(animated: false)
        }
        mascot.sink("island") { [weak self] image, word in
            guard let self else { return }
            let textChanged = word != self.word
            self.mark = image
            self.word = word
            guard self.mode == .collapsed else { return }
            // A sprite frame is not a layout change. Re-running the whole pass here
            // rebuilt the row and resized the panel ~12×/s, which is what made the
            // mascot look frozen; only the width can actually need revisiting.
            // While a flash is up the pill isn't the mascot's — leave it alone.
            if textChanged { self.layout(animated: true) }
            else if self.flash == nil { self.pill.update(mark: self.personality.decorate(image)) }
        }
        rebuild()
        // The hello, once the pill has dropped out of the notch and settled. The
        // pill as it is at that moment decides, once for the whole launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.sayHello() }
    }

    /// Clawd waves from the pill — opt-in personality only, never with Reduce
    /// Motion, and only from a pill that is up, collapsed and his. It changes the
    /// mark and nothing else: no sound, nothing opens, the pill stays click-through.
    private func sayHello() {
        personality.greet(pillVisible: panel.isVisible && !hiding && !hidden,
                          collapsed: mode == .collapsed, flashing: flash != nil,
                          mark: mark) { [weak self] in
            guard let self, self.mode == .collapsed, self.flash == nil, !self.hidden else { return }
            self.pill.update(mark: self.personality.decorate(self.mark))
        }
    }

    private var mark: NSImage?
    private var word = ""

    /// What the pill says. The panel no longer opens by itself, so the pill is the
    /// only thing a waiting session gets to say — it has to name the wait, not just
    /// animate. Otherwise it's Claude's rotating verb, as in the menu bar.
    ///
    /// Kept short on purpose: the pill has to stay narrower than the notch to read as
    /// part of it, and "needs approval" was already wider than that.
    private var pillText: String {
        if let flash { return flash.text }
        switch visibleSessions.first?.state {
        case .permission: return "approve?"
        case .question:   return "answer?"
        case .error:      return "failed"
        default:          return word.isEmpty ? "" : "\(word)…"
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        pointerTimer?.invalidate()
        pointerTimer = nil
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        mascot.sink("island", nil)
        personality.endGreeting()
        expandWork?.cancel()
        collapseWork?.cancel()
        wantsExpanded = false
        hovered = false
        peeking = false
        visibilityTurn += 1
        hiding = false
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// The Space or the displays changed. Rebuild now for the common case, and once
    /// more after the transition settles — the notification lands while the incoming
    /// windows are still animating into place, so an immediate look can still see
    /// the old shape. (The pointer poll corrects any stale hover on its own tick.)
    @objc private func surroundingsChanged() {
        rebuild()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in self?.rebuild() }
    }

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
    private func checkPointer() {
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

    func apply(sessions: [Session], requests: [ApprovalRequest]) {
        self.sessions = sessions
        self.requests = requests
        // Half-made choices die with their request (answered in the terminal,
        // timed out, hook gone) — a later request must start clean. A request
        // REPLACED under the same file name (prompt ids repeat within a turn)
        // counts as gone too: its ts changed, and choices made on the old shape
        // must not answer the new one.
        let live = Set(requests.map(\.fileName))
        for r in requests where requestIdentity[r.fileName] != r.identity {
            requestIdentity[r.fileName] = r.identity
            questionSelections[r.fileName] = nil
            questionSteps[r.fileName] = nil
            approvalCards[r.fileName] = nil
        }
        requestIdentity = requestIdentity.filter { live.contains($0.key) }
        questionSelections = questionSelections.filter { live.contains($0.key) }
        questionSteps = questionSteps.filter { live.contains($0.key) }
        approvalCards = approvalCards.filter { live.contains($0.key) }
        // Answered in the terminal, timed out, or replaced under the same name while
        // a note was being typed: the note has nothing left to go with.
        if let c = composing, requestIdentity[c] == nil || approvalCards[c] == nil {
            endComposing()
        }
        let celebrate = personality.observe(sessions)
        rebuild(animated: true)
        // Inside the pill or not at all: an open panel, a flash or a pill on its
        // way out lets the finish pass unmarked.
        if celebrate, mode == .collapsed, flash == nil, !hidden, panel.isVisible, !hiding {
            pill.celebrate()
        }
    }

    // MARK: - State

    /// The same set the menu lists — a finished session stays until its process
    /// dies or the store prunes it — but ordered for a panel: whatever needs the
    /// user first, then the working, then the finished. Stable within each group,
    /// so rows don't trade places on every poll.
    private var visibleSessions: [Session] {
        sessions.enumerated().sorted { a, b in
            a.1.priority != b.1.priority ? a.1.priority > b.1.priority : a.0 < b.0
        }.map(\.1)
    }

    /// A Settings control changed something the island renders from
    /// (hide-when-empty, most likely) — re-evaluate now, not on the next tick.
    /// Cached approval cards bake shortcut hints in, so they rebuild too.
    func settingsChanged() {
        // Every card but the one with a note being typed in it: that one is on
        // screen, held still, and throwing it away would lose the note.
        approvalCards = approvalCards.filter { $0.key == composing }
        rebuild(animated: true)
    }

    /// The quota line moved. It is read fresh on every layout, so this only
    /// needs a re-render — emphatically NOT a card rebuild: the token count
    /// ticks up every minute, and dropping the cards with it would reset a
    /// plan the user is halfway through reading.
    func usageChanged() { rebuild(animated: false) }

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
            open: wantsExpanded || composing != nil
                || UserDefaults.standard.bool(forKey: "islandExpandDebug"),
            flashing: flash != nil,
            peeking: peeking,
            hideWhenEmpty: IslandVisibility.Prefs.hideWhenEmpty,
            hideWhenAway: hideWhenAway,
            idleSeconds: hideWhenAway ? InputIdle.seconds() : 0))
    }

    private func rebuild(animated: Bool = false) {
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
        mode = (wantsExpanded || held || composing != nil) ? .expanded : .collapsed
        // The collapsed pill is click-through: it floats over whatever the frontmost
        // window keeps at its top edge (tab strips, toolbars), and a pill that eats
        // those clicks is worse than no pill. Only the open panel takes the mouse.
        panel.ignoresMouseEvents = mode == .collapsed && !held
        layout(animated: animated)
    }

    // MARK: - Layout

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
    private func hide(animated: Bool, after delay: TimeInterval = 0) {
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

    private func layout(animated: Bool = false, force: Bool = false) {
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

    private func rows() -> [NSView] {
        var out: [NSView] = []
        let visible = visibleSessions
        let rowW = Self.expandedWidth - IslandContentView.hPad * 2
        for (i, s) in visible.prefix(Self.maxRows).enumerated() {
            // The list leads with whatever needs the user, so the first row is the
            // hero — boxed, with the mark; the rest stay one quiet line each.
            let style: IslandRowView.Style = i == 0 ? .hero : .compact
            let mark = IconRenderer.shared.sprite(for: s.agent).restingColor
            let row = IslandRowView(session: s, mark: mark, style: style) { [weak self] session in
                self?.click(session)
            }
            personality.attach(row.mascot, session: s.id)
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: rowW).isActive = true
            out.append(row)
            out.append(contentsOf: approvalViews(for: s))
            if let q = questionView(for: s) { out.append(q) }
        }
        if visible.count > Self.maxRows {
            out.append(more(visible.count - Self.maxRows))
        }
        if visible.isEmpty { out.append(emptyRow(width: rowW)) }
        return out
    }

    /// Cards sit under their session, indented just enough to read as belonging
    /// to it rather than to the panel.
    private static let cardIndent: CGFloat = 12

    private func card(_ view: NSView) -> NSView {
        let wrapper = NSStackView(views: [view])
        wrapper.orientation = .horizontal
        wrapper.edgeInsets = NSEdgeInsets(top: 0, left: Self.cardIndent, bottom: 0, right: 0)
        return wrapper
    }

    private func deferTitle(for s: Session, plan: Bool = false) -> String {
        let verb = plan ? "Review" : "Answer"
        return s.entrypoint == "claude-desktop" ? "\(verb) in Claude" : "\(verb) in terminal"
    }

    /// One approval card per request, cached for the request's lifetime: the
    /// rows rebuild every store tick, and recreating a content-static card each
    /// time reset the plan box's inner scroll mid-read.
    private var approvalCards: [String: NSView] = [:]

    /// The pending request's own detail and buttons — same mini-diff the menu
    /// shows, Deny and Allow in front, the answer echoed in the pill on the way out.
    private func approvalViews(for s: Session) -> [NSView] {
        guard s.state == .permission else { return [] }
        let mine = requests.filter { $0.sessionId == s.id }
        var out: [NSView] = []
        for r in mine {
            if let cached = approvalCards[r.fileName] {
                out.append(cached)
                continue
            }
            let view = card(IslandApprovalView(
                request: r,
                deferTitle: deferTitle(for: s, plan: r.isPlanRequest),
                // The repo the count is scoped to: the same command is routine in
                // one checkout and the opposite in another.
                cwd: s.cwd,
                width: Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent,
                onChoose: { [weak self] behavior in
                // "rule" is not an answer to this request — it opens the sheet and
                // leaves the card pending. Handled before the answer path so a
                // dropped-answer beep can never fire for a click that answered
                // nothing on purpose.
                if behavior == "rule" {
                    SettingsWindow.shared.addRule(from: RuleSheet.Prefill(
                        decision: DecisionLedger.shouldOfferRule(
                            DecisionLedger.summary(shape: DecisionLedger.shape(of: r),
                                                   cwd: s.cwd, in: DecisionLedger.cached())) ?? "allow",
                        shape: DecisionLedger.shape(of: r),
                        cwd: r.cwd.isEmpty ? s.cwd : r.cwd,
                        display: r.display))
                    return
                }
                // Only confirm what actually reached disk: a dropped answer leaves the
                // request pending, and a "✓ Allowed" flash would be a lie.
                guard AgentActions.answer(ApprovalAction(request: r, behavior: behavior, session: s))
                else { return }
                self?.flashAnswer(behavior, plan: r.isPlanRequest)
            }, onDenyNote: { [weak self] text in
                guard let self else { return }
                self.endComposing(relayout: false)
                let noted = DenyNote.clean(text) != nil
                guard AgentActions.answer(ApprovalAction(request: r, behavior: "deny", session: s,
                                                         note: text))
                else { self.rebuild(animated: true); return }
                self.flashAnswer(noted ? "denyNote" : "deny", plan: r.isPlanRequest)
            }, onCompose: { [weak self] on in
                guard let self else { return }
                if on { self.beginComposing(r.fileName) } else { self.endComposing() }
            }))
            approvalCards[r.fileName] = view
            out.append(view)
        }
        return out
    }

    /// Selections and the wizard step per pending question request, keyed by the
    /// request file name. They live here, not in the card: the island rebuilds its
    /// rows on every store tick, so view state would be torn down mid-choice.
    private var questionSelections: [String: [Set<Int>]] = [:]
    private var questionSteps: [String: Int] = [:]
    /// What each keyed request WAS when its state was created — the tell that a
    /// same-named file now holds a different request.
    private var requestIdentity: [String: String] = [:]

    /// The question card under a session that asked one. When the hook carried the
    /// options, the card is answerable in place; otherwise it names the question
    /// and hands over in one click.
    private func questionView(for s: Session) -> NSView? {
        guard s.state == .question else { return nil }
        let width = Self.expandedWidth - IslandContentView.hPad * 2 - Self.cardIndent
        if let r = requests.first(where: { $0.sessionId == s.id }), let qs = r.questions {
            return card(IslandQuestionCardView(
                questions: qs,
                selections: questionSelections[r.fileName] ?? [],
                step: questionSteps[r.fileName] ?? 0,
                deferTitle: deferTitle(for: s),
                width: width,
                onAnswer: { [weak self] labels in
                    guard AgentActions.answerQuestion(labels, request: r) else { return }
                    self?.questionSelections[r.fileName] = nil
                    self?.questionSteps[r.fileName] = nil
                    self?.flashAnswer("answer")
                },
                onSelect: { [weak self] selections in
                    self?.questionSelections[r.fileName] = selections
                },
                onStep: { [weak self] step in
                    guard let self else { return }
                    self.questionSteps[r.fileName] = step
                    // The next question replaces this one in place; the panel
                    // resizes to fit it.
                    self.layout(animated: true)
                },
                onDefer: { [weak self] in
                    guard let self else { return }
                    self.questionSelections[r.fileName] = nil
                    self.questionSteps[r.fileName] = nil
                    AgentActions.focus(s, requests: self.requests)
                }))
        }
        var q = s.label
        if q.hasPrefix("❓") { q.removeFirst(); q = q.trimmingCharacters(in: .whitespaces) }
        if q.isEmpty { q = "\(s.agent.name) has a question" }
        return card(IslandQuestionView(
            question: q,
            deferTitle: deferTitle(for: s),
            width: width
        ) { [weak self] in
            guard let self else { return }
            AgentActions.focus(s, requests: self.requests)
        })
    }

    /// Echo the choice in the pill — "✓ Allowed" — for a beat, then go back to
    /// reporting. Defer skips the flash: the hand-off itself is the feedback.
    private func flashAnswer(_ behavior: String, plan: Bool = false) {
        wantsExpanded = false
        collapseWork?.cancel()
        expandWork?.cancel()
        let green = NSColor(srgbRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
        switch behavior {
        // Honest tense for plans: what went out is the dialog keystroke, and
        // the session's own dialog has the last word.
        case "allow":  flash = (plan ? "Approving plan…" : "✓ Allowed", green)
        case "always": flash = ("✓ Always allowed", green)
        case "answer": flash = ("✓ Answered", green)
        case "deny" where plan:
            // Sending a plan back is a neutral outcome, not a refusal.
            flash = ("✎ Planning on", NSColor.white.withAlphaComponent(0.85))
        case "denyNote" where plan:
            flash = ("✎ Sent back", NSColor.white.withAlphaComponent(0.85))
        case "deny":   flash = ("✕ Denied", NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
        // Still a refusal, but one that told the agent where to go instead.
        case "denyNote": flash = ("✕ Denied · told it", NSColor(srgbRed: 1, green: 0.45, blue: 0.42, alpha: 1))
        default:       flash = nil
        }
        rebuild(animated: true)
        guard flash != nil else { return }
        flashWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.flash = nil
            self.rebuild(animated: true)
        }
        flashWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    private func more(_ n: Int) -> NSView {
        let l = NSTextField(labelWithString: "+\(n) more session\(n == 1 ? "" : "s")")
        l.font = .systemFont(ofSize: 11)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        return l
    }

    private func emptyRow(width: CGFloat) -> NSView {
        let firstRun = EmptyState.firstRun
        let l = NSTextField(labelWithString: EmptyState.title(firstRun: firstRun))
        l.font = .systemFont(ofSize: 12)
        l.textColor = NSColor.white.withAlphaComponent(0.45)
        guard let hint = EmptyState.hint(firstRun: firstRun) else { return l }
        let h = NSTextField(wrappingLabelWithString: hint)
        h.font = .systemFont(ofSize: 11)
        h.textColor = NSColor.white.withAlphaComponent(0.35)
        h.preferredMaxLayoutWidth = width
        let stack = NSStackView(views: [l, h])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// In Island-only mode the menu bar mark is gone, so the panel carries the way
    /// into Settings, updates and Quit itself. The provider quota line rides
    /// along on the left — a glance, not a dashboard.
    private func footer() -> NSView {
        let row = footerRow()
        guard let strip = todayStrip() else { return row }
        // A vertical pair rather than a taller single row: `setFooter` measures what
        // it is handed (`fittingSize`) and `contentHeight` already carries the result,
        // so the panel grows by exactly the strip and nothing else moves.
        let stack = NSStackView(views: [strip, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    /// Cached on what it is drawn from. `footer()` runs on every rebuild — about once
    /// a second while an agent works — and the day only changes when a session ends.
    private var todayStripCache: (signature: String, view: TodayStripView)?

    private func todayStrip() -> TodayStripView? {
        // Both halves off unless asked for in Appearance — the panel's whole argument
        // is that it stays small, and the same numbers are a click away under ⋯ and in
        // `agentbar history`. See TodayStripView for why they switch on separately.
        guard TodayStripView.enabled else { todayStripCache = nil; return nil }
        let (summary, entries) = HistoryDigest.today(HistoryStore.cached())
        guard !summary.isEmpty else { todayStripCache = nil; return nil }
        let signature = TodayStripView.signature(summary, entries)
        if let cache = todayStripCache, cache.signature == signature {
            // A view can only live in one place: `setRows`/`setFooter` tear the old
            // hierarchy down, so the cached one has to be lifted out before reuse.
            cache.view.removeFromSuperview()
            return cache.view
        }
        let view = TodayStripView(summary: summary, entries: entries,
                                  width: Self.expandedWidth - IslandContentView.hPad * 2)
        todayStripCache = (signature, view)
        return view
    }

    private func footerRow() -> NSView {
        let dots = NSButton(title: "⋯", target: self, action: #selector(showMenu(_:)))
        dots.isBordered = false
        dots.font = .systemFont(ofSize: 15, weight: .semibold)
        dots.contentTintColor = NSColor.white.withAlphaComponent(0.55)
        dots.toolTip = "AgentBar"

        var views: [NSView] = []
        // The same line the footer always spent on quota, drawn instead of
        // written: a meter reads at a glance and a sentence does not, and at this
        // size they cost the same height. The full numbers stay one tooltip and
        // one ⋯ away — which is also what makes it fair to show only the
        // providers actually in use here. See `UsageCenter.relevant`.
        let all = UsageCenter.shared.readings
        let active = Set(sessions.compactMap { UsageCenter.provider(forAgent: $0.agentID) })
        let shown = UsageCenter.relevant(all, active: active,
                                         lastUsed: active.isEmpty ? lastUsedProvider() : nil)
        if let meters = UsageMeterView(readings: shown, style: .islandFooter,
                                       tooltipReadings: all) {
            meters.translatesAutoresizingMaskIntoConstraints = false
            meters.heightAnchor.constraint(equalToConstant: meters.frame.height).isActive = true
            // Exactly its own width, and the spacer takes the rest. Both used to
            // hug at the same priority, which left the solver free to decide
            // between them — and when it decided against the line, the line got
            // no width and the quota vanished off the island.
            meters.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            // It must never squeeze the ⋯ button out; it truncates instead.
            meters.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            views.append(meters)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        views.append(dots)
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant:
            Self.expandedWidth - IslandContentView.hPad * 2).isActive = true
        return row
    }

    /// The provider of the last session that ended, so the quota line has
    /// something to keep showing when nothing is running. Only asked for when
    /// nothing is — the history is memoised, but the scan is not free.
    private func lastUsedProvider() -> String? {
        // One pass, not a sort: the newest record that belongs to a provider,
        // which is rarely the newest record.
        var best: (at: TimeInterval, provider: String)?
        for r in HistoryStore.cached() {
            guard let provider = UsageCenter.provider(forAgent: r.agent),
                  r.endedAt > (best?.at ?? 0) else { continue }
            best = (r.endedAt, provider)
        }
        return best?.provider
    }

    // MARK: - Interaction

    // MARK: - A note being typed

    private func beginComposing(_ fileName: String) {
        // One note at a time: opening a second card's field closes the first.
        if let other = composing, other != fileName,
           let card = approvalCards[other].flatMap(Self.approvalView(in:)) {
            card.setComposing(false, notify: false)
        }
        composing = fileName
        let front = NSWorkspace.shared.frontmostApplication
        keysCameFrom = front?.processIdentifier == getpid() ? nil : front
        collapseWork?.cancel()
        panel.acceptsKeys = true
        // One last layout with the note row showing, so the panel grows to it —
        // then rows hold still until the note is done.
        layout(animated: true, force: true)
        panel.makeKey()
    }

    private func endComposing(relayout: Bool = true) {
        guard let c = composing else { return }
        composing = nil
        if let card = approvalCards[c].flatMap(Self.approvalView(in:)), card.composing {
            card.setComposing(false, notify: false)
        }
        panel.makeFirstResponder(nil)
        panel.acceptsKeys = false
        panel.resignKey()
        // Open exactly as far as the pointer says: it may have left long ago (the
        // grace timer was held off while typing), or still be on the panel after
        // an answer elsewhere asked it to close. A peek ends the same way.
        wantsExpanded = hovered
        peeking = hovered
        // Keys go back to the app that had them. The panel never activated this
        // app, so that app is still frontmost; activating it again is what hands
        // the key window back rather than leaving keys addressed to the island.
        if let app = keysCameFrom, !app.isTerminated { app.activate() }
        keysCameFrom = nil
        if relayout { rebuild(animated: true) }
    }

    /// Cards are cached wrapped in their indent; the approval view is inside.
    private static func approvalView(in wrapper: NSView) -> IslandApprovalView? {
        (wrapper as? NSStackView)?.arrangedSubviews.first as? IslandApprovalView
    }

    private func hover(_ inside: Bool) {
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
            guard let self, !self.hovered, self.composing == nil else { return }
            self.wantsExpanded = false
            self.peeking = false
            self.rebuild(animated: true)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func click(_ s: Session) {
        AgentActions.focus(s, requests: requests)
    }

    @objc private func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // In island-only mode this is the only menu there is, so the day's digest
        // has to be reachable from it — otherwise the feature exists for menu bar
        // users and nobody else.
        menu.addItem(MenuBuilder.todayRow(target: self, action: #selector(openPastProject(_:))))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Appearance…", action: #selector(openWelcome), keyEquivalent: "")
        // In Island-only mode this menu is the only menu — the colour choice the
        // status item dropdown offers has to be reachable here too.
        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (title, system) in [("Color", false), ("System", true)] {
            let item = NSMenuItem(title: title, action: #selector(chooseColor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = system
            item.state = IconColor.system == system ? .on : .off
            colorSub.addItem(item)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)
        // One-click mute/unmute; volume and the cue details live in Settings.
        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.state = SoundCenter.enabled ? .on : .off
        menu.addItem(sounds)
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AgentBar", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func chooseColor(_ sender: NSMenuItem) {
        IconColor.system = (sender.representedObject as? Bool) ?? false
    }

    @objc private func toggleSounds() {
        SoundCenter.enabled.toggle()
        if SoundCenter.enabled { SoundCenter.shared.preview() }
        SettingsWindow.shared.refreshIfVisible()
    }

    /// A finished session's project folder — the session itself is gone, so there is
    /// no tab to jump back to. Mirrors `StatusItemController.openPastProject`.
    @objc private func openPastProject(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }

    @objc private func openWelcome() { WelcomeWindow.shared.show() }
    @objc private func openSettings() { SettingsWindow.shared.show() }
    @objc private func checkUpdates() { UpdateChecker.shared.check(manual: true) }
}

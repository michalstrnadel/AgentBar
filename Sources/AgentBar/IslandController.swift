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
    enum Mode {
        case collapsed
        case expanded
    }

    let panel = IslandPanel()
    let content = IslandContentView()
    let pill = IslandPillView()
    let mascot: MascotDriver
    /// The island's own touches on the mascot — gaze, pokes, the finish sparkle.
    /// Fed from here and drawn only here; the menu bar never sees them.
    let personality = IslandMascot()

    var sessions: [Session] = []
    var requests: [ApprovalRequest] = []
    var mode: Mode = .collapsed
    var hovered = false
    /// The debounced intent behind `mode`. Only the dwell and grace timers (and an
    /// answer) may flip this — `rebuild` runs on every store tick, roughly once a
    /// second while an agent works, and deciding the shape from the instantaneous
    /// hover state there bypassed both timers: a pointer grazing an edge snapped
    /// the panel open and shut in rhythm with the ticks.
    var wantsExpanded = false
    private var tracking: NSTrackingArea?
    var collapseWork: DispatchWorkItem?
    var expandWork: DispatchWorkItem?
    var flashWork: DispatchWorkItem?
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
    var lastAway = Date.distantPast
    /// A just-given answer, echoed in the pill for a beat — "✓ Allowed" — before
    /// the island goes back to reporting.
    var flash: (text: String, tint: NSColor)?
    /// What the last layout pass drew, so a mode change can animate differently
    /// from a same-shape refresh.
    var lastLaidMode: Mode?
    /// The request whose card has its note field open, if any. While set, the
    /// panel takes keys, stays open when the pointer leaves, and does not re-set its
    /// rows: `setRows` detaches every view, and a detached field loses its caret and
    /// whatever was half typed into it.
    var composing: String?
    /// The app that had the keyboard when a note was opened.
    var keysCameFrom: NSRunningApplication?
    /// Take a break (`IslandController+Game`): the game, while there is one — on
    /// screen, or put aside because work came in — and whether it is on screen now.
    /// On screen it is held like a note being typed: open, keyed, rows frozen.
    var breakGame: BreakGameView?
    var breakShown = false
    var breakWaiting: Set<String> = []
    var breakSuspendedAt: Date?
    var breakKeyWatch: NSObjectProtocol?
    /// A fresh arrival at the notch asked for the pill while it was hidden. Set with
    /// the hover, cleared only by the grace timer on the way out — the same timer
    /// that closes an open panel — so a pointer crossing a gap doesn't make the pill
    /// blink, and the exit is exactly as forgiving as the collapse.
    var peeking = false
    /// The last answer to "is the user away", as the pointer poll saw it. Only its
    /// changes matter: they are what tells the island to re-evaluate, because with
    /// every session quiet nothing else would tick.
    var away = false
    /// What `rebuild` last decided. `layout` has callers that are not `rebuild` — the
    /// mascot's rotating verb, above all — and before this every one of them ended
    /// in `orderFront`, which would pull a hidden pill straight back on screen.
    var hidden = false
    /// A fade-out is running. The panel is still visible, so this is the only way to
    /// tell a pill on its way out from one that is staying.
    var hiding = false
    /// Bumped by every show and hide, so a fade-out that finishes after the pill was
    /// asked back can tell it has been overtaken and leave the panel on screen.
    var visibilityTurn = 0

    /// One approval card per request, cached for the request's lifetime: the
    /// rows rebuild every store tick, and recreating a content-static card each
    /// time reset the plan box's inner scroll mid-read.
    var approvalCards: [String: NSView] = [:]

    /// Selections and the wizard step per pending question request, keyed by the
    /// request file name. They live here, not in the card: the island rebuilds its
    /// rows on every store tick, so view state would be torn down mid-choice.
    var questionSelections: [String: [Set<Int>]] = [:]
    var questionSteps: [String: Int] = [:]
    /// What each keyed request WAS when its state was created — the tell that a
    /// same-named file now holds a different request.
    private var requestIdentity: [String: String] = [:]

    /// Cached on what it is drawn from. `footer()` runs on every rebuild — about once
    /// a second while an agent works — and the day only changes when a session ends.
    var todayStripCache: (signature: String, view: TodayStripView)?

    var mark: NSImage?
    var word = ""

    static let expandedWidth: CGFloat = 460
    /// Deliberately small. The collapsed island is a glance, not a panel — anything
    /// taller starts covering the screen for no gain.
    static let pillHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 8
    /// Beyond this the panel would run down the screen; the rest are summarised.
    static let maxRows = 6
    /// How far the pill rises into the notch as it fades away, and drops out of it
    /// coming back. A few points is enough to read as *going somewhere* rather than
    /// switching off; under a real notch the top of the travel is hidden anyway.
    static let hideSlide: CGFloat = 6
    /// How long the open panel takes to fold back into the pill — `layout`'s
    /// closing pass, and what `hide` waits out when it has to fold first.
    static let closeDuration: TimeInterval = 0.3

    /// Read fresh on every hide and every layout, the way `IslandMascot.plays` is:
    /// the user can flip it in System Settings while the pill is up, and the next
    /// move should already respect it.
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

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
        // The game is a panel that pauses the instant it loses the keyboard, which is
        // what happens when you go to look at it. CONTRIBUTING lists it.
        if UserDefaults.standard.bool(forKey: "islandGameDebug") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.beginBreak() }
        }
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

    /// What the pill says. The panel no longer opens by itself, so the pill is the
    /// only thing a waiting session gets to say — it has to name the wait, not just
    /// animate. Otherwise it's Claude's rotating verb, as in the menu bar.
    ///
    /// Kept short on purpose: the pill has to stay narrower than the notch to read as
    /// part of it, and "needs approval" was already wider than that.
    var pillText: String {
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
        // Before the rebuild: a game that has to step aside should not be drawn once more.
        checkBreakYield()
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
    var visibleSessions: [Session] {
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
}

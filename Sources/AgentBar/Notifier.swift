import Cocoa
import UserNotifications

/// Native macOS notifications, with Allow and Deny on the banner itself.
///
/// This is a deliberate, narrow exception to rule 2 ("nothing that unfolds over
/// the screen on its own"), and it earns it twice over. It is **off by default and
/// stays off** until the user turns it on, like sounds — a status app must not
/// start interrupting people after an update. And the surface belongs to macOS:
/// AgentBar draws nothing of its own, it hands the system a banner and the system
/// decides where and whether to show it, under the user's own Focus rules.
///
/// What made it worth building was the display picker. Pin the island to one screen
/// and work on another and there is no longer anywhere a pending approval can
/// appear — the hole is new, and this is what fills it.
///
/// The buttons land in exactly the seam the menu, the island and the global hotkey
/// already use: `AgentActions.answer(ApprovalAction(...))`. No fourth code path.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Category ids. Actions are registered once, before anything is posted —
    /// a notification whose category has no registered actions shows no buttons.
    private static let approvalCategory = "agentbar.approval"
    private static let plainCategory = "agentbar.plain"
    private static let allowAction = "agentbar.allow"
    private static let denyAction = "agentbar.deny"
    /// Deny, with a line typed on the banner itself: what to do instead. The one
    /// thing a banner can carry besides a verb, and the reason it is worth having —
    /// a refusal that says why steers the agent rather than stopping it.
    private static let denyNoteAction = "agentbar.denyNote"

    /// Set by the app delegate so a tapped banner can find its request and session.
    var requests: (() -> [ApprovalRequest])?
    var sessions: (() -> [Session])?

    /// The previous tick, for edge detection — the same shape `SoundCenter` keeps.
    private var lastStates: [String: Session.State] = [:]
    private var primed = false
    /// Identifiers currently on screen, so they can be taken back down.
    private var deliveredRequests: Set<String> = []
    /// File name → the identity of the request its banner was posted for.
    private var deliveredIdentities: [String: String] = [:]
    /// The run of work currently in progress, or the one that just ended.
    private var burst = Burst()
    /// A banner is the whole point while the screen is locked, but the lock is also
    /// the strongest possible signal that nobody is watching the island.
    private var screenLocked = false
    private var quietTimer: Timer?

    // MARK: - Preferences

    /// Three switches, all off by default (`bool(forKey:)` gives false), owned here
    /// rather than as string literals because Settings and this class both read them.
    ///
    /// Each one answers a different question, and none of them is "an agent did
    /// something". 1.17.0 shipped a switch called *When an agent finishes* that fired
    /// on `state == .done`, which Claude Code enters at the end of **every turn** — a
    /// fifty-turn conversation posted fifty banners. What earns a banner is wanting
    /// an answer, failing, or finishing while nobody was there to see it.
    enum Prefs {
        static var approvals: Bool {
            get { UserDefaults.standard.bool(forKey: "notifyApprovals") }
            set { UserDefaults.standard.set(newValue, forKey: "notifyApprovals") }
        }
        static var failures: Bool {
            get { UserDefaults.standard.bool(forKey: "notifyFailures") }
            set { UserDefaults.standard.set(newValue, forKey: "notifyFailures") }
        }
        static var quiet: Bool {
            get { UserDefaults.standard.bool(forKey: "notifyQuiet") }
            set { UserDefaults.standard.set(newValue, forKey: "notifyQuiet") }
        }
        static var anyEnabled: Bool { approvals || failures || quiet }

        /// `notifyDone` is gone. Someone who ticked it wanted to hear about endings,
        /// so they get both of the switches that replaced it — once, and never again
        /// even if they turn them back off.
        static func migrate(_ defaults: UserDefaults = .standard) {
            guard !defaults.bool(forKey: "notifyMigrated18") else { return }
            defaults.set(true, forKey: "notifyMigrated18")
            guard defaults.bool(forKey: "notifyDone") else { return }
            defaults.set(true, forKey: "notifyFailures")
            defaults.set(true, forKey: "notifyQuiet")
        }
    }

    // MARK: - Lifecycle

    /// Registers the delegate and the categories at launch, **without** asking for
    /// permission. Setting a delegate prompts for nothing; `requestAuthorization`
    /// does, and a system prompt during launch is how the app once hung waiting for
    /// a TCC dialog nobody had seen yet. The ask happens when the user ticks the box.
    ///
    /// The delegate is registered even with both switches off, because it is what
    /// receives button taps — and a notification can outlive the setting that
    /// created it.
    func start() {
        Prefs.migrate()
        // See `stepQuiet`: nothing else ticks once everything has stopped.
        quietTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.stepQuiet(self.sessions?() ?? [])
        }
        quietTimer?.tolerance = 3
        // Same pair `SoundCenter` watches, for the opposite reason: a locked screen
        // silences sounds and is exactly when a summary is worth posting.
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked = true }
        dnc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                        object: nil, queue: .main) { [weak self] _ in self?.screenLocked = false }

        let center = UNUserNotificationCenter.current()
        // A launch-time probe for diagnosing "the checkbox does nothing" without
        // making someone click it again; documented next to the other debug
        // defaults in CONTRIBUTING. Async, so it cannot hang the launch.
        if UserDefaults.standard.bool(forKey: "notifyProbeDebug") {
            requestAuthorization { granted, error in
                // A file, not just NSLog: an app launched by LaunchServices has no
                // stderr anyone can read, and launching the binary by hand to get one
                // changes the very thing being measured.
                var line = "granted=\(granted) error=\(String(describing: error))\n"
                line += "bundleID=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)\n"
                let url = AgentBarHome.url("notify-probe.txt")
                UNUserNotificationCenter.current().getNotificationSettings { st in
                    let full = line + "authorizationStatus=\(st.authorizationStatus.rawValue) "
                        + "alertSetting=\(st.alertSetting.rawValue) "
                        + "notificationCenterSetting=\(st.notificationCenterSetting.rawValue)\n"
                    try? full.write(to: url, atomically: true, encoding: .utf8)
                    NSLog("AgentBar: notification probe \(full)")
                }
            }
        }
        center.delegate = self
        let allow = UNNotificationAction(identifier: Self.allowAction, title: "Allow", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny",
                                        options: [.destructive])
        let denyNote = UNTextInputNotificationAction(
            identifier: Self.denyNoteAction, title: "Deny with a note…", options: [.destructive],
            textInputButtonTitle: "Deny", textInputPlaceholder: "What should it do instead?")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.approvalCategory,
                                   actions: [allow, deny, denyNote],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: Self.plainCategory, actions: [],
                                   intentIdentifiers: [], options: []),
        ])
    }

    /// Asks macOS for permission, and reports back what happened so the checkbox can
    /// un-tick itself **and say why** rather than silently springing back — which is
    /// indistinguishable from a dead control, and was exactly that until it was
    /// caught by someone clicking it.
    ///
    /// The error matters as much as the refusal: a plain "no" is the user declining
    /// the system prompt, while an error means macOS would not even ask (an
    /// unregistered or unsigned bundle, usually a build run from a folder rather
    /// than installed), and those two need different words.
    func requestAuthorization(_ done: @escaping (Bool, Error?) -> Void) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, error in
            if let error { NSLog("AgentBar: notification authorization failed: \(error)") }
            DispatchQueue.main.async { done(granted, error) }
        }
    }

    /// One sentence for the Settings caption, or nil when there is nothing wrong.
    ///
    /// Worded from the *status*, not from the error. `requestAuthorization` returns
    /// `UNErrorDomain Code=1` for anything it will not ask about, and guessing why
    /// from that is how the first version of this told people to move the app when
    /// the real answer was a switch in System Settings. Once macOS has AgentBar down
    /// as denied it never prompts again, so the only way out is that switch.
    static func problem(granted: Bool, error: Error?, status: UNAuthorizationStatus) -> String? {
        if granted || status == .authorized || status == .provisional { return nil }
        switch status {
        case .denied:
            return "macOS has notifications switched off for AgentBar. Turn them on in\nSystem Settings ▸ Notifications ▸ AgentBar, then tick this again."
        case .notDetermined where error != nil:
            return "macOS would not ask: \(error!.localizedDescription)"
        default:
            return "macOS did not allow notifications for AgentBar."
        }
    }

    /// Whether macOS will actually deliver, which the user can change in System
    /// Settings behind our back. Settings shows it so a ticked box that does nothing
    /// is explainable.
    func authorizationStatus(_ done: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            DispatchQueue.main.async { done(s.authorizationStatus) }
        }
    }

    // MARK: - What deserves a notification (pure, so it can be tested)

    struct Event: Equatable {
        enum Kind: Equatable { case approval, question, failed, quiet }
        let id: String
        let kind: Kind
        let title: String
        let body: String
        let sessionId: String
        /// The request's `identity` for approvals and questions, empty otherwise. The
        /// banner is keyed by file name, and a file name can come back holding a
        /// different request; this is what tells the two apart when it is tapped.
        var requestIdentity: String = ""
    }

    /// Approvals and questions, keyed by the request's file name so the banner can
    /// be taken back down when the request goes away.
    ///
    /// Questions get no buttons: their answer is a choice from a list or free text,
    /// which a two-button banner cannot express — tapping one jumps to the session.
    /// `shown` is the identity each banner was posted for. A file name that comes
    /// back holding a different request is a new request, and it is announced —
    /// posted under the same id, so it replaces the stale banner instead of
    /// leaving the old command on screen and the new one unheard.
    static func requestEvents(previous: Set<String>, requests: [ApprovalRequest],
                              sessions: [Session], enabled: Bool,
                              shown: [String: String] = [:]) -> (post: [Event], withdraw: [String]) {
        guard enabled else { return ([], Array(previous)) }
        let live = Set(requests.map(\.fileName))
        let post = requests.filter { r in
            !previous.contains(r.fileName) || shown[r.fileName].map { $0 != r.identity } == true
        }.map { r -> Event in
            // The project names the work; the agent names it when there is no project
            // yet, and the request carries its own agent id — a request can arrive
            // before the session row it belongs to.
            let project = sessions.first { $0.id == r.sessionId }?.project ?? ""
            let who = project.isEmpty ? r.agent.name : project
            return r.questions != nil
                ? Event(id: r.fileName, kind: .question, title: "\(who) is asking",
                        body: r.display, sessionId: r.sessionId, requestIdentity: r.identity)
                : Event(id: r.fileName, kind: .approval, title: "\(who) needs approval",
                        body: r.display, sessionId: r.sessionId, requestIdentity: r.identity)
        }
        return (post, previous.subtracting(live).map { $0 })
    }

    /// Turns that ended badly. Edge-detected against the previous tick, the way
    /// `SoundCenter.observe` does it, so a row sitting in `error` notifies once.
    ///
    /// Only `error`, deliberately. A successful turn ending is the single most
    /// frequent event AgentBar sees and it wants nothing from you; a failed one is
    /// rare and is the reason you would go and look.
    ///
    /// `decayed` rows are skipped: a watchdog guessing that a quiet Antigravity
    /// session is over is not the agent saying it failed, and a banner claiming
    /// otherwise would be inventing an outcome.
    static func failureEvents(previous: [String: Session.State], sessions: [Session],
                              enabled: Bool) -> [Event] {
        guard enabled else { return [] }
        return sessions.compactMap { s -> Event? in
            guard s.started, !s.decayed, s.state == .error else { return nil }
            guard previous[s.id] != .error else { return nil }
            // The display name, not the raw id — "claude failed" is a log line, not a
            // notification. Matches what `requestEvents` above already does.
            let who = s.project.isEmpty ? s.agent.name : s.project
            return Event(id: "error:\(s.id):\(Int(s.ts))", kind: .failed,
                         title: "\(who) failed",
                         body: s.label.isEmpty ? "The turn ended with an error." : s.label,
                         sessionId: s.id)
        }
    }

    // MARK: - All quiet

    /// One burst of work: from the moment something started running until everything
    /// has stopped and stayed stopped.
    ///
    /// The unit is deliberately not the session. Sessions finish constantly — every
    /// turn, in Claude's case — and none of those endings is news. A *burst* ending
    /// is: you set some agents going, and now there is nothing left running.
    struct Burst: Equatable {
        /// When work began after the last quiet spell. 0 = nothing has run yet.
        var startedAt: TimeInterval = 0
        /// nil while anything is busy; otherwise when the quiet began.
        var quietSince: TimeInterval?
        /// This burst has already had its banner. Reset when work resumes.
        var announced = false
    }

    /// How long everything must stay stopped, and how long the human must have been
    /// away, before the day is called quiet. Two minutes is long enough that reading
    /// an agent's output does not end the burst, and short enough to still be news.
    static let quietSettle: TimeInterval = 120

    /// Pure: no clock, no `UserDefaults`, no notification centre. Returns the next
    /// burst state and, when this is the tick that earns one, the window the banner
    /// should summarise.
    ///
    /// `inputIdle` is seconds since the human last touched the machine. It is the
    /// difference between a notification and an interruption: if you are at the
    /// keyboard, the island and the menu bar have been telling you this all along,
    /// and a banner is just noise on top. Being away — or locked — is what makes the
    /// same fact worth saying out loud.
    static func quietStep(_ prev: Burst, sessions: [Session], now: TimeInterval,
                          inputIdle: TimeInterval, locked: Bool, enabled: Bool,
                          settle: TimeInterval = quietSettle,
                          requireAway: Bool = true) -> (Burst, announce: (since: TimeInterval, until: TimeInterval)?) {
        // Busy is "not finished", so a session parked on `permission` or `question`
        // holds the burst open. Something waiting on you is not a day's work over.
        let busy = sessions.contains { $0.started && !$0.state.isFinished }
        var next = prev

        if busy {
            // A burst begins on the first work ever seen, and again whenever work
            // resumes after a quiet spell. Otherwise this one is simply still running.
            if next.startedAt == 0 || next.quietSince != nil {
                next.startedAt = now
                next.announced = false
            }
            next.quietSince = nil
            return (next, nil)
        }

        guard enabled, next.startedAt > 0, !next.announced else {
            if next.quietSince == nil { next.quietSince = now }
            return (next, nil)
        }
        guard let since = next.quietSince else {
            next.quietSince = now
            return (next, nil)
        }
        guard now - since >= settle else { return (next, nil) }
        guard !requireAway || locked || inputIdle >= settle else { return (next, nil) }

        next.announced = true
        return (next, (since: next.startedAt, until: now))
    }

    // MARK: - Wiring

    func observe(_ sessions: [Session]) {
        defer { lastStates = Dictionary(sessions.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        // The launch snapshot is a baseline; every failed session already on disk did
        // not just fail, and a relaunch must not fire a dozen banners.
        guard primed else { primed = true; return }

        for e in Self.failureEvents(previous: lastStates, sessions: sessions, enabled: Prefs.failures) {
            post(e)
        }
        stepQuiet(sessions)
    }

    /// The burst, advanced against the clock rather than against a change.
    ///
    /// `SessionStore` only calls back when something *visibly changed* — which is
    /// precisely what a quiet spell is the absence of. The tick where the last
    /// session went quiet is the last tick there is, so waiting for another one waits
    /// forever. Hence a slow timer of its own, and the reason this is split out of
    /// `observe` at all.
    private func stepQuiet(_ sessions: [Session]) {
        // `quietDebug` exists because the honest version of this feature is, by
        // design, almost impossible to see on purpose: it waits two minutes and
        // wants you to have walked away. Documented in CONTRIBUTING.
        let debug = UserDefaults.standard.bool(forKey: "notifyQuietDebug")
        let now = Date().timeIntervalSince1970
        let (next, announce) = Self.quietStep(
            burst, sessions: sessions, now: now,
            inputIdle: InputIdle.seconds(),
            locked: screenLocked, enabled: Prefs.quiet,
            settle: debug ? 10 : Self.quietSettle, requireAway: !debug)
        burst = next
        guard let announce else { return }
        let (summary, _) = HistoryDigest.digest(HistoryStore.cached(),
                                                since: announce.since, until: announce.until)
        // Nothing was recorded for this burst — an agent we cannot time, or a session
        // that never reached an end we trust. Saying "all quiet" with no account of
        // what happened is a banner that costs attention and returns nothing.
        guard !summary.isEmpty else { return }
        post(Event(id: "quiet:\(Int(announce.until))", kind: .quiet,
                   title: "All quiet", body: HistoryDigest.headline(summary), sessionId: ""))
    }

    func requestsChanged(_ requests: [ApprovalRequest], sessions: [Session]) {
        let (post, withdraw) = Self.requestEvents(previous: deliveredRequests, requests: requests,
                                                  sessions: sessions, enabled: Prefs.approvals,
                                                  shown: deliveredIdentities)
        // Withdraw first, and always — a delivered banner whose request has been
        // answered elsewhere, or has timed out, has two live buttons that would do
        // nothing. That is worse than never having shown it.
        if !withdraw.isEmpty {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: withdraw)
            deliveredRequests.subtract(withdraw)
            for id in withdraw { deliveredIdentities[id] = nil }
        }
        for e in post {
            self.post(e)
            deliveredRequests.insert(e.id)
            deliveredIdentities[e.id] = e.requestIdentity
        }
    }

    /// Posts one harmless notification so "are these reaching me?" has an answer
    /// that is not "wait for an agent to need something".
    ///
    /// Worth its button because a delivered notification and a *visible* one are
    /// different things: a Focus suppresses the banner and files it in Notification
    /// Center instead, and from the outside that is indistinguishable from broken.
    func preview() {
        let content = UNMutableNotificationContent()
        content.title = "AgentBar"
        content.body = "This is what an agent notification looks like. Real ones carry Allow and Deny."
        content.categoryIdentifier = Self.plainCategory
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "preview:\(UUID().uuidString)",
                                  content: content, trigger: nil))
    }

    /// Everything on screen goes away — used when the user turns approvals off, so a
    /// banner posted a moment ago cannot outlive the setting that allowed it.
    func withdrawAll() {
        guard !deliveredRequests.isEmpty else { return }
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: Array(deliveredRequests))
        deliveredRequests.removeAll()
        deliveredIdentities.removeAll()
    }

    private func post(_ e: Event) {
        let content = UNMutableNotificationContent()
        content.title = e.title
        if !e.body.isEmpty { content.body = e.body }
        // No sound, deliberately. Audio belongs to `SoundCenter`, which is its own
        // opt-in with its own volume — two systems both deciding to make a noise
        // would double up on every approval.
        content.categoryIdentifier = e.kind == .approval ? Self.approvalCategory : Self.plainCategory
        content.userInfo = ["sessionId": e.sessionId, "requestId": e.id,
                            "requestIdentity": e.requestIdentity]
        let request = UNNotificationRequest(identifier: e.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// The request a banner's button may answer: the one still under that file name
    /// *and* still the one the banner showed. A banner with no identity (posted by an
    /// older build, or not a request at all) answers nothing.
    static func answerable(requestId: String, identity: String,
                           requests: [ApprovalRequest]) -> ApprovalRequest? {
        guard !identity.isEmpty,
              let r = requests.first(where: { $0.fileName == requestId }),
              r.identity == identity
        else { return nil }
        return r
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// AgentBar has no dock icon and is almost never frontmost, but when it is (the
    /// Settings window is open) the banner must still appear — otherwise turning the
    /// setting on and testing it looks broken.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler handler: @escaping () -> Void) {
        defer { handler() }
        let info = response.notification.request.content.userInfo
        let requestId = info["requestId"] as? String ?? ""
        let sessionId = info["sessionId"] as? String ?? ""
        let identity = info["requestIdentity"] as? String ?? ""
        deliveredRequests.remove(requestId)
        deliveredIdentities[requestId] = nil

        let behavior: String?
        var note: String?
        switch response.actionIdentifier {
        case Self.allowAction: behavior = "allow"
        case Self.denyAction: behavior = "deny"
        case Self.denyNoteAction:
            behavior = "deny"
            note = (response as? UNTextInputNotificationResponse)?.userText
        default: behavior = nil          // the banner itself was clicked
        }

        let live = sessions?() ?? []
        guard let behavior else {
            // Tapping the body means "take me there", for an approval and a question
            // alike — a question's answer is a list or free text, which a banner
            // cannot carry.
            if let session = live.first(where: { $0.id == sessionId }) {
                AgentActions.focus(session, requests: requests?() ?? [])
            }
            return
        }

        // Re-look-up rather than trusting the banner: request file names repeat
        // across the tools of one turn, so by the time this is tapped the name may
        // belong to a *successor* request showing a different command. Answering
        // that one would allow something the user never read — so a name that now
        // holds another request only takes you to it, and the answer is yours there.
        let pending = requests?() ?? []
        guard let request = Self.answerable(requestId: requestId, identity: identity,
                                            requests: pending)
        else {
            if let session = live.first(where: { $0.id == sessionId }) {
                AgentActions.focus(session, requests: pending)
            }
            return
        }
        guard let session = live.first(where: { $0.id == request.sessionId }) else { return }
        AgentActions.answer(ApprovalAction(request: request, behavior: behavior, session: session,
                                           note: note))
    }
}

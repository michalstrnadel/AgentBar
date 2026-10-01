import Foundation
import Testing
@testable import AgentBar

/// What deserves a banner, and — the part that matters more — what must stop being
/// one. Everything here runs against the pure decision functions; nothing touches
/// `UNUserNotificationCenter`, which needs a real bundle and a real user.
@Suite struct NotifierTests {
    private let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("agentbar-notify-\(UUID().uuidString)")

    init() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func session(_ id: String, state: String, project: String = "AgentBar",
                         started: Bool = true, recap: String = "", ts: TimeInterval = 1_000) throws -> Session {
        let url = dir.appendingPathComponent("\(id).json")
        let o: [String: Any] = ["agent": "claude", "state": state, "started": started,
                                "ts": ts, "project": project, "label": "build",
                                "recap": recap, "pid": 4242]
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(Session(fileURL: url))
    }

    private func request(_ name: String, session: String = "a",
                         display: String = "Bash: git push", question: Bool = false,
                         hookPid: Int = 2) throws -> ApprovalRequest {
        let url = dir.appendingPathComponent(name)
        var o: [String: Any] = ["sessionId": session, "agent": "claude", "toolName": "Bash",
                                "display": display, "toolInputPretty": "{}",
                                "pid": 1, "hookPid": hookPid, "ts": 1_000]
        if question {
            o["context"] = ["kind": "question",
                            "questions": [["question": "Which one?", "header": "Pick",
                                           "multiSelect": false,
                                           "options": [["label": "A", "description": ""]]]]]
        }
        try JSONSerialization.data(withJSONObject: o).write(to: url)
        return try #require(ApprovalRequest(fileURL: url))
    }

    // MARK: - Off means off

    /// Rule 2 says nothing unfolds over the screen on its own. The switch being off
    /// is what makes this an exception rather than a violation, so it is the first
    /// thing worth a test.
    @Test func nothingIsPostedWhileTheSwitchIsOff() throws {
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [], enabled: false)
        #expect(post.isEmpty)

        let failed = try session("a", state: "error")
        #expect(Notifier.failureEvents(previous: ["a": .thinking], sessions: [failed],
                                       enabled: false).isEmpty)
    }

    /// Turning approvals off has to take back what is already on screen, or a banner
    /// outlives the setting that allowed it.
    @Test func turningItOffWithdrawsWhatIsAlreadyShowing() throws {
        let r = try request("r1.json")
        let (_, withdraw) = Notifier.requestEvents(previous: ["r1.json"], requests: [r],
                                                   sessions: [], enabled: false)
        #expect(withdraw == ["r1.json"])
    }

    // MARK: - Approvals

    @Test func anApprovalIsPostedOnceAndNamesTheProject() throws {
        let s = try session("a", state: "permission", project: "AgentBar")
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [s], enabled: true)
        #expect(post.count == 1)
        #expect(post[0].kind == .approval)
        #expect(post[0].title == "AgentBar needs approval")
        #expect(post[0].body == "Bash: git push")
        #expect(post[0].id == "r1.json")

        // Already showing: the store fires on every tick, and re-posting would make
        // one pending approval buzz forever.
        let (again, _) = Notifier.requestEvents(previous: ["r1.json"], requests: [r],
                                                sessions: [s], enabled: true)
        #expect(again.isEmpty)
    }

    /// File names repeat within a turn. A banner posted for one request must not
    /// answer the request that later took its file name: the button was pressed on
    /// a command the user read, and the successor is a different one.
    @Test func aBannerCannotAnswerTheRequestThatReplacedIt() throws {
        let first = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [first], sessions: [],
                                               enabled: true)
        let shown = try #require(post.first)
        #expect(shown.requestIdentity == first.identity)
        #expect(Notifier.answerable(requestId: shown.id, identity: shown.requestIdentity,
                                    requests: [first])?.identity == first.identity)

        let successor = try request("r1.json", display: "Bash: git reset", hookPid: 3)
        #expect(Notifier.answerable(requestId: shown.id, identity: shown.requestIdentity,
                                    requests: [successor]) == nil)
        // A banner that carries no identity answers nothing either.
        #expect(Notifier.answerable(requestId: shown.id, identity: "", requests: [first]) == nil)
    }

    /// The one that makes the buttons trustworthy: answered in the menu, by the
    /// hotkey, or simply timed out — either way the banner has to come down, because
    /// two live buttons that do nothing are worse than no banner at all.
    @Test func anAnsweredRequestIsWithdrawn() throws {
        let (post, withdraw) = Notifier.requestEvents(previous: ["r1.json"], requests: [],
                                                      sessions: [], enabled: true)
        #expect(post.isEmpty)
        #expect(withdraw == ["r1.json"])
    }

    /// A question's answer is a list or free text; two buttons cannot carry it, so
    /// it is posted without them and the tap jumps to the session instead.
    @Test func aQuestionGetsNoButtons() throws {
        let s = try session("a", state: "question")
        let r = try request("q1.json", question: true)
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [s], enabled: true)
        #expect(post.first?.kind == .question)
    }

    /// No session row yet — the request can arrive before the state file lands.
    @Test func anApprovalWithNoSessionRowStillSaysSomething() throws {
        let r = try request("r1.json")
        let (post, _) = Notifier.requestEvents(previous: [], requests: [r], sessions: [], enabled: true)
        #expect(post.first?.title == "Claude needs approval")
    }

    // MARK: - The banner that had to go

    /// The regression this release exists for. 1.17.0 fired on `state == .done`, and
    /// Claude Code enters `done` at the end of **every turn** — so a long conversation
    /// posted a banner per reply. A successful ending is now not an event at all.
    @Test func aSuccessfulTurnIsNoLongerABanner() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done", recap: "Pushed 3 commits")
        #expect(Notifier.failureEvents(previous: ["a": working.state], sessions: [done],
                                       enabled: true).isEmpty)
    }

    // MARK: - Failures

    @Test func aFailureIsAnnouncedOnce() throws {
        let failed = try session("a", state: "error")
        let out = Notifier.failureEvents(previous: ["a": .tool], sessions: [failed], enabled: true)
        #expect(out.count == 1)
        #expect(out[0].title == "AgentBar failed")
        #expect(out[0].body == "build")

        // The row sits in `error` for hours before pruning reaches it.
        #expect(Notifier.failureEvents(previous: ["a": .error], sessions: [failed],
                                       enabled: true).isEmpty)
    }

    /// "claude failed" is a log line. The banner says what a person calls the thing.
    @Test func aFailureWithoutAProjectNamesTheAgentProperly() throws {
        let failed = try session("a", state: "error", project: "")
        let out = Notifier.failureEvents(previous: ["a": .tool], sessions: [failed], enabled: true)
        #expect(out.first?.title == "Claude failed")
    }

    /// A watchdog guessing that a quiet session is over is not the agent saying it
    /// failed. Announcing it would invent an outcome the user then acts on.
    @Test func aDecayedEndIsNotAnnounced() throws {
        var decayed = try session("a", state: "error")
        decayed.decayed = true
        #expect(Notifier.failureEvents(previous: ["a": .tool], sessions: [decayed],
                                       enabled: true).isEmpty)
    }

    @Test func aSessionThatNeverStartedIsNotAnnounced() throws {
        let ghost = try session("ghost", state: "error", started: false)
        #expect(Notifier.failureEvents(previous: [:], sessions: [ghost], enabled: true).isEmpty)
    }

    /// Two failed turns of one session are two events, so the identifier has to change
    /// or the second banner would silently replace the first under the same id.
    @Test func twoFailedTurnsGetDistinctIdentifiers() throws {
        let first = try session("a", state: "error", ts: 1_000)
        let second = try session("a", state: "error", ts: 2_000)
        let a = Notifier.failureEvents(previous: ["a": .tool], sessions: [first], enabled: true)
        let b = Notifier.failureEvents(previous: ["a": .thinking], sessions: [second], enabled: true)
        #expect(a.first?.id != b.first?.id)
    }

    @Test func failuresRespectTheirOwnSwitch() throws {
        let failed = try session("a", state: "error")
        #expect(Notifier.failureEvents(previous: ["a": .tool], sessions: [failed],
                                       enabled: false).isEmpty)
    }

    // MARK: - All quiet

    /// Drives one burst from first work to the banner, the way the app does.
    private func run(_ steps: [(sessions: [Session], now: TimeInterval, idle: TimeInterval)],
                     locked: Bool = false, enabled: Bool = true, requireAway: Bool = true)
    -> (Notifier.Burst, [(since: TimeInterval, until: TimeInterval)]) {
        var burst = Notifier.Burst()
        var announced: [(since: TimeInterval, until: TimeInterval)] = []
        for step in steps {
            let (next, out) = Notifier.quietStep(burst, sessions: step.sessions, now: step.now,
                                                 inputIdle: step.idle, locked: locked,
                                                 enabled: enabled, settle: 120,
                                                 requireAway: requireAway)
            burst = next
            if let out { announced.append(out) }
        }
        return (burst, announced)
    }

    @Test func aBurstIsAnnouncedOnceAndCoversItsWholeSpan() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([(([working]), 1_000, 0), ([done], 1_100, 100),
                            ([done], 1_300, 300), ([done], 1_400, 400)])
        #expect(out.count == 1)
        #expect(out.first?.since == 1_000)
        #expect(out.first?.until == 1_300)
    }

    /// The whole point of the settle: a pause to read the output is not the end of
    /// the day's work.
    @Test func nothingIsAnnouncedBeforeTheQuietHolds() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([([working], 1_000, 0), ([done], 1_100, 100), ([done], 1_190, 190)])
        #expect(out.isEmpty)
    }

    /// If you are at the keyboard, the island has been telling you this all along and
    /// a banner is noise on top of it.
    @Test func nothingIsAnnouncedWhileYouAreAtTheKeyboard() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([([working], 1_000, 0), ([done], 1_100, 0), ([done], 1_300, 2)])
        #expect(out.isEmpty)
    }

    @Test func aLockedScreenCountsAsAway() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([([working], 1_000, 0), ([done], 1_100, 0), ([done], 1_300, 0)],
                           locked: true)
        #expect(out.count == 1)
    }

    /// A session parked on a permission prompt is the opposite of a finished day —
    /// it is the one thing that is definitely still waiting.
    @Test func aSessionWaitingOnYouHoldsTheBurstOpen() throws {
        let working = try session("a", state: "thinking")
        let waiting = try session("a", state: "permission")
        let (_, out) = run([([working], 1_000, 0), ([waiting], 1_100, 100), ([waiting], 1_400, 400)])
        #expect(out.isEmpty)
    }

    @Test func workResumingStartsAFreshBurst() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([([working], 1_000, 0), ([done], 1_100, 100), ([done], 1_300, 300),
                            ([working], 1_500, 0), ([done], 1_600, 100), ([done], 1_800, 300)])
        #expect(out.count == 2)
        #expect(out[1].since == 1_500)
    }

    @Test func quietRespectsItsOwnSwitch() throws {
        let working = try session("a", state: "thinking")
        let done = try session("a", state: "done")
        let (_, out) = run([([working], 1_000, 0), ([done], 1_100, 100), ([done], 1_300, 300)],
                           enabled: false)
        #expect(out.isEmpty)
    }

    /// Launching into a machine where nothing is running must not announce a burst
    /// that never happened.
    @Test func aQuietStartAnnouncesNothing() {
        let (_, out) = run([([], 1_000, 999), ([], 1_300, 999)])
        #expect(out.isEmpty)
    }

    // MARK: - Migration

    /// `notifyDone` is gone, but someone ticked it. They wanted to hear about
    /// endings, so they get both switches that replaced it — and only once, so
    /// turning them back off sticks.
    @Test func theOldFinishedSwitchBecomesBothNewOnes() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar-migrate-\(UUID().uuidString)"))
        defaults.set(true, forKey: "notifyDone")
        Notifier.Prefs.migrate(defaults)
        #expect(defaults.bool(forKey: "notifyFailures"))
        #expect(defaults.bool(forKey: "notifyQuiet"))

        defaults.set(false, forKey: "notifyQuiet")
        Notifier.Prefs.migrate(defaults)
        #expect(!defaults.bool(forKey: "notifyQuiet"))
    }

    @Test func someoneWhoNeverTickedItGetsNothingSwitchedOn() throws {
        let defaults = try #require(UserDefaults(suiteName: "agentbar-migrate-\(UUID().uuidString)"))
        Notifier.Prefs.migrate(defaults)
        #expect(!defaults.bool(forKey: "notifyFailures"))
        #expect(!defaults.bool(forKey: "notifyQuiet"))
    }
}

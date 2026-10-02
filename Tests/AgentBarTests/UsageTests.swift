import Foundation
import SQLite3
import Testing
@testable import AgentBar

/// What the providers say is left. Most of these are about the cases where the
/// honest answer is a gap: a window nobody has written since it rolled over, a
/// ceiling that does not exist locally, a number that is somebody else's day.
@Suite struct UsageTests {
    /// 2026-09-17 12:00:00 UTC, with a UTC calendar wherever a day boundary
    /// matters — a test that inherits the runner's timezone passes in Prague and
    /// fails in CI.
    private static let noon = Date(timeIntervalSince1970: 1_789_646_400)
    private static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// The exact text shape Copilot's `created_at` column uses. Written out again
    /// here rather than borrowed from the code under test, so a format that drifts
    /// on one side shows up as a failure instead of agreeing with itself.
    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return f.string(from: d)
    }

    private func rollout(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    private func tokenCount(limitID: String?, primary: String = "null",
                            secondary: String = "null", credits: String = "null",
                            at: Date = UsageTests.noon) -> String {
        let iso = ISO8601DateFormatter().string(from: at)
        let id = limitID.map { "\"\($0)\"" } ?? "null"
        return """
        {"timestamp":"\(iso)","payload":{"type":"token_count","info":{},"rate_limits":\
        {"limit_id":\(id),"primary":\(primary),"secondary":\(secondary),"credits":\(credits)}}}
        """
    }

    private func window(_ percent: Double, minutes: Int, resets: Date) -> String {
        """
        {"used_percent":\(percent),"window_minutes":\(minutes),\
        "resets_at":\(Int(resets.timeIntervalSince1970))}
        """
    }

    // MARK: - Codex

    /// The regression this release exists for: a rollout carries more than one
    /// bucket, and on a real machine the **last** `token_count` line was the
    /// `premium` one with both windows null. Reading only the newest matching
    /// line found nothing and the whole row vanished.
    @Test func codexReadsPastAPremiumLineToTheAccountWindows() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(97, minutes: 300, resets: Self.noon.addingTimeInterval(1800)),
                       secondary: window(27, minutes: 10080,
                                         resets: Self.noon.addingTimeInterval(86400))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":false,"unlimited":false,"balance":"0"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 2)
        #expect(usage.windows[0].name == "5h")
        #expect(usage.windows[0].usedPercent == 97)
        #expect(usage.windows[1].name == "weekly")
        #expect(usage.windows[1].usedPercent == 27)
    }

    /// An account with no credits has a balance of "0", and "0 credits left" is
    /// bad news about a thing that was never true.
    @Test func codexShowsNoCreditLineWithoutCredits() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(10, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":false,"unlimited":false,"balance":"0"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.creditsNote == nil)
    }

    @Test func codexShowsTheBalanceWhenThereAreCredits() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(10, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "premium",
                       credits: #"{"has_credits":true,"unlimited":false,"balance":"12.50"}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.creditsNote == "12.50 credits left")
    }

    /// Model-specific buckets answer a different question, and taking one for the
    /// account's would understate a busy day.
    @Test func codexIgnoresPerModelBuckets() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(80, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
            tokenCount(limitID: "codex_gpt-5",
                       primary: window(3, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedPercent == 80)
    }

    /// Rollouts predate `limit_id` entirely; a missing one is the account bucket.
    @Test func codexTreatsAMissingLimitIDAsTheAccount() throws {
        let tail = rollout([
            tokenCount(limitID: nil,
                       primary: window(42, minutes: 300, resets: Self.noon.addingTimeInterval(600))),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.first?.usedPercent == 42)
    }

    /// A March window shown in August. Silence is the only honest rendering of a
    /// number whose window rolled over a dozen times since it was written.
    @Test func codexRefusesAStaleTail() {
        let old = Self.noon.addingTimeInterval(-48 * 3600)
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(97, minutes: 300, resets: old.addingTimeInterval(600)),
                       at: old),
        ])
        #expect(UsageCenter.codexUsage(tail: tail, now: Self.noon) == nil)
    }

    /// A window the account doesn't have comes back as null — no meter, never a
    /// confident zero.
    @Test func codexSkipsNullWindows() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(55, minutes: 300, resets: Self.noon.addingTimeInterval(600)),
                       secondary: "null"),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 1)
    }

    @Test func codexWithNothingToSaySaysNothing() {
        #expect(UsageCenter.codexUsage(tail: "", now: Self.noon) == nil)
        #expect(UsageCenter.codexUsage(tail: "not json at all\n", now: Self.noon) == nil)
    }

    // MARK: - The sentence

    @Test func remainingIsWhatIsLeft() {
        let w = UsageWindow(name: "5h", usedPercent: 97, resetsAt: nil)
        #expect(w.remainingPercent == 3)
        #expect(UsageCenter.short(w, now: Self.noon) == "3% left")
    }

    @Test func aRolledOverWindowSaysSoInsteadOfQuotingTheOldNumber() {
        let w = UsageWindow(name: "5h", usedPercent: 97,
                            resetsAt: Self.noon.addingTimeInterval(-60))
        #expect(w.expired(now: Self.noon))
        #expect(UsageCenter.short(w, now: Self.noon) == "window reset")
    }

    /// A clock for today, a weekday for anything further out: "resets 14:31" for
    /// next Thursday is not an answer.
    @Test func resetsReadAsAClockOrAWeekday() {
        let soon = UsageWindow(name: "5h", usedPercent: 50,
                               resetsAt: Self.noon.addingTimeInterval(3600))
        #expect(UsageCenter.short(soon, now: Self.noon).contains("resets"))
        let far = UsageWindow(name: "weekly", usedPercent: 50,
                              resetsAt: Self.noon.addingTimeInterval(4 * 86400))
        let text = UsageCenter.short(far, now: Self.noon)
        #expect(text.contains("50% left"))
        #expect(!text.contains(":"))   // a weekday, not a time of day
    }

    /// A window that has just rolled over has nothing to say, so the line leads
    /// with one that does — otherwise the island spends its whole usage line on
    /// "window reset" while "74% of the week left" hides in a tooltip.
    @Test func theOneLineFormLeadsWithAWindowThatHasNews() throws {
        let r = try #require(UsageCenter.reading(provider: "Codex", windows: [
            UsageWindow(name: "5h", usedPercent: 97, resetsAt: Self.noon.addingTimeInterval(-60)),
            UsageWindow(name: "weekly", usedPercent: 26,
                        resetsAt: Self.noon.addingTimeInterval(4 * 86_400)),
        ], now: Self.noon))
        #expect(r.text.hasPrefix("74% left"))
        #expect(r.detail?.contains("5h: window reset") == true)
    }

    /// When every window has rolled over there is no news to lead with, and the
    /// line says exactly that rather than reaching for the old number.
    @Test func allWindowsResetStillSaysSo() throws {
        let r = try #require(UsageCenter.reading(provider: "Codex", windows: [
            UsageWindow(name: "5h", usedPercent: 97, resetsAt: Self.noon.addingTimeInterval(-60)),
        ], now: Self.noon))
        #expect(r.text == "window reset")
    }

    /// The meter rows: a provider says its name once, an expired window carries no
    /// meter at all, and a note rides along without pretending to be a window.
    @Test func meterRowsSayTheNameOnceAndSkipMetersNobodyMeasured() {
        let reading = UsageCenter.Reading(
            provider: "Codex", text: "x", detail: nil,
            windows: [UsageWindow(name: "5h", usedPercent: 97,
                                  resetsAt: Date(timeIntervalSince1970: 1)),
                      UsageWindow(name: "weekly", usedPercent: 27,
                                  resetsAt: Date(timeIntervalSinceNow: 86400))],
            note: "12.50 credits left")
        let rows = UsageMeterView.rows(for: [reading])
        #expect(rows.count == 3)
        #expect(rows[0].provider == "Codex")
        #expect(rows[0].used == nil)          // rolled over: no meter
        #expect(rows[1].provider.isEmpty)     // said once
        #expect(rows[1].used == 27)
        #expect(rows[2].trailing == "12.50 credits left")
        #expect(rows[2].window.isEmpty)
    }

    /// A provider with no published ceiling gets a number, not a meter against a
    /// guess.
    @Test func aProviderWithoutACeilingGetsNoMeter() {
        let rows = UsageMeterView.rows(for: [
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].used == nil)
        #expect(rows[0].trailing == "2.4 AIU today")
    }

    /// The island's line has room for one window per provider, and it takes the one
    /// about to run out — the same choice the sentence makes.
    @Test func theIslandLineTakesTheWindowWithNews() throws {
        let reading = UsageCenter.Reading(
            provider: "Codex", text: "x",
            windows: [UsageWindow(name: "5h", usedPercent: 97,
                                  resetsAt: Date(timeIntervalSince1970: 1)),
                      UsageWindow(name: "weekly", usedPercent: 26,
                                  resetsAt: Date(timeIntervalSinceNow: 86_400))])
        let rows = UsageMeterView.compactRows(for: [reading])
        #expect(rows.count == 1)
        #expect(rows[0].used == 26)          // the 5h one rolled over
        #expect(rows[0].trailing == "74% left")
    }

    /// A bar that is nearly full beside a bare "3%" reads as a contradiction: the
    /// bar says what is gone and the number says what is left. The word settles it.
    @Test func theIslandNumberSaysWhichHalfItIs() throws {
        let reading = UsageCenter.Reading(
            provider: "Codex", text: "x",
            windows: [UsageWindow(name: "5h", usedPercent: 97,
                                  resetsAt: Date(timeIntervalSinceNow: 600))])
        #expect(UsageMeterView.compactRows(for: [reading]).first?.trailing == "3% left")
    }

    /// A provider with no ceiling keeps its sentence and gets no bar, on the island
    /// exactly as in the menu.
    @Test func theIslandLineKeepsAProviderWithoutACeiling() {
        let rows = UsageMeterView.compactRows(for: [
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ])
        #expect(rows.count == 1)
        #expect(rows[0].used == nil)
        #expect(rows[0].trailing == "2.4 AIU today")
    }

    /// …and when the missing bar has a reason, the island says it. A meter that is
    /// absent without a word reads as a broken app, which is how it was read.
    @Test func aMissingMeterSaysWhyOnTheIslandToo() {
        let rows = UsageMeterView.compactRows(for: [
            UsageCenter.Reading(provider: "Claude", text: "~1.1M tok this 5h block",
                                note: "the stored login is empty"),
        ])
        #expect(rows[0].trailing == "~1.1M tok this 5h block · the stored login is empty")
        // A provider that simply has no ceiling is not a problem and says nothing.
        let quiet = UsageMeterView.compactRows(for: [
            UsageCenter.Reading(provider: "Copilot", text: "2.4 AIU today"),
        ])
        #expect(quiet[0].trailing == "2.4 AIU today")
    }

    @Test func aiuKeepsTheDecimalsThatMatter() {
        #expect(UsageCenter.aiu(33_104_000) == "0.03")   // a morning of small edits
        #expect(UsageCenter.aiu(2_373_072_000) == "2.4")
        #expect(UsageCenter.aiu(42_000_000_000) == "42")
    }

    // MARK: - Which providers the island's one line is for

    private func reading(_ provider: String, used: Double?,
                         resets: TimeInterval = 3_600) -> UsageCenter.Reading {
        guard let used else { return UsageCenter.Reading(provider: provider, text: "no ceiling") }
        return UsageCenter.Reading(
            provider: provider, text: "",
            windows: [UsageWindow(name: "5h", usedPercent: used,
                                  resetsAt: Date().addingTimeInterval(resets))])
    }

    /// The line is one line, shared with the ⋯ button: it carries what is
    /// running, and the menu carries the rest.
    @Test func theIslandLineShowsWhatIsRunning() {
        let all = [reading("Codex", used: 26), reading("Claude", used: 40)]
        let shown = UsageCenter.relevant(all, active: ["Claude"])
        #expect(shown.map(\.provider) == ["Claude"])
    }

    /// Running first, but the rest of the order left alone — a shortlist that
    /// reshuffles itself between two Codex sessions is a moving target.
    @Test func whatIsRunningComesFirst() {
        let all = [reading("Codex", used: 90), reading("Claude", used: 40),
                   reading("Copilot", used: nil)]
        let shown = UsageCenter.relevant(all, active: ["Claude", "Copilot"])
        #expect(shown.map(\.provider) == ["Claude", "Copilot", "Codex"])
    }

    /// The one thing that must never be hidden by tidiness: a window nearly
    /// spent. Whether you are using it now is exactly the decision it informs.
    @Test func aProviderNearlyOutStaysOnTheLine() {
        let all = [reading("Codex", used: 84), reading("Claude", used: 12)]
        #expect(UsageCenter.relevant(all, active: ["Claude"]).map(\.provider)
                == ["Claude", "Codex"])
        // …but only while the number still stands for something.
        let stale = [UsageCenter.Reading(
            provider: "Codex", text: "",
            windows: [UsageWindow(name: "5h", usedPercent: 99,
                                  resetsAt: Date().addingTimeInterval(-60))])]
        #expect(UsageCenter.relevant(stale + [reading("Claude", used: 12)],
                                     active: ["Claude"]).map(\.provider) == ["Claude"])
    }

    /// Nothing running: the line keeps the last thing that was, rather than
    /// blinking out between sessions.
    @Test func withNothingRunningTheLastProviderStays() {
        let all = [reading("Codex", used: 26), reading("Claude", used: 40)]
        #expect(UsageCenter.relevant(all, active: [], lastUsed: "Claude").map(\.provider)
                == ["Claude"])
        // And with no history either, something rather than nothing.
        #expect(UsageCenter.relevant(all, active: []).map(\.provider) == ["Codex"])
        #expect(UsageCenter.relevant([], active: []).isEmpty)
    }

    @Test func agentsMapOntoTheAccountTheySpendFrom() {
        #expect(UsageCenter.provider(forAgent: "claude") == "Claude")
        #expect(UsageCenter.provider(forAgent: "cowork") == "Claude")
        #expect(UsageCenter.provider(forAgent: "codex") == "Codex")
        #expect(UsageCenter.provider(forAgent: "copilot") == "Copilot")
        #expect(UsageCenter.provider(forAgent: "gemini") == nil)
    }

    @Test func aLookalikeIdSpendsFromNobody() {
        // Any tool may report under an id it picks; one that merely starts like a
        // vendor's must not put its spending on that vendor's meter.
        #expect(UsageCenter.provider(forAgent: "codex-fork") == nil)
        #expect(UsageCenter.provider(forAgent: "claudette") == nil)
        #expect(UsageCenter.provider(forAgent: "copilot-x") == nil)
        #expect(UsageCenter.provider(forAgent: "") == nil)
    }

    /// A sentence gets the width; a value keeps its column. A note under a
    /// provider is a sentence, and so is a provider whose whole truth is a
    /// phrase — held in the numbers column, "~654k tok this 5h block · resets
    /// 12:00" arrived as "~654k tok this 5h block…".
    @Test func sentencesGetTheWidthAndValuesKeepTheirColumn() throws {
        let rows = UsageMeterView.rows(for: [
            UsageCenter.Reading(provider: "Claude", text: "~12k tok this 5h block",
                                note: "waiting on Keychain permission"),
            reading("Codex", used: 26),
        ])
        #expect(rows.count == 3)
        #expect(rows[0].spans)                       // a provider with no ceiling
        #expect(rows[1].spans)                       // its note
        #expect(rows[1].trailing == "waiting on Keychain permission")
        #expect(rows[2].spans == false)              // a window with a meter
    }

    // MARK: - Claude's quota (parsing only — nothing here reaches the network)

    private static let payload = """
    {"five_hour":{"utilization":33.0,"resets_at":"2026-09-16T17:00:00.528743+00:00"},
     "seven_day":{"utilization":13.0,"resets_at":"2026-09-20T00:59:59.951713+00:00"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null}}
    """

    @Test func quotaParsesBothWindows() throws {
        let snap = try #require(ClaudeQuota.parse(Data(Self.payload.utf8), account: "someone"))
        #expect(snap.windows.count == 2)
        #expect(snap.windows[0].name == "5h")
        #expect(snap.windows[0].usedPercent == 33)
        #expect(snap.windows[1].name == "weekly")
        #expect(snap.windows[1].resetsAt != nil)
        #expect(snap.account == "someone")
    }

    /// `utilization` is already a percentage. Readers that take it for a fraction
    /// render 1 % as 100 % or 55 % as half a percent — both have been filed
    /// against other clients of this endpoint, so it is worth a test of its own.
    @Test func quotaTreatsUtilizationAsAPercentageNotAFraction() throws {
        let json = #"{"five_hour":{"utilization":1.0,"resets_at":null}}"#
        let snap = try #require(ClaudeQuota.parse(Data(json.utf8)))
        #expect(snap.windows[0].usedPercent == 1)
    }

    @Test func quotaSkipsWindowsTheAccountDoesNotHave() throws {
        let json = #"{"five_hour":null,"seven_day":{"utilization":8.0,"resets_at":null}}"#
        let snap = try #require(ClaudeQuota.parse(Data(json.utf8)))
        #expect(snap.windows.count == 1)
        #expect(snap.windows[0].name == "weekly")
    }

    @Test func quotaWithNoWindowsIsNoReading() {
        #expect(ClaudeQuota.parse(Data(#"{"extra_usage":{}}"#.utf8)) == nil)
        #expect(ClaudeQuota.parse(Data("nonsense".utf8)) == nil)
    }

    /// One Keychain record, many logins. Claude Code keeps its own OAuth token
    /// beside an `accessToken` for **every MCP server the user has authorised**,
    /// so a search by key name returns whichever one the dictionary yields first
    /// — and this token is put in an `Authorization` header to Anthropic. Sending
    /// somebody else's OAuth token to a company it has nothing to do with is not
    /// a formatting mistake, so the field is named and never searched for.
    @Test func onlyClaudesOwnTokenIsEverRead() {
        let real: [String: Any] = [
            "claudeAiOauth": ["accessToken": "sk-ant-oat01-real", "expiresAt": 0],
            "mcpOAuth": [
                "figma|abc": ["accessToken": "figd_thirdparty", "clientSecret": "shh"],
                "supabase|def": ["accessToken": "sbp_thirdparty"],
            ],
        ]
        #expect(ClaudeQuota.accessToken(in: real) == "sk-ant-oat01-real")

        // Signed out of Claude, still holding other people's tokens: nothing
        // leaves this machine. Run it enough times that dictionary order cannot
        // hide a regression.
        let loggedOut: [String: Any] = [
            "claudeAiOauth": ["accessToken": "", "expiresAt": 0],
            "mcpOAuth": [
                "figma|abc": ["accessToken": "figd_thirdparty"],
                "supabase|def": ["accessToken": "sbp_thirdparty"],
                "sentry|ghi": ["accessToken": "sntrys_thirdparty"],
            ],
        ]
        for _ in 0..<50 { #expect(ClaudeQuota.accessToken(in: loggedOut) == nil) }
        #expect(ClaudeQuota.loggedOut(loggedOut))
        #expect(!ClaudeQuota.loggedOut(real))

        // The file form's own spellings still work; an unknown shape reads as
        // nothing rather than as a guess.
        #expect(ClaudeQuota.accessToken(in: ["access_token": "sk-y"]) == "sk-y")
        #expect(ClaudeQuota.accessToken(in: ["accessToken": ""]) == nil)
        #expect(ClaudeQuota.accessToken(in: ["somethingElse": 1]) == nil)
    }

    /// Same discipline for the expiry: one read out of an MCP server's section
    /// describes that server's token, and answered a question nobody asked —
    /// including, on this machine, "expired in July" about a token issued in
    /// September.
    @Test func theExpiryIsClaudesOwnOrNothing() {
        let mixed: [String: Any] = [
            "claudeAiOauth": ["accessToken": "sk-ant-oat01-real", "expiresAt": 0],
            "mcpOAuth": ["figma|abc": ["expiresAt": 1_000_000]],
        ]
        for _ in 0..<50 { #expect(!ClaudeQuota.expired(mixed, now: Self.noon)) }
        #expect(ClaudeQuota.expiry(in: mixed) == nil)   // zero means no expiry, not 1970
    }

    /// An expired token is not an error worth surfacing: the CLI renews it on its
    /// own next run, and asking with it would only spend a 401.
    @Test func anExpiredCredentialIsNotUsed() {
        let past = ["claudeAiOauth": ["expiresAt": 1_000_000]]
        #expect(ClaudeQuota.expired(past, now: Self.noon))
        let future = ["claudeAiOauth": ["expiresAt": Self.noon.timeIntervalSince1970 * 1000 + 60_000]]
        #expect(!ClaudeQuota.expired(future, now: Self.noon))
        #expect(!ClaudeQuota.expired(["no": "expiry"], now: Self.noon))
    }

    /// The header the endpoint routes on, with our own name after it rather than
    /// instead of it.
    @Test func theUserAgentNamesBothProgrammes() {
        let ua = ClaudeQuota.userAgent(appVersion: "1.19.0")
        #expect(ua.hasPrefix("claude-code/"))
        #expect(ua.contains("AgentBar/1.19.0"))
    }

    // MARK: - Saying why there is no number

    /// "There is no login here" and "macOS would not give me the one that is
    /// here" send a person to two different places, so they are two states.
    @Test func aRefusalIsNotAMissingLogin() {
        func outcome(_ code: OSStatus) -> String {
            switch ClaudeQuota.lookup(forKeychain: code) {
            case .found:            return "found"
            case .missing:          return "missing"
            case .refused(let got): return "refused:\(got)"   // the number tells them apart
            case .notAsked:         return "not asked"
            }
        }
        #expect(outcome(errSecItemNotFound) == "missing")
        for code in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            #expect(outcome(code) == "refused:\(code)")
        }
    }

    /// Everywhere else a failure is silent. Beside the switch that caused it,
    /// silence is indistinguishable from a broken switch.
    @Test func everyFailureHasASentenceAndACause() {
        let cases: [ClaudeQuota.Status] = [
            .off, .asking, .noCredential, .loggedOut, .notAsked, .refused(errSecAuthFailed),
            .expiredToken(at: Self.noon), .declined(code: 401, message: nil),
            .rateLimited(until: Self.noon), .unreachable, .unexpected(503),
        ]
        for status in cases {
            let sentence = ClaudeQuota.sentence(for: status, now: Self.noon)
            #expect(sentence.count > 20)
            #expect(sentence.hasSuffix("."))
        }
        #expect(ClaudeQuota.sentence(for: .refused(errSecAuthFailed)).contains("Keychain"))
        #expect(ClaudeQuota.sentence(for: .ok(at: Self.noon, account: "someone"),
                                     now: Self.noon).contains("someone"))
    }

    /// A reading on screen and a switch that is off both mean there is nothing
    /// to explain; the menu row stays a number.
    @Test func theMenuNoteAppearsOnlyWhenSomethingIsWrong() {
        #expect(ClaudeQuota.shortReason(for: .off) == nil)
        #expect(ClaudeQuota.shortReason(for: .ok(at: Self.noon, account: nil)) == nil)
        #expect(ClaudeQuota.shortReason(for: .refused(errSecAuthFailed))
                == "waiting on Keychain permission")
        // Short enough for a menu row: the long form lives in Settings.
        for status: ClaudeQuota.Status in [.asking, .noCredential, .loggedOut, .notAsked,
                                           .expiredToken(at: Self.noon),
                                           .declined(code: 401, message: nil),
                                           .rateLimited(until: Self.noon), .unreachable] {
            #expect((ClaudeQuota.shortReason(for: status) ?? "").count <= 34)
        }
    }

    /// A token handed over on purpose wins over the CLI's own record: it is the
    /// only thing that works on a Mac whose sessions keep their login out of
    /// reach, and pasting one is a deliberate act with a deliberate meaning.
    @Test func aTokenGivenOnPurposeWins() throws {
        let record = ClaudeQuota.Lookup.found(
            json: ["claudeAiOauth": ["accessToken": "from-the-cli"]],
            account: "someone")
        let mine = try ClaudeQuota.token(storedBy: "pasted-by-hand", orIn: record).get()
        #expect(mine.token == "pasted-by-hand")
        #expect(mine.account == "your own token")

        let cli = try ClaudeQuota.token(storedBy: nil, orIn: record).get()
        #expect(cli.token == "from-the-cli")
        #expect(cli.account == "someone")
    }

    /// And every way there is to have none says which one it was, because they
    /// send a person to four different places.
    @Test func noTokenSaysWhichKindOfNothing() {
        func failure(_ stored: String?, _ lookup: ClaudeQuota.Lookup) -> ClaudeQuota.Status? {
            if case .failure(let why) = ClaudeQuota.token(storedBy: stored, orIn: lookup) {
                return why
            }
            return nil
        }
        #expect(failure(nil, .missing) == .noCredential)
        #expect(failure(nil, .refused(errSecAuthFailed)) == .refused(errSecAuthFailed))
        #expect(failure(nil, .found(json: ["claudeAiOauth": ["accessToken": ""]],
                                    account: nil)) == .loggedOut)
        #expect(failure(nil, .found(json: ["nothing": 1], account: nil)) == .noCredential)
        let stale: [String: Any] = ["claudeAiOauth": ["accessToken": "long-lapsed",
                                                      "expiresAt": 1_000_000]]
        #expect(failure(nil, .found(json: stale, account: nil))
                == .expiredToken(at: Date(timeIntervalSince1970: 1_000_000)))
    }

    /// The dialog macOS raises for another application's Keychain item comes
    /// back after every reinstall, so what becomes of the answer matters more
    /// than the answer: a grant outlives the build that earned it, a refusal
    /// closes the door until somebody presses the button again, and "no such
    /// item" settles nothing, because nothing was refused. Without this, ten
    /// releases in a day cost ten prompts and one Deny cost one every five
    /// minutes.
    @Test func oneAnswerToTheKeychainPromptIsRemembered() {
        #expect(ClaudeQuota.allowed(after: errSecSuccess, was: false))
        #expect(ClaudeQuota.allowed(after: errSecSuccess, was: true))
        #expect(!ClaudeQuota.allowed(after: errSecAuthFailed, was: true))
        #expect(!ClaudeQuota.allowed(after: errSecUserCanceled, was: true))
        #expect(!ClaudeQuota.allowed(after: errSecInteractionNotAllowed, was: true))
        #expect(ClaudeQuota.allowed(after: errSecItemNotFound, was: true))
        #expect(!ClaudeQuota.allowed(after: errSecItemNotFound, was: false))
    }

    /// And a question nobody asked is not a login nobody has: one is answered by
    /// pressing a button, the other by signing in somewhere, and a person told
    /// the wrong one goes looking in the wrong place.
    @Test func aQuestionNotAskedIsNotALoginNotThere() throws {
        func failure(_ lookup: ClaudeQuota.Lookup) -> ClaudeQuota.Status? {
            if case .failure(let why) = ClaudeQuota.token(storedBy: nil, orIn: lookup) {
                return why
            }
            return nil
        }
        #expect(failure(.notAsked) == .notAsked)
        #expect(failure(.missing) == .noCredential)
        #expect(ClaudeQuota.sentence(for: .notAsked).contains("Check now"))

        // A token handed over on purpose is read without anyone being asked
        // anything, so the shut door costs it nothing.
        let mine = try ClaudeQuota.token(storedBy: "pasted-by-hand", orIn: .notAsked).get()
        #expect(mine.token == "pasted-by-hand")
    }

    /// The island's quota line sits in a stack next to the ⋯ button, so nothing
    /// stretches it and nothing else states its width. Without a width of its
    /// own the solver was free to give it zero — and did, sometimes, which is
    /// how the quota disappeared off the island and came back on the next
    /// rebuild. Measured over the rows alone, so this needs no view.
    @Test func theIslandLineStatesItsOwnWidth() {
        typealias Row = UsageMeterView.Row
        let one = [Row(provider: "Claude", window: "", used: 16, trailing: "84% left")]
        let two = one + [Row(provider: "Codex", window: "", used: 97, trailing: "3% left")]

        let single = UsageMeterView.compactWidth(of: one)
        #expect(single > 60)
        // Two readings need room for two; this is the case that was being
        // squeezed to nothing when Codex crossed the line and joined Claude.
        #expect(UsageMeterView.compactWidth(of: two) > single)

        // A reading with no meter is narrower than the same one with a bar, and
        // still wider than nothing.
        let sentence = [Row(provider: "Claude", window: "", used: nil,
                            trailing: "~654k tok this 5h block")]
        let bare = UsageMeterView.compactWidth(of: sentence)
        #expect(bare > 0)
        #expect(UsageMeterView.compactWidth(of: []) == 0)
    }

    /// …and then stays inside the width it is *given*, which is a different
    /// number. The footer's stack hands the line whatever is left beside the ⋯
    /// button, and since macOS 14 nothing clips a view's drawing to its own
    /// bounds — so a Codex meter beside Claude's whole sentence drew straight
    /// through the button and out past the panel's rounded edge.
    @Test func theIslandLineStaysInsideTheWidthItIsGiven() {
        typealias Row = UsageMeterView.Row
        let rows = [
            Row(provider: "Codex", window: "", used: 42, trailing: "58% left"),
            Row(provider: "Claude", window: "", used: nil,
                trailing: "~605k tok this 5h block · resets 19:00 · the stored login is empty"),
        ]
        let given: CGFloat = 380
        #expect(UsageMeterView.compactWidth(of: rows) > given)   // the line that overflowed

        let placed = UsageMeterView.compactLayout(of: rows, in: given)
        #expect(!placed.isEmpty)
        for piece in placed {
            #expect(piece.width >= 0)
            #expect(piece.x + piece.width <= given)
        }
        // The sentence is cut short at the edge rather than dropped: it is the
        // one reading whose whole point is the words.
        #expect(placed.last.map { $0.x + $0.width } == given)
        guard case .trailing(let last)? = placed.last?.piece else {
            Issue.record("the sentence should be the last thing on the line"); return
        }
        #expect(last.contains("605k"))

        // Narrower than the first name: what is left lands inside, and the
        // pieces there is no room for are left out rather than drawn at zero
        // width past the edge — a meter's rounded cap has a minimum width.
        let cramped = UsageMeterView.compactLayout(of: rows, in: 30)
        #expect(cramped.count < placed.count)
        for piece in cramped {
            #expect(piece.width > 0)
            #expect(piece.x + piece.width <= 30)
        }

        // Asked for all the room it wants, nothing is trimmed at all.
        let wide = UsageMeterView.compactLayout(of: rows, in: 10_000)
        #expect(wide.count == placed.count)
        #expect(wide.last.map { $0.x + $0.width } == UsageMeterView.compactWidth(of: rows))
    }

    // MARK: - The signed-in web session

    /// WebKit initialises itself the first time anything touches it, and traps
    /// if that happens off the main thread. The usage refresh runs on its own
    /// serial queue, so reaching the cookie store from there took the whole app
    /// down inside `WebKit::InitializeWebKit2()` — and only once somebody was
    /// signed in, because until then the refresh stopped before it got that far.
    ///
    /// The hop has to be immediate when it is already home: the sign-in window
    /// polls for the cookie and closes itself on the answer, and deferring that
    /// would put a closed window's work after the window.
    @Test func theWebKitHopLandsOnTheMainThread() async {
        final class Flag: @unchecked Sendable { var value = false }
        let immediate = Flag()
        await MainActor.run { ClaudeWeb.onMain { immediate.value = true } }
        #expect(immediate.value)

        let landed: Bool = await withCheckedContinuation { c in
            DispatchQueue.global().async {
                ClaudeWeb.onMain { c.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(landed)
    }

    /// The usage call needs the account's uuid and nothing local knows it, so the
    /// first call is for the account — and the name travels with the number,
    /// because a percentage with the wrong account's name on it is worse than one
    /// with none.
    @Test func theAccountComesFromTheOrganisationsCall() throws {
        let body = """
        [{"uuid":"org-1","name":"Slevomat Group","capabilities":["chat"]},
         {"uuid":"org-2","name":"Personal"}]
        """
        let org = try #require(ClaudeWeb.organization(in: Data(body.utf8)))
        #expect(org.uuid == "org-1")
        #expect(org.name == "Slevomat Group")

        // An entry with no uuid is not an account we can ask about.
        let partial = #"[{"name":"no uuid"},{"uuid":"org-9"}]"#
        #expect(ClaudeWeb.organization(in: Data(partial.utf8))?.uuid == "org-9")
        #expect(ClaudeWeb.organization(in: Data("{}".utf8)) == nil)
        #expect(ClaudeWeb.organization(in: Data("nonsense".utf8)) == nil)
    }

    /// The web path's failures speak the same vocabulary as the token path's, so
    /// one sentence under the switch covers both doors.
    @Test func theWebPathFailsInTheSameWords() {
        #expect(ClaudeWebQuota.status(for: .noSession) == .loggedOut)
        #expect(ClaudeWebQuota.status(for: .declined(401))
                == .declined(code: 401, message: nil))
        #expect(ClaudeWebQuota.status(for: .unreachable) == .unreachable)
        #expect(ClaudeWebQuota.status(for: .unexpected(503)) == .unexpected(503))
    }

    /// The body claude.ai answers with has the shape the OAuth endpoint uses, so
    /// there is one parser and not two — worth a test, because the day that stops
    /// being true is the day this reads zeroes.
    @Test func bothDoorsShareOneParser() throws {
        let snap = try #require(ClaudeQuota.parse(Data(Self.payload.utf8), account: "Personal"))
        #expect(snap.windows.map(\.name) == ["5h", "weekly"])
        #expect(snap.account == "Personal")
    }

    // MARK: - Copilot's own ledger

    private func copilotDB(rows: [(created: String, nano: Int, input: Int, output: Int,
                                   cacheWrite: Int)]) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(base.appendingPathComponent("session-store.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE assistant_usage_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL,
                model TEXT NOT NULL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                total_nano_aiu INTEGER, created_at TEXT);
            """
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        for r in rows {
            let sql = """
                INSERT INTO assistant_usage_events (session_id, model, input_tokens,
                    output_tokens, cache_read_tokens, cache_write_tokens, total_nano_aiu, created_at)
                VALUES ('s', 'gpt-5.6', \(r.input), \(r.output), 999999, \(r.cacheWrite),
                        \(r.nano), '\(r.created)');
                """
            #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
        }
        return base
    }

    /// The day is a **local** day against a UTC column, so the boundary is a range
    /// and not a string prefix — a prefix takes somebody else's day on either side
    /// of midnight. Fixed to UTC here so the test means the same thing in Prague
    /// and in CI.
    @Test func copilotCountsOneLocalDayAndNoOther() throws {
        let utc = Self.utc
        let midnight = utc.startOfDay(for: Self.noon)
        let base = try copilotDB(rows: [
            (stamp(midnight.addingTimeInterval(-1)), 1_000_000_000, 10, 1, 0),      // yesterday
            (stamp(midnight.addingTimeInterval(1)), 2_000_000_000, 100, 10, 5),     // today
            (stamp(midnight.addingTimeInterval(19 * 3600)), 500_000_000, 200, 20, 5), // today
            (stamp(midnight.addingTimeInterval(86_401)), 9_000_000_000, 999, 99, 0), // tomorrow
        ])
        let spend = try #require(WeightReader.copilotSpend(day: Self.noon, calendar: utc, base: base))
        #expect(spend.events == 2)
        #expect(spend.nanoAIU == 2_500_000_000)
        // Cache reads stay out, exactly as they do in `Weight.total`.
        #expect(spend.tokens == 340)
    }

    @Test func copilotWithNoDatabaseSaysNothing() {
        let nowhere = URL(fileURLWithPath: "/tmp/agentbar-not-a-copilot-dir")
        #expect(WeightReader.copilotSpend(base: nowhere) == nil)
    }

    /// Every `~/.claude*` counts as a config directory, transcripts or not —
    /// the credential and the version marker live beside them, not inside
    /// `projects/`.
    @Test func claudeConfigDirsSeeMoreThanTranscriptFolders() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-home-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: home.appendingPathComponent(".claude/projects"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".claude-work"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: home.appendingPathComponent(".config"),
                               withIntermediateDirectories: true)
        let dirs = WeightReader.claudeConfigDirs(home: home).map(\.lastPathComponent)
        #expect(dirs == [".claude", ".claude-work"])
        #expect(WeightReader.claudeRoots(home: home).count == 1)
    }

    // MARK: - Numbers that came from somebody else's file

    /// `1e19` is an ordinary JSON number: finite, parseable, and past `Int.max`, so
    /// `Int(_:)` on it is not a wrong answer but a runtime trap. The reset time is
    /// the one number in a rollout that goes straight from the file into a `Date`
    /// and back out through `Int` in the redraw signature, which runs on every
    /// refresh — so a single silly timestamp took the app down rather than the row.
    /// A reset in the year 2286 is not a reset; the honest reading is no reset time.
    @Test func aResetTimeNobodyCouldMeetIsNotAResetTime() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: #"{"used_percent":40,"window_minutes":300,"resets_at":1e19}"#),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows.count == 1)
        #expect(usage.windows[0].usedPercent == 40)
        #expect(usage.windows[0].resetsAt == nil)
        // The signature is where the trap was, so it is the thing that must survive.
        _ = UsageCenter.signature(UsageCenter.Reading(provider: "codex", text: "",
                                                      windows: usage.windows))
    }

    /// The ordinary one still arrives, so the guard above is a ceiling and not a
    /// wholesale refusal to read reset times.
    @Test func anOrdinaryResetTimeStillArrives() throws {
        let tail = rollout([
            tokenCount(limitID: "codex",
                       primary: window(40, minutes: 300, resets: Self.noon.addingTimeInterval(1800))),
        ])
        let usage = try #require(UsageCenter.codexUsage(tail: tail, now: Self.noon))
        #expect(usage.windows[0].resetsAt == Self.noon.addingTimeInterval(1800))
    }
}

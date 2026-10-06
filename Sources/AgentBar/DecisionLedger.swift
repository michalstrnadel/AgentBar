import Foundation

/// What you decided about permission prompts, kept so the next prompt can say what
/// you did last time.
///
/// AgentBar sits in the permission path — the blocking hook is its own — which
/// means it is the only thing on the machine that can know this. Today it throws
/// every decision away the moment it is made: `RequestStore` never even learns
/// *why* a request vanished, only that it is gone. Two things become possible once
/// the decisions are kept:
///
/// - the card can say **"allowed 23× here"** at the moment you are deciding again,
///   which is the only place that fact is worth anything;
/// - the day can say how long agents spent **blocked on you**, which nothing else
///   measures because nothing else is standing at that door.
///
/// **It never decides anything itself.** A repeat count is offered next to the
/// *Always* button that was already there; the click stays yours. Since 1.28.0 one
/// thing does answer without a click — a rule the person wrote in Settings ▸
/// Approvals — and the way that stays honest is this file: every firing writes a
/// row naming the rule, and `firings(rule:in:)` is what the rules list reads back.
/// A rule is the person deciding in advance; this is where it is shown that they
/// did, and what came of it. See `RuleEngine`.
///
/// **What is not written here matters as much as what is.** `AgentActions.keystroke`
/// presses a key at a terminal for agents with no request file (Codex, Antigravity)
/// and never learns what the terminal did with it — recording that as "you allowed"
/// would be a claim this project does not get to make. So the ledger covers the
/// agents that speak `requests.d`: Claude Code and Copilot CLI. A plan approval is
/// likewise a keystroke, and likewise absent.
final class DecisionLedger {
    static let shared = DecisionLedger()

    static let fileURL = AgentBarHome.url("decisions.jsonl")

    /// The same span and ceiling `history.jsonl` keeps, for the same reasons.
    static let maxAge: TimeInterval = 30 * 86_400
    static let maxRecords = 5_000

    /// On by default — unlike sounds and notifications, nothing here appears on
    /// screen unprompted. It is a switch because `display` is a line of a command
    /// somebody may have typed a secret into, and anyone who would rather not keep
    /// that deserves a first-class way not to (`agentbar forget` empties it).
    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "rememberDecisions") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "rememberDecisions")
        }
        set { UserDefaults.standard.set(newValue, forKey: "rememberDecisions") }
    }

    private let url: URL
    /// Appends off the main thread, in order, exactly like `HistoryStore`: a
    /// decision is written while the user is watching the card disappear.
    private let writer = DispatchQueue(label: "agentbar.decisions", qos: .utility)

    init(url: URL = DecisionLedger.fileURL) { self.url = url }

    // MARK: - One decision

    struct Record: Equatable {
        var ts: TimeInterval = 0
        var agent = ""
        var sessionId = ""
        var project = ""
        var cwd = ""
        var tool = ""
        /// The normalised key repeats are counted by — see `shape(of:)`.
        var shape = ""
        /// The request's own one-line summary, for showing a person what a count
        /// refers to. Capped by the hook at ~60 characters before it ever gets here.
        var display = ""
        /// allow | always | deny | defer | answer | **watch**
        ///
        /// `watch` is not a verdict and nothing happened: a rule in its watching
        /// mode saw a request it matched and deliberately did not answer it. It is
        /// spelled as its own decision rather than as `allow` with a flag beside
        /// it, so that every counter that switches on the verdicts already skips
        /// it. A row that says `allow` when nothing was allowed is the kind of
        /// record this project does not write.
        var decision = ""
        /// For a `watch` row: what the rule would have answered. Empty otherwise.
        var would = ""
        /// How long the agent sat blocked before this landed. The half of the loop
        /// nobody measures.
        var waited: TimeInterval = 0
        /// app | cli | rule | claude — which frontend answered, or that nobody did:
        /// a rule the human wrote answered for them (`rule`), or Claude Code decided
        /// the call itself before any prompt existed and the AgentBar mod saw it
        /// (`claude`, see `ClaudeDecisionIngest`).
        var via = ""
        /// The id of the rule that answered, when `via` is "rule". This is what
        /// makes a rule auditable: the row names the decision it came from, so
        /// "what did this rule ever do" is a question with an answer.
        var rule = ""
        /// For a `claude` row: who in Claude Code decided — `rule` (a settings rule,
        /// named in `claudeRule`), `mode` (the permission mode or the tool's own
        /// check) or `hook` (a hook or another mod). Empty for every other `via`.
        var by = ""
        var claudeRule = ""
        /// Claude Code's own sentence about it, capped at 300 characters.
        var reason = ""
        /// The tool call's id. Unique: one row per id, ever — what keeps a sidecar
        /// read twice from becoming two decisions.
        var toolUseId = ""

        /// Whether a person made this decision. `rule` and `claude` rows are the
        /// two kinds nobody was asked about, and every count that is a claim about
        /// the person — "allowed 23× here", how long agents waited on you, whether
        /// you agreed with a watching rule — leaves them out (`docs/protocol.md`).
        /// Spelled as what it excludes rather than as `app`/`cli`, so a row written
        /// before `via` meant anything still counts as the person's, as it always did.
        var isPersonal: Bool { via != "rule" && via != "claude" }

        var json: [String: Any] {
            var o: [String: Any] = [
                "v": 1, "ts": Int(ts), "agent": agent, "sessionId": sessionId,
                "project": project, "cwd": cwd, "tool": tool, "shape": shape,
                "display": display, "decision": decision,
                "waited": Int(waited.rounded()), "via": via, "rule": rule, "would": would]
            // Only when there is something to say, so a row of any other kind is
            // byte for byte what it was before Claude Code's own decisions arrived.
            if !by.isEmpty { o["by"] = by }
            if !claudeRule.isEmpty { o["claudeRule"] = claudeRule }
            if !reason.isEmpty { o["reason"] = reason }
            if !toolUseId.isEmpty { o["toolUseId"] = toolUseId }
            return o
        }

        init() {}

        init?(jsonLine: String) {
            guard let data = jsonLine.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let shape = o["shape"] as? String, !shape.isEmpty,
                  let decision = o["decision"] as? String
            else { return nil }
            self.shape = shape
            self.decision = decision
            // Checked the way `waited` is below: `json` does `Int(ts)`, and prune runs
            // that on every row at launch. A time that is not a time (NaN, `1e19`,
            // past the year 3000) reads as none, which prune then drops as old
            // rather than trapping on.
            ts = Session.plausibleTime(o["ts"])
            agent = o["agent"] as? String ?? ""
            sessionId = o["sessionId"] as? String ?? ""
            project = o["project"] as? String ?? ""
            cwd = o["cwd"] as? String ?? ""
            tool = o["tool"] as? String ?? ""
            display = o["display"] as? String ?? ""
            // Clamped, not taken: this file is on somebody's disk, another tool can
            // append to it and a person can edit it, and `1e19` is an ordinary JSON
            // number that `Int(_:)` traps on rather than rounds — which the export
            // does to every row. A wait longer than a year is not a wait, so a row
            // carrying one is read as having none instead of taking the export down.
            let claimed = (o["waited"] as? NSNumber)?.doubleValue ?? 0
            waited = claimed.isFinite && claimed > 0 && claimed <= 31_536_000 ? claimed : 0
            via = o["via"] as? String ?? ""
            rule = o["rule"] as? String ?? ""
            would = o["would"] as? String ?? ""
            by = o["by"] as? String ?? ""
            claudeRule = o["claudeRule"] as? String ?? ""
            reason = o["reason"] as? String ?? ""
            toolUseId = o["toolUseId"] as? String ?? ""
        }
    }

    /// Records a decision that actually reached `answers.d`. Callers pass only what
    /// they already hold at the click; nothing here goes looking for more.
    func record(_ decision: String, request: ApprovalRequest, session: Session?,
                via: String = "app", rule: String = "", would: String = "",
                now: TimeInterval = Date().timeIntervalSince1970) {
        guard let r = row(decision, request: request, session: session, via: via,
                          rule: rule, would: would, now: now)
        else { return }
        writer.async { [url] in Self.append([r], to: url) }
    }

    /// A rule's answer, written down before it is given and on this thread. An
    /// answer nobody clicked may only exist with the row that names its rule
    /// (CLAUDE.md rule 3), so when the row cannot be written — a full disk, a
    /// read-only `~/.agentbar` — the caller gives no answer and the human decides.
    func recordNow(_ decision: String, request: ApprovalRequest, session: Session?,
                   via: String, rule: String,
                   now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let r = row(decision, request: request, session: session, via: via,
                          rule: rule, would: "", now: now)
        else { return false }
        return writer.sync { Self.append([r], to: url) }
    }

    private func row(_ decision: String, request: ApprovalRequest, session: Session?,
                     via: String, rule: String, would: String,
                     now: TimeInterval) -> Record? {
        // The switch is about the human's own clicks. A rule's firing is written
        // whatever it says: an answer nobody clicked is only allowed to exist
        // because it leaves a row naming the rule (CLAUDE.md rule 3), and a
        // watching rule with no rows can never be judged. Off, rules kept
        // approving and nothing anywhere said so.
        guard Self.enabled || via == "rule" else { return nil }
        var r = Record()
        r.ts = now
        r.agent = request.agentID
        r.sessionId = request.sessionId
        r.project = session?.project ?? ""
        // The hook carries the directory since 1.28.0; the session join is the
        // fallback for a request written by an older one.
        r.cwd = request.cwd.isEmpty ? (session?.cwd ?? "") : request.cwd
        r.tool = request.toolName
        r.shape = Self.shape(of: request)
        r.display = request.display
        r.decision = decision
        // A request whose `ts` is missing or in the future contributes no wait
        // rather than a negative one that would quietly shrink the day's total.
        r.waited = request.ts > 0 ? max(0, now - request.ts) : 0
        r.via = via
        r.rule = rule
        r.would = would
        return r
    }

    func flush() { writer.sync {} }

    // MARK: - Handing the record to somebody else

    /// The ledger as a spreadsheet.
    ///
    /// The point of keeping a record is being able to show it to someone — a
    /// reviewer, an auditor, yourself in three months — and `decisions.jsonl` is
    /// not that, however honest it is. One row per decision, oldest first, with the
    /// timestamp written out as a date rather than a number nobody can read.
    ///
    /// Watching rows are included and say so in `decision`: a week of what a rule
    /// *would* have done is exactly the evidence somebody would be asked for.
    static func csv(_ rows: [Record]) -> String {
        // `by` and `claude rule` sit before the wait, which stays last: they say
        // who inside Claude Code made one of its own decisions, and are empty on
        // every other row.
        let header = ["when", "agent", "directory", "tool", "shape", "what",
                      "decision", "would have", "answered by", "rule", "by", "claude rule",
                      "waited (s)"]
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        var out = [header.joined(separator: ",")]
        for r in rows.sorted(by: { $0.ts < $1.ts }) {
            out.append([
                stamp.string(from: Date(timeIntervalSince1970: r.ts)),
                r.agent, r.cwd, r.tool, r.shape, r.display,
                r.decision, r.would, r.via, r.rule, r.by, r.claudeRule,
                String(Int(r.waited.rounded())),
            ].map(quoted).joined(separator: ","))
        }
        return out.joined(separator: "\n") + "\n"
    }

    /// A CSV field that survives a comma, a quote, a newline — and a leading `=`,
    /// `+`, `-` or `@`, which a spreadsheet would otherwise read as a formula. The
    /// export carries commands somebody's agent wanted to run; handing that to
    /// Excel as something to evaluate is not a thing this file is going to do.
    static func quoted(_ field: String) -> String {
        var f = field
        if let first = f.first, "=+-@\t\r".contains(first) { f = "'" + f }
        return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - The shape a repeat is counted by

    /// The key two prompts are "the same prompt" under.
    ///
    /// It has to be coarse enough to repeat and specific enough to mean something:
    /// `git push` repeats, `git push origin feature/PR-4113` never does. It also has
    /// to be **free of arguments** — paths, URLs and flags are where a one-off
    /// lives, and where a secret would live if one ever got typed into a command.
    static func shape(of request: ApprovalRequest) -> String {
        var command: String?
        if case .bash(let c) = request.context { command = c }
        return shape(tool: request.toolName, command: command, filePath: filePath(of: request))
    }

    /// The same key for a call Claude Code decided itself, from what the mod keeps
    /// of its input (`mods.d`): `command` for Bash, `file_path` for the file tools.
    /// Through the same core as `shape(of:)`, so a rule's shape and a Claude Code
    /// decision's shape cannot drift apart. The CLI's `decisionShapeOfCall` mirrors
    /// it, held to it by `Tests/Fixtures/tool-shape`.
    static func shape(tool: String, input: [String: Any]) -> String {
        let command = tool == "Bash" ? (input["command"] as? String ?? "") : nil
        let path = ["file_path", "notebook_path", "path", "filePath"]
            .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty }
        return shape(tool: tool, command: command, filePath: path)
    }

    /// The one place a shape is made. `command` is non-nil for a shell command —
    /// even an empty one, which is `bash:` and never a tool.
    private static func shape(tool: String, command: String?, filePath: String?) -> String {
        if let command { return "bash:" + verb(of: command) }
        if let path = filePath { return "\(tool.lowercased()):\(folder(of: path))" }
        return "tool:" + tool
    }

    /// The first two words that matter. `git`, `npm` and friends are multiplexers —
    /// their verb is the second word, and collapsing `git push` into `git` would
    /// count a commit and a force-push as the same decision.
    static let multiplexers: Set<String> = [
        "git", "gh", "npm", "pnpm", "yarn", "bun", "cargo", "go", "docker", "kubectl",
        "brew", "make", "swift", "dotnet", "pip", "pip3", "uv", "poetry", "rails",
        "terraform", "aws", "gcloud", "systemctl", "apt", "apt-get", "flutter",
    ]

    static func verb(of command: String) -> String {
        // Only the first command of a pipeline or a chain: what follows is
        // consequence, and `cmd && rm -rf /` must never be counted as `cmd`.
        // By scalar: `\r\n` is one Character to Swift and would not equal "\n", so a
        // CRLF-joined second command used to stay in the head. `\r` splits too, as it
        // does in the CLI's `decisionVerb` — the two must cut the same head.
        let head = command.split(whereSeparator: { $0.unicodeScalars.contains { "|;&\r\n".unicodeScalars.contains($0) } })
            .first.map(String.init) ?? command
        var words = head.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        // Leading environment assignments and `sudo` are how the same command
        // arrives wearing a different hat.
        while let first = words.first,
              first == "sudo" || first == "command" || first == "env"
                || (first.contains("=") && !first.hasPrefix("-")) {
            words.removeFirst()
        }
        guard let head = words.first else { return "" }
        let name = (head as NSString).lastPathComponent
        guard Self.multiplexers.contains(name) else { return name }
        // The subcommand, if there is one that isn't a flag.
        guard let next = words.dropFirst().first(where: { !$0.hasPrefix("-") }) else { return name }
        return "\(name) \(next)"
    }

    /// The file this request names: the hook's own field when it wrote one, else
    /// read out of the tool input. The field is what keeps a large edit's shape
    /// the same as a small one's — the input is cut at 4 KB, and a cut is not JSON.
    static func filePath(of request: ApprovalRequest) -> String? {
        request.filePath.isEmpty ? filePath(in: request.toolInputPretty) : request.filePath
    }

    /// Tool inputs are JSON, capped at 4 KB by the hook. Edits and writes name a
    /// file in there; nothing else needs to be understood.
    static func filePath(in toolInputPretty: String) -> String? {
        guard let data = toolInputPretty.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["file_path", "notebook_path", "path", "filePath"] {
            if let p = o[key] as? String, !p.isEmpty { return p }
        }
        return nil
    }

    /// `Sources/AgentBar/Weight.swift` → `Sources/*.swift`. A directory and an
    /// extension repeat across a session's worth of edits; a file name does not,
    /// and a full path is both a one-off and somebody's home directory.
    static func folder(of path: String) -> String {
        let ext = (path as NSString).pathExtension
        let parts = path.split(separator: "/").map(String.init)
        // The last component is the file itself; the one before it is the local
        // neighbourhood, which is what repeats.
        let dir = parts.dropLast().last ?? ""
        let suffix = ext.isEmpty ? "*" : "*.\(ext)"
        return dir.isEmpty ? suffix : "\(dir)/\(suffix)"
    }

    // MARK: - What it adds up to

    struct Summary: Equatable {
        var allowed = 0
        var denied = 0
        var lastAt: TimeInterval = 0

        var total: Int { allowed + denied }
        var isEmpty: Bool { total == 0 }
    }

    /// How this exact shape was decided before, **in this repo**. A command that is
    /// routine in one checkout can be the opposite in another, so the count is
    /// scoped by working directory and says "here" when it is shown. With no
    /// directory to scope by, everything counts — that is the honest reading of
    /// "nobody knows where this ran".
    /// Rows a rule wrote are **not** counted here. The sentence this feeds says
    /// "Allowed 23× here", which is a claim about the person — and a rule that
    /// answered for them is precisely not them deciding again. Those rows are
    /// counted by `firings(rule:in:)`, under the rule that made them. Neither are
    /// Claude Code's own decisions: two hundred `git status` calls its settings
    /// allowed are not one thing you did, and must never earn an *Always* nudge or
    /// a rule offer.
    static func summary(shape: String, cwd: String, in records: [Record]) -> Summary {
        var out = Summary()
        for r in records where r.shape == shape && r.isPersonal
            && (cwd.isEmpty || r.cwd == cwd) {
            switch r.decision {
            case "allow", "always": out.allowed += 1
            case "deny": out.denied += 1
            default: continue          // defer and answer are not verdicts
            }
            out.lastAt = max(out.lastAt, r.ts)
        }
        return out
    }

    /// "Allowed 23× here · last Tue". Nil below two, because "allowed 1× here" is
    /// the thing you just did and tells you nothing.
    static func hint(_ s: Summary, now: Date = Date()) -> String? {
        guard s.total >= 2 else { return nil }
        var parts: [String] = []
        if s.allowed > 0 { parts.append("Allowed \(s.allowed)×") }
        if s.denied > 0 { parts.append("denied \(s.denied)×") }
        var text = parts.joined(separator: ", ") + " here"
        if s.lastAt > 0 { text += " · last \(ago(Date(timeIntervalSince1970: s.lastAt), now: now))" }
        return text
    }

    /// A weekday inside the week, a date beyond it. "last Tue" is a memory; "last
    /// 14 days ago" is arithmetic.
    static func ago(_ d: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        let days = now.timeIntervalSince(d) / 86_400
        if days < 1, Calendar.current.isDate(d, inSameDayAs: now) { return "today" }
        if days < 6 { f.dateFormat = "EEE" } else { f.dateFormat = "d MMM" }
        return f.string(from: d)
    }

    /// Enough repeats, never refused, and a rule Claude Code itself suggested: the
    /// *Always* button is worth pointing at. It is still a button somebody has to
    /// press — a count is not consent.
    static let promoteAfter = 5

    static func shouldPromoteAlways(_ s: Summary, hasRule: Bool) -> Bool {
        hasRule && s.denied == 0 && s.allowed >= promoteAfter
    }

    /// Whether a rule is worth offering for this prompt, and which way it would go.
    ///
    /// Note what is NOT a condition: a `ruleSuggestion`. `shouldPromoteAlways`
    /// needs one because *Always* pins a permission Claude Code offered. A rule of
    /// ours is the opposite kind of object — it is written from what the person
    /// repeatedly did, and it must never originate in anything the agent produced.
    /// That is the same posture as never reading a token out of a record by key
    /// name: do not trust content made by the thing you are guarding.
    ///
    /// Only when the answer has been the same every single time. A prompt someone
    /// has allowed nine times and refused once is exactly the prompt that still
    /// deserves to be asked.
    static func shouldOfferRule(_ s: Summary) -> String? {
        if s.denied == 0, s.allowed >= promoteAfter { return "allow" }
        if s.allowed == 0, s.denied >= promoteAfter { return "deny" }
        return nil
    }

    /// What one rule has actually done. The rules file holds the intent and never
    /// a counter; this is where "fired 12× · last today" comes from, so the audit
    /// stays the single source of truth about what happened.
    static func firings(rule id: String, in records: [Record]) -> Summary {
        var out = Summary()
        for r in records where r.rule == id && r.via == "rule" {
            switch r.decision {
            case "allow": out.allowed += 1
            case "deny":  out.denied += 1
            default:      continue          // `watch` is not something it did
            }
            out.lastAt = max(out.lastAt, r.ts)
        }
        return out
    }

    /// What a watching rule **would** have done. The whole point of the mode: a
    /// week of this is how somebody finds out an approving rule matches what they
    /// pictured, without it having approved anything yet.
    static func wouldHave(rule id: String, in records: [Record]) -> Summary {
        var out = Summary()
        for r in records where r.rule == id && r.decision == "watch" {
            switch r.would {
            case "allow": out.allowed += 1
            case "deny":  out.denied += 1
            default:      continue
            }
            out.lastAt = max(out.lastAt, r.ts)
        }
        return out
    }

    // MARK: - Whether you agreed with it

    /// What a watching rule's evidence actually says: not how often it matched,
    /// but whether **you**, answering the same prompt, did what it would have done.
    struct Agreement: Equatable {
        /// You answered the prompt the way the rule would have.
        var agreed = 0
        /// You answered it the other way.
        var disagreed = 0
        /// Nothing in the ledger says what you did: answered at the terminal, by a
        /// keystroke, or left to time out. Those write no row, so they are counted
        /// apart and never as agreement — an absence is not a yes.
        var unwitnessed = 0
        /// Distinct local calendar days the agreements fall on.
        var days = 0
        var firstAt: TimeInterval = 0
        var lastAt: TimeInterval = 0
        /// Your row, the most recent time you went the other way.
        var lastDisagreement: Record?

        var witnessed: Int { agreed + disagreed }
        var total: Int { witnessed + unwitnessed }
    }

    /// How long after a watch row the human's answer to the same prompt may land.
    /// `permission.js` waits 600 s by default and then hands the prompt back to the
    /// terminal, after which there is no card left to answer in AgentBar — so a
    /// row later than that is a different prompt. Fifteen minutes covers the
    /// default wait with room for a raised `AGENTBAR_APPROVAL_TIMEOUT`, and the
    /// one-to-one pairing below keeps a later identical prompt's answer from being
    /// counted for two watch rows.
    static let agreementWindow: TimeInterval = 15 * 60

    /// Pairs each `watch` row of one rule with the human's answer to the same
    /// prompt: the first unclaimed row a person wrote (`isPersonal`: not a rule, not Claude Code) with
    /// a verdict (`allow`, `always`, `deny` — `defer` and `answer` are not
    /// verdicts), in the same session, for the same tool and shape, no earlier
    /// than the watch row and within `agreementWindow` of it. `always` is an allow.
    ///
    /// The ledger carries no request id, so "the same prompt" is the closest thing
    /// it can prove: same session, same shape, moments later. A session id that is
    /// empty proves nothing and is never matched. Each human row witnesses at most
    /// one watch row, taken in time order, so two identical prompts pending at
    /// once pair off rather than both claiming the first answer.
    ///
    /// `since` drops watch rows older than it — the rule's last save, because rows
    /// from before an edit were about a rule that no longer exists.
    static func agreement(rule id: String, in records: [Record], since: TimeInterval = 0,
                          calendar: Calendar = .current) -> Agreement {
        var out = Agreement()
        let watches = records.enumerated()
            .filter { $0.element.rule == id && $0.element.decision == "watch"
                      && $0.element.ts >= since }
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
        // The human's verdicts, oldest first, by index so a claimed one stays claimed.
        let answers = records.enumerated()
            .filter { $0.element.isPersonal && !$0.element.sessionId.isEmpty
                      && ["allow", "always", "deny"].contains($0.element.decision) }
            .sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }
        var claimed = Set<Int>()
        var days = Set<DateComponents>()
        for (_, w) in watches {
            out.firstAt = out.firstAt == 0 ? w.ts : min(out.firstAt, w.ts)
            out.lastAt = max(out.lastAt, w.ts)
            let match = w.sessionId.isEmpty ? nil : answers.first { candidate in
                let a = candidate.element
                return !claimed.contains(candidate.offset) && a.sessionId == w.sessionId
                    && a.shape == w.shape && a.tool == w.tool
                    && a.ts >= w.ts && a.ts - w.ts <= agreementWindow
            }
            guard let found = match else {
                out.unwitnessed += 1
                continue
            }
            claimed.insert(found.offset)
            let a = found.element
            let did = a.decision == "deny" ? "deny" : "allow"
            if did == w.would {
                out.agreed += 1
                days.insert(calendar.dateComponents([.year, .month, .day],
                                                    from: Date(timeIntervalSince1970: w.ts)))
            } else {
                out.disagreed += 1
                if a.ts >= (out.lastDisagreement?.ts ?? 0) { out.lastDisagreement = a }
            }
        }
        out.days = days.count
        return out
    }

    /// Enough agreement to offer the "Let it answer" button. Ten, because a rule
    /// that has matched a handful of times has not yet met the prompt it gets
    /// wrong; three days, because one long afternoon in one task is one context,
    /// and a rule that is going to answer for you meets all of them. A single
    /// disagreement blocks it outright: a prompt you answered the other way even
    /// once is a prompt that still deserves to be asked. The button is an offer —
    /// switching is still a click, and nothing here switches anything.
    static let letItAnswerAfterAgreements = 10
    static let letItAnswerAcrossDays = 3

    static func canLetItAnswer(_ a: Agreement) -> Bool {
        a.disagreed == 0 && a.agreed >= letItAnswerAfterAgreements
            && a.days >= letItAnswerAcrossDays
    }

    /// "you did the same 13×, the other way 1×" — the half of a watching rule's line
    /// that says whether it matched you, not just whether it matched. Nil when you
    /// have answered none of its prompts here and they are too few to say so.
    static func agreementClause(_ a: Agreement) -> String? {
        var parts: [String] = []
        if a.agreed > 0 { parts.append("you did the same \(a.agreed)×") }
        if a.disagreed > 0 {
            parts.append(a.agreed > 0 ? "the other way \(a.disagreed)×"
                                      : "you went the other way \(a.disagreed)×")
        }
        // Mentioned only when it is most of the story: otherwise "13 the same" next
        // to a would-have count of 14 already says one went unseen.
        if a.unwitnessed > a.witnessed {
            parts.append(a.witnessed == 0 ? "none answered here yet"
                                          : "\(a.unwitnessed)× not answered here")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "Allowed 12× · last today" for a rule's row. Unlike `hint`, one firing is
    /// worth saying: it is the first proof the rule does what it says.
    static func firingLine(_ s: Summary, wouldHave: Bool = false, now: Date = Date()) -> String {
        guard !s.isEmpty else {
            return wouldHave ? "Nothing has matched it yet" : "Never fired yet"
        }
        var parts: [String] = []
        if s.allowed > 0 { parts.append("\(wouldHave ? "Would have allowed" : "Allowed") \(s.allowed)×") }
        if s.denied > 0 { parts.append("\(wouldHave ? "would have denied" : "Denied") \(s.denied)×") }
        var text = parts.joined(separator: ", ")
        if s.lastAt > 0 { text += " · last \(ago(Date(timeIntervalSince1970: s.lastAt), now: now))" }
        return text
    }

    /// How many decisions in a span were made by a rule rather than by a person.
    /// The day's account says both, because "18 answered" that quietly included
    /// six a rule made would be the wrong number in the most important place.
    static func byRules(in records: [Record], since: TimeInterval, until: TimeInterval) -> Int {
        records.filter {
            $0.ts >= since && $0.ts <= until && $0.via == "rule" && $0.decision != "watch"
        }.count
    }

    /// How long agents sat blocked on the human over a span. The other half of the
    /// day's account: `history.jsonl` says how long the machine worked, and this
    /// says how long it waited.
    static func waiting(in records: [Record], since: TimeInterval, until: TimeInterval)
    -> (answered: Int, waited: TimeInterval) {
        var out = (answered: 0, waited: TimeInterval(0))
        // A rule answers in milliseconds and nobody was asked, so counting its
        // rows here would inflate "18 answered" with decisions the person never
        // made and deflate the average wait with times nobody waited.
        // Claude Code's own decisions likewise: nobody was asked and nobody waited.
        for r in records where r.ts >= since && r.ts <= until && r.isPersonal {
            out.answered += 1
            out.waited += r.waited
        }
        return out
    }

    // MARK: - Reading and writing the file

    /// Every line that still parses, oldest first. Unlike `history.jsonl` nothing
    /// collapses here: two decisions about the same command are two decisions, and
    /// counting them is the entire point.
    static func read(url: URL = DecisionLedger.fileURL) -> [Record] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { Record(jsonLine: String($0)) }
    }

    /// `read()` memoised on `(mtime, size)`, for the same reason `HistoryStore` has
    /// one: an approval card is rebuilt about once a second while a request is open.
    static func cached(url: URL = DecisionLedger.fileURL) -> [Record] {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = ((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
                     (attrs?[.size] as? Int) ?? 0)
        cacheLock.lock()
        if let c = cache, c.url == url.path, c.stamp == stamp { cacheLock.unlock(); return c.records }
        cacheLock.unlock()
        // Parsed outside the lock: an approval card on the main thread must not wait
        // behind the ingest queue reading the same month of rows.
        let records = read(url: url)
        cacheLock.lock()
        cache = (url.path, stamp, records)
        cacheLock.unlock()
        return records
    }

    private static let cacheLock = NSLock()
    private static var cache: (url: String, stamp: (TimeInterval, Int), records: [Record])?

    /// Held by every append and by prune. Prune reads the file and replaces it; an
    /// append that landed between the two went to the file being replaced and was
    /// gone — a rule's row included, which is the row rule 3 promises always exists.
    static let fileLock = NSLock()

    /// Posted on the main queue after rows were appended, by anyone — a click, a
    /// rule, or Claude Code's own decisions arriving from `mods.d`. A view showing
    /// counts from the ledger listens here instead of waiting to be shown again.
    static let didAppend = Notification.Name("AgentBarDecisionLedgerDidAppend")

    /// True only when every byte reached the file.
    @discardableResult
    static func append(_ records: [Record], to url: URL = DecisionLedger.fileURL) -> Bool {
        let lines = records.compactMap { r -> String? in
            guard let data = try? JSONSerialization.data(withJSONObject: r.json,
                                                         options: [.sortedKeys]),
                  let line = String(data: data, encoding: .utf8)
            else { return nil }
            return line + "\n"
        }
        guard !lines.isEmpty, let data = lines.joined().data(using: .utf8) else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        // O_APPEND, like the history: the app and a CLI on a shared home must not be
        // able to truncate each other.
        fileLock.lock()
        defer { fileLock.unlock() }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else {
            NSLog("AgentBar: decisions.jsonl could not be opened (errno %d)", errno)
            return false
        }
        defer { close(fd) }
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            NSLog("AgentBar: decisions.jsonl took %d of %d bytes", written, data.count)
            return false
        }
        DispatchQueue.main.async { NotificationCenter.default.post(name: didAppend, object: nil) }
        return true
    }

    /// Claude Code's own decisions have a ceiling of their own. A busy day can
    /// write hundreds of them, and under one shared ceiling they would push the
    /// person's own record out — the half this file exists for.
    static let maxClaudeRecords = 5_000

    static func prune(url: URL = DecisionLedger.fileURL,
                      now: TimeInterval = Date().timeIntervalSince1970) {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        // A line this version cannot read — a row from a newer AgentBar, a hand edit
        // gone wrong — is not this version's to delete. It stays, word for word, and
        // only rows that were understood are aged out.
        let unread = lines.filter { Record(jsonLine: $0) == nil }
        let all = lines.compactMap { Record(jsonLine: $0) }
        let fresh = all.enumerated().filter { now - $0.element.ts <= maxAge }
        var own = fresh.filter { $0.element.via != "claude" }
        var claude = fresh.filter { $0.element.via == "claude" }
        if own.count > maxRecords { own = Array(own.suffix(maxRecords)) }
        if claude.count > maxClaudeRecords { claude = Array(claude.suffix(maxClaudeRecords)) }
        // Back in file order: the two ceilings choose what stays, not where it sits.
        let kept = (own + claude).sorted { $0.offset < $1.offset }.map(\.element)
        guard kept.count != all.count else { return }
        let body = kept.compactMap { r -> String? in
            guard let d = try? JSONSerialization.data(withJSONObject: r.json,
                                                      options: [.sortedKeys])
            else { return nil }
            return String(data: d, encoding: .utf8)
        }
        let out = (unread + body).joined(separator: "\n")
        do {
            try (out.isEmpty ? "" : out + "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("AgentBar: decisions.jsonl was not pruned: \(error)")
        }
    }
}

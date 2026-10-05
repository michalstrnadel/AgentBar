import Foundation

/// One `mods.d/<session_id>.json`, as the AgentBar Claude Code mod writes it
/// (`docs/protocol.md`, "mods.d"): what Claude Code measures about a session —
/// its context, the account's rate limits — and the calls it decided without
/// asking anybody.
///
/// Pure: bytes in, a value or nil out. Everything a stranger could put in the file
/// is checked here, where it enters, the way `Session.plausibleTime` checks a row's
/// times. The mod is ours, but the folder is anybody's, and this is the one file in
/// the protocol that is rewritten in place — a reader can catch it half-written.
/// A file that does not parse, or says something that is not a sidecar, is nil;
/// what to do about that (keep the last good one) is the caller's business.
struct ModReport: Equatable {
    struct Context: Equatable {
        /// 0…100, rounded. Nil when Claude Code did not say — never zero for "unknown".
        var percent: Int?
        var tokens: Int?
        var window: Int?
    }

    struct RateLimit: Equatable {
        /// Claude Code's own name: `five_hour`, `seven_day`, …
        var kind: String
        /// Not clamped to 100: an exceeded spend limit is reported past it, and
        /// that is the reading. Clamped to what a meter can draw where it is drawn.
        var percentUsed: Double
        var resetsAt: Date?
    }

    /// One verdict Claude Code reached without a prompt.
    struct Decision: Equatable {
        var id: String
        var ts: TimeInterval
        var tool: String
        var command = ""
        var filePath = ""
        var url = ""
        var description = ""
        /// allow | deny — nothing else is a verdict here.
        var verdict: String
        /// rule | mode | hook | auto — who decided, as far as can be told.
        var by: String
        /// The settings rule, when `by` is "rule". Empty otherwise.
        var rule = ""
        var reason = ""
    }

    var sessionId: String
    var ts: TimeInterval
    var cwd = ""
    var mod = ""
    var ended = false
    var context: Context?
    var rateLimits: [RateLimit] = []
    var subagents = 0
    var decisions: [Decision] = []
    /// A call held before it runs — a mod waiting on the person in its own pane.
    var held: Held?

    struct Held: Equatable {
        var tool: String
        var command = ""
        var filePath = ""
        var since: TimeInterval
    }

    // MARK: - Caps

    /// The protocol's own ceilings, applied again on the way in: the mod caps
    /// input fields at 2 KB and keeps 200 decisions; a file claiming more was not
    /// written by it, and is cut rather than believed.
    static let maxField = 2_048
    static let maxReason = 300
    static let maxRule = 256
    static let maxDecisions = 200
    static let maxRateLimits = 8
    /// A sidecar of 200 capped decisions stays well under this. Anything larger is
    /// not one, and is not read into memory to find out.
    static let maxBytes = 4 * 1_024 * 1_024

    static let verdicts: Set<String> = ["allow", "deny"]
    static let deciders: Set<String> = ["rule", "mode", "hook", "auto"]

    // MARK: - Decoding

    /// The report in `data`, for the session the file is named after. Nil for a
    /// torn write, a version this reader does not know, or a file that names a
    /// different session than the one it is filed under.
    static func decode(_ data: Data, sessionId: String) -> ModReport? {
        guard !data.isEmpty, data.count <= maxBytes,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              int(o["v"]) == 1
        else { return nil }
        // The file is joined to its session by name. One that says it belongs to
        // another session is a copy, or a mistake, and either way not this one's.
        if let named = o["session_id"] {
            guard let s = named as? String, s == sessionId else { return nil }
        }
        if let agent = o["agent"], (agent as? String) != "claude" { return nil }
        let ts = Session.plausibleTime(o["ts"])
        guard ts > 0 else { return nil }

        var r = ModReport(sessionId: sessionId, ts: ts)
        r.cwd = text(o["cwd"], cap: 4_096)
        r.mod = text(o["mod"], cap: 32)
        r.ended = bool(o["ended"])
        r.context = context(o["context"])
        r.rateLimits = (o["rate_limits"] as? [Any] ?? []).prefix(maxRateLimits)
            .compactMap(rateLimit)
        r.subagents = int(o["subagents"]).map { min(max($0, 0), 999) } ?? 0
        r.held = held(o["held"])
        var seen = Set<String>()
        // The newest end of the ring: a file listing more than the mod keeps
        // loses the oldest, the way the mod's own ring would have.
        let raw = (o["decisions"] as? [Any] ?? []).suffix(maxDecisions)
        r.decisions = raw.compactMap { decision($0, fallbackTs: ts) }
            .filter { seen.insert($0.id).inserted }
        return r
    }

    private static func context(_ any: Any?) -> Context? {
        guard let o = any as? [String: Any] else { return nil }
        var c = Context()
        if let p = number(o["percent"]) { c.percent = Int(min(max(p, 0), 100).rounded()) }
        // Tokens and windows are counts. Past a billion they are not tokens.
        if let t = number(o["tokens"]), t >= 0, t < 1e9 { c.tokens = Int(t) }
        if let w = number(o["window"]), w > 0, w < 1e9 { c.window = Int(w) }
        return c.percent == nil && c.tokens == nil && c.window == nil ? nil : c
    }

    private static func held(_ any: Any?) -> Held? {
        guard let o = any as? [String: Any],
              let tool = o["tool"] as? String, !tool.isEmpty else { return nil }
        let since = Session.plausibleTime(o["since"])
        guard since > 0 else { return nil }
        let input = o["input"] as? [String: Any] ?? [:]
        return Held(tool: oneLine(tool, cap: 128),
                    command: oneLine(text(input["command"], cap: maxField), cap: maxField),
                    filePath: oneLine(text(input["file_path"], cap: maxField), cap: maxField),
                    since: since)
    }

    private static func rateLimit(_ any: Any) -> RateLimit? {
        guard let o = any as? [String: Any],
              let kind = o["kind"] as? String, !kind.isEmpty, kind.count <= 32,
              kind.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }),
              let used = number(o["percent_used"]), used >= 0, used <= 10_000
        else { return nil }
        return RateLimit(kind: kind, percentUsed: used, resetsAt: resetTime(o["resets_at"]))
    }

    private static func decision(_ any: Any, fallbackTs: TimeInterval) -> Decision? {
        guard let o = any as? [String: Any],
              let id = o["id"] as? String, !id.isEmpty, id.count <= 128,
              !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                                                    || $0 == " " }),
              let tool = o["tool"] as? String, !tool.isEmpty, tool.count <= 128,
              let verdict = o["verdict"] as? String, verdicts.contains(verdict),
              let by = o["by"] as? String, deciders.contains(by)
        else { return nil }
        let stamp = Session.plausibleTime(o["ts"])
        var d = Decision(id: id, ts: stamp > 0 ? stamp : fallbackTs, tool: oneLine(tool, cap: 128),
                         verdict: verdict, by: by)
        let input = o["input"] as? [String: Any] ?? [:]
        d.command = text(input["command"], cap: maxField)
        d.filePath = text(input["file_path"], cap: maxField)
        d.url = text(input["url"], cap: maxField)
        d.description = text(input["description"], cap: maxField)
        // A rule is named only when a rule decided; anything else carrying one
        // would put a name on a decision it did not make.
        d.rule = by == "rule" ? oneLine(text(o["rule"], cap: maxRule), cap: maxRule) : ""
        d.reason = oneLine(text(o["reason"], cap: maxReason), cap: maxReason)
        return d
    }

    // MARK: - Pieces

    /// An integer, and only a number that is one: `true` is not `1` here.
    private static func int(_ any: Any?) -> Int? {
        guard let n = number(any), n == n.rounded(), abs(n) < 1e15 else { return nil }
        return Int(n)
    }

    private static func number(_ any: Any?) -> Double? {
        guard let n = any as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }

    private static func bool(_ any: Any?) -> Bool {
        guard let n = any as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    private static func text(_ any: Any?, cap: Int) -> String {
        guard let s = any as? String else { return "" }
        return s.count > cap ? String(s.prefix(cap)) : s
    }

    /// First line, control characters dropped, capped. For fields that end up on
    /// one line of a card or a spreadsheet cell.
    static func oneLine(_ s: String, cap: Int) -> String {
        let first = s.split(omittingEmptySubsequences: false,
                            whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" }).first
            .map(String.init) ?? ""
        let kept = String(String.UnicodeScalarView(first.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })).trimmingCharacters(in: .whitespaces)
        return kept.count > cap ? String(kept.prefix(cap)) : kept
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    private static let isoLock = NSLock()

    /// An ISO-8601 string, or Unix seconds; through `UsageCenter.resetTime` either
    /// way, so a silly year is no reset time rather than a trap later.
    private static func resetTime(_ any: Any?) -> Date? {
        if let s = any as? String {
            isoLock.lock(); defer { isoLock.unlock() }
            guard let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) else { return nil }
            return UsageCenter.resetTime(d.timeIntervalSince1970)
        }
        return number(any).flatMap(UsageCenter.resetTime)
    }
}

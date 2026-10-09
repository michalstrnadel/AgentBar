import Foundation
import Security

/// Claude Code's quota windows — the one number on this machine that cannot be
/// read off the disk.
///
/// Everything else AgentBar shows about spending comes from a file: Codex writes
/// its exact percentages into every rollout, Copilot keeps its spend in a SQLite
/// database, Claude's transcripts carry tokens. Claude's *windows* are not
/// written anywhere local — checked across every `~/.claude*` config on this
/// machine, twice — so the choice was to keep showing half an answer or to ask
/// Anthropic the same question Claude Code itself asks. This asks, and only when
/// switched on.
///
/// The rules this file exists to keep:
///
/// - **Off until asked.** `enabled` is false by default and nothing here runs
///   until it is true. It is the second network call the app can make, and the
///   README says so in the same breath as the first.
/// - **The token is borrowed, never kept.** Claude Code's own login is read at the
///   moment of the call, never cached in memory between calls, never written
///   anywhere, and never put into a string that could reach a label, a log or a
///   crash report. The one exception is a token *you* hand over on purpose —
///   `claude setup-token`, pasted into Settings — which is kept, because there is
///   no other way to hold onto something the CLI did not store for us. It goes in
///   AgentBar's own Keychain item (the ntfy token of `PhoneRelay` is the only
///   other one), and **Remove** takes it out again. Nothing is ever written to a file.
///   This exists because a machine whose sessions run under their own
///   `CLAUDE_CONFIG_DIR` keeps its login somewhere AgentBar cannot read, and
///   "switch it on and get nothing forever" is not an answer.
/// - **Nothing on a clock raises a permission dialog.** Claude Code's record
///   belongs to another application, so the first read of it brings up macOS's
///   own password prompt — and that prompt returns after every reinstall. A
///   five-minute refresh allowed to raise it would meet somebody shipping ten
///   builds a day ten times over, and somebody who once pressed Deny every five
///   minutes thereafter. So only a press asks; a success is remembered and the
///   clock reads quietly from then on, a refusal shuts the door until the next
///   press. The two credentials that cost nobody a dialog — a signed-in
///   claude.ai session, a token pasted in on purpose — are read on the clock
///   like anything else.
/// - **AgentBar never refreshes it.** That is Claude Code's job; two processes
///   racing on one refresh token is how people get logged out. An expired token
///   means no reading until the CLI renews it on its own next run.
/// - **Every failure is silent where the number would have been.** A refused
///   Keychain prompt, no credential, a 401, a 429, no network — all end the same
///   way on the island and in the menu block: no reading, and the local token
///   line stays where it was. A quota line that turns into an error message is an
///   error message sitting where a number used to be.
/// - **And never silent next to the switch.** Silence there is a different
///   thing: a switch that does nothing and says nothing is indistinguishable from
///   a broken one, and the first person to meet that was the one who turned it
///   on. So every attempt leaves a `Status` behind, Settings says it in a
///   sentence, and *Check now* asks again on demand — which is also the only
///   thing in this app that opens Claude Code's Keychain record, and so the only
///   thing that can raise the password dialog.
final class ClaudeQuota {
    static let shared = ClaudeQuota()

    // MARK: - The switch

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeQuotaNetwork") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeQuotaNetwork") }
    }

    /// Whether the five-minute refresh may read **Claude Code's** Keychain
    /// record — another application's item, whose first read raises the system's
    /// "AgentBar wants to use an item in your keychain, enter your password"
    /// dialog.
    ///
    /// Off until a deliberate press has been answered with Allow, and off again
    /// the moment macOS refuses. Nothing on a clock may raise that dialog: an
    /// answer of Deny was not remembered, so a person who dismissed it once met
    /// it again five minutes later, and forever after. The switch turns the
    /// reading on; only a button opens that door.
    static var keychainAllowed: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeQuotaKeychain") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeQuotaKeychain") }
    }

    // MARK: - What comes back

    struct Snapshot: Equatable {
        /// `UsageWindow`, not a type of this file's own: the meter draws Codex and
        /// Claude with the same code, and two structs of the same shape would
        /// drift the first time one of them learned something.
        let windows: [UsageWindow]
        /// Which login the number belongs to. A machine can carry several
        /// `~/.claude*` configs, and a percentage with no owner is a lie on all
        /// but one of them.
        let account: String?
        let at: Date
    }

    // MARK: - Why there is no number

    /// What the last attempt came to. Every case names a cause somebody can act
    /// on — or, in two of them, one nobody has to: an expired token is Claude
    /// Code's to renew and a rate limit passes by itself.
    ///
    /// No case carries anything from the credential. The token is borrowed for
    /// the length of one request and the reason it failed is all that outlives
    /// it.
    /// `Error` so a failed lookup can be a `Result`'s failure — this type names
    /// what went wrong, which is the whole job of an error.
    enum Status: Equatable, Error {
        case off
        /// On, with nothing back yet — including the moment the Keychain prompt
        /// is on screen waiting to be answered.
        case asking
        case ok(at: Date, account: String?)
        /// Neither the Keychain nor any `~/.claude*` holds a login.
        case noCredential
        /// The record exists and Claude's section of it is empty: signed out.
        /// A session running under its own `CLAUDE_CONFIG_DIR` keeps its login
        /// elsewhere, so this is also what a machine looks like when the config
        /// AgentBar can read is not the one being used.
        case loggedOut
        /// There may well be a login in Claude Code's Keychain record, and
        /// AgentBar has not asked for it — asking is what raises the password
        /// dialog. *Check now* asks; the clock never does.
        case notAsked
        /// macOS was asked and did not hand it over: the prompt was refused,
        /// dismissed, or never shown. Carries the `OSStatus` because the number
        /// is the only thing that tells those apart.
        case refused(OSStatus)
        /// The stored login is past its expiry, and when it went. AgentBar never
        /// refreshes it — two processes racing on one refresh token is how
        /// people get logged out — so this clears when the CLI next runs. The
        /// date is in the sentence because "expired" alone cannot tell a token
        /// that lapsed this morning from a timestamp being read in the wrong
        /// unit, and the second one is a bug in this file.
        case expiredToken(at: Date)
        /// A 401 or 403: the login exists and Anthropic would not take it.
        /// Carries the code and, where the answer had one, the server's own
        /// message — this endpoint is not a published API, and its own sentence
        /// is worth more than any guess this file could make about it.
        case declined(code: Int, message: String?)
        case rateLimited(until: Date)
        case unreachable
        case unexpected(Int)
    }

    /// The last outcome. Written from the fetch's completion, read from the main
    /// thread, so it sits behind the same lock as everything else here.
    private var _status: Status = .off
    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }
    /// Fired on the main queue whenever the status changes. One observer,
    /// because there is one place this belongs: the window with the switch in
    /// it.
    var onStatus: (() -> Void)?

    /// Always called with the lock held; the callback goes out after it, on the
    /// main queue, so an observer can read `status` without deadlocking on the
    /// thread that changed it.
    private func set(_ new: Status) {
        guard _status != new else { return }
        _status = new
        DispatchQueue.main.async { [weak self] in self?.onStatus?() }
    }

    // MARK: - State

    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var nextAllowed = Date.distantPast
    private var inFlight = false

    /// The documented safe floor for this endpoint is 180 s; five minutes is
    /// well clear of it and still fresh enough for a window that moves over
    /// hours.
    private static let interval: TimeInterval = 300
    /// Past this the number is old enough to be wrong, and silence beats a stale
    /// percentage — the same stance `UsageCenter` takes for Codex.
    private static let maxAge: TimeInterval = 30 * 60
    /// 429 backs off hard and recovers slowly. The endpoint has a punishing
    /// bucket for callers it does not recognise, and hammering it is how a
    /// borrowed token gets the person's own CLI throttled.
    private static let backoffSteps: [TimeInterval] = [600, 1200, 1800]
    private var backoffStep = 0

    /// The freshest reading, or nil when there isn't one worth showing.
    func latest(now: Date = Date()) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let s = snapshot, now.timeIntervalSince(s.at) < Self.maxAge else { return nil }
        return s
    }

    /// Fetch if the switch is on and enough time has passed. `changed` fires on
    /// an arbitrary queue, and only when there is something new to draw.
    func refreshIfDue(now: Date = Date(), deliberate: Bool = false,
                      changed: @escaping () -> Void) {
        // A signed-in claude.ai session answers the same question for the same
        // account without a Keychain anywhere near it. Both paths asking at once
        // would double the traffic to buy nothing — and would raise a password
        // prompt for a number already on screen.
        guard Self.enabled, !ClaudeWeb.connected else {
            lock.lock(); snapshot = nil; set(.off); lock.unlock()
            return
        }
        lock.lock()
        guard !inFlight, now >= nextAllowed else { lock.unlock(); return }
        inFlight = true
        nextAllowed = now.addingTimeInterval(Self.interval)
        // Only when there is nothing to show: a five-minute refresh must not
        // blink a good reading back to "asking" and in again.
        if snapshot == nil { set(.asking) }
        lock.unlock()

        fetch(deliberate: deliberate) { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            var fresh = false
            switch result {
            case .success(let snap):
                self.backoffStep = 0
                fresh = self.snapshot?.windows != snap.windows
                self.snapshot = snap
                self.set(.ok(at: snap.at, account: snap.account))
            case .rateLimited:
                let wait = Self.backoffSteps[min(self.backoffStep, Self.backoffSteps.count - 1)]
                self.backoffStep += 1
                let until = Date().addingTimeInterval(wait)
                self.nextAllowed = until
                self.set(.rateLimited(until: until))
            case .failed(let why):
                // Ordinary failure (offline, 401, a shape we don't recognise):
                // wait out the normal interval and try again. Whatever is on
                // screen ages out by itself through `maxAge`; the reason stays.
                self.set(why)
            }
            self.lock.unlock()
            if fresh { changed() }
        }
    }

    private enum Outcome {
        case success(Snapshot)
        case rateLimited
        case failed(Status)
    }

    /// Ask now, whatever the schedule said. This is the button in Settings, and
    /// it exists for one reason beyond impatience: the Keychain prompt appears
    /// when the call is made, and a person who has just switched this on should
    /// be able to summon it rather than wait up to five minutes for it to arrive
    /// behind whatever they are looking at.
    /// `deliberate: false` is the same impatience without the door: it forgets
    /// the schedule but leaves Claude Code's Keychain record alone, which is what
    /// flipping the switch on wants — turn the reading on, raise nothing.
    func checkNow(deliberate: Bool = true, changed: @escaping () -> Void) {
        lock.lock()
        nextAllowed = .distantPast
        backoffStep = 0
        lock.unlock()
        refreshIfDue(deliberate: deliberate, changed: changed)
    }

    // MARK: - The call

    private func fetch(deliberate: Bool, _ done: @escaping (Outcome) -> Void) {
        let token: String
        let account: String?
        // A press asks whatever the standing answer was; the clock reads only
        // where a press was already allowed once.
        switch Self.token(orIn: Self.credential(askingKeychain:
                                                deliberate || Self.keychainAllowed)) {
        case .success(let found): (token, account) = (found.token, found.account)
        case .failure(let why): done(.failed(why)); return
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent(), forHTTPHeaderField: "User-Agent")

        // Ephemeral: no cookie jar, no disk cache, nothing about this call
        // outlives it.
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let http = response as? HTTPURLResponse else {
                done(.failed(error == nil ? .unexpected(0) : .unreachable)); return
            }
            switch http.statusCode {
            case 429: done(.rateLimited)
            case 401, 403:
                done(.failed(.declined(code: http.statusCode, message: Self.message(in: data))))
            case 200:
                guard let data, let snap = Self.parse(data, account: account) else {
                    // A 200 whose body we cannot read is not a network problem
                    // and not a login problem: it is the shape changing under
                    // us, which this endpoint is allowed to do.
                    done(.failed(.unexpected(200))); return
                }
                done(.success(snap))
            case let code: done(.failed(.unexpected(code)))
            }
        }.resume()
    }

    /// `claude-code/<version>` is what the endpoint routes on; callers without it
    /// land in a bucket that 429s almost immediately. We keep that prefix and add
    /// our own name after it rather than pretending to be the CLI outright — if a
    /// stricter match ever rejects the suffix, the feature goes quiet and backs
    /// off, which is the failure mode everything else here has too.
    static func userAgent(appVersion: String? = nil) -> String {
        let app = appVersion
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            ?? "0"
        return "claude-code/\(installedCLIVersion() ?? "2.1.0") AgentBar/\(app)"
    }

    /// The Claude Code build actually installed here, so the header isn't
    /// claiming a version that doesn't exist. Two cheap places carry it; a
    /// constant is the last resort.
    static func installedCLIVersion(home: URL? = nil) -> String? {
        let fm = FileManager.default
        let base = home ?? fm.homeDirectoryForCurrentUser
        let versions = base.appendingPathComponent(".local/share/claude/versions")
        if let names = try? fm.contentsOfDirectory(atPath: versions.path) {
            let real = names.filter { $0.first?.isNumber == true }
                .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            if let newest = real.last { return newest }
        }
        for root in WeightReader.claudeConfigDirs(home: base) {
            let marker = root.appendingPathComponent(".last-update-result.json")
            guard let data = try? Data(contentsOf: marker),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if let v = o["version_to"] as? String { return v }
            if let v = o["version_from"] as? String { return v }
        }
        return nil
    }

    // MARK: - Parsing (pure)

    /// What the server said went wrong, short enough to sit in a caption. Only
    /// the message — never a field we did not ask for, and never the request.
    static func message(in data: Data?) -> String? {
        guard let data, data.count < 8_192,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let text = (o["error"] as? [String: Any])?["message"] as? String
            ?? o["message"] as? String
            ?? o["error"] as? String
        guard let text, !text.isEmpty else { return nil }
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    /// The endpoint answers with one object per window. `utilization` is a
    /// **percentage**, not a fraction — readers that assume otherwise render 1 %
    /// as 100 % or 55 % as half a percent, and both mistakes have been filed
    /// against other clients of this endpoint. Take it as given, clamp it, and
    /// never scale it.
    static func parse(_ data: Data, account: String? = nil, at: Date = Date()) -> Snapshot? {
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        var windows: [UsageWindow] = []
        if let w = window(o["five_hour"], name: "5h") { windows.append(w) }
        if let w = window(o["seven_day"], name: "weekly") { windows.append(w) }
        guard !windows.isEmpty else { return nil }
        return Snapshot(windows: windows, account: account, at: at)
    }

    private static func window(_ any: Any?, name: String) -> UsageWindow? {
        // A window that isn't running comes back as null, and that is an answer:
        // no window, no meter. It must not become a confident zero.
        guard let o = any as? [String: Any],
              let raw = (o["utilization"] as? NSNumber)?.doubleValue,
              raw.isFinite
        else { return nil }
        return UsageWindow(name: name,
                           usedPercent: min(max(raw, 0), 100),
                           resetsAt: (o["resets_at"] as? String).flatMap(parseISO))
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseISO(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    // MARK: - The credential

    /// Claude Code keeps its OAuth credential in the login Keychain under one
    /// service name; some installs keep a file instead. Either way the shape is
    /// the same JSON, and either way macOS is the one that decides whether this
    /// app may read it — the first attempt raises the system's own "allow
    /// AgentBar to use this keychain item" dialog, and a refusal is final until
    /// the person changes their mind.
    static let service = "Claude Code-credentials"
    /// AgentBar's own Keychain item, holding only a token the person pasted in.
    /// A separate service name from Claude Code's on purpose: this app writes
    /// here and reads here, and never writes to the CLI's record.
    static let ownService = "AgentBar-claude-quota"
    private static let ownAccount = "pasted-token"

    /// The token someone handed over deliberately, if there is one. Reading an
    /// item this app created raises no prompt: macOS already trusts the writer.
    static func storedToken() -> String? {
        var query = ownQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty
        else { return nil }
        return token
    }

    /// Store one, replace one, or — with nil or an empty string — remove it. The
    /// delete runs either way, so "replace" cannot leave two.
    @discardableResult
    static func setStoredToken(_ token: String?) -> Bool {
        SecItemDelete(ownQuery() as CFDictionary)
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return true }
        var add = ownQuery()
        add[kSecValueData as String] = Data(trimmed.utf8)
        // Readable while the Mac is unlocked-since-boot, so a refresh on wake
        // works without asking for anything.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func ownQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: ownService,
         kSecAttrAccount as String: ownAccount]
    }

    /// What to send, and whose it is. A token handed over on purpose wins: it was
    /// a deliberate act, and it is the only thing that works on a machine whose
    /// CLI keeps its login out of reach.
    static func token(storedBy stored: @autoclosure () -> String? = storedToken(),
                      orIn lookup: @autoclosure () -> Lookup
                          = credential(askingKeychain: keychainAllowed))
        -> Result<(token: String, account: String?), Status> {
        if let mine = stored() { return .success((mine, "your own token")) }
        switch lookup() {
        case .missing: return .failure(.noCredential)
        case .notAsked: return .failure(.notAsked)
        case .refused(let code): return .failure(.refused(code))
        case .found(let json, let account):
            guard let token = accessToken(in: json) else {
                return .failure(loggedOut(json) ? .loggedOut : .noCredential)
            }
            if let when = expiry(in: json), when <= Date() {
                return .failure(.expiredToken(at: when))
            }
            return .success((token, account))
        }
    }

    /// Not an optional: "there is no login here" and "macOS would not give me
    /// the one that is here" are different facts, and the second one is the only
    /// one a person can do something about.
    enum Lookup {
        case found(json: [String: Any], account: String?)
        case missing
        case refused(OSStatus)
        /// Not asked. Distinct from `missing` in the only way that matters to
        /// the person reading the sentence: there may be a login sitting there,
        /// and the reason nobody knows is that asking costs a password prompt.
        case notAsked
    }

    /// `askingKeychain: false` leaves the one door that costs a password prompt
    /// shut and still reads the file form, which costs nothing and prompts for
    /// nothing.
    static func credential(askingKeychain ask: Bool = true) -> Lookup {
        let keychain = ask ? keychainCredential() : Lookup.notAsked
        if case .found = keychain { return keychain }
        let fm = FileManager.default
        // Claude Code relocates its credential file with two environment
        // variables, and an install that sets either keeps nothing in the usual
        // place. Only visible when the app was started from a shell that had
        // them — a GUI launch inherits neither — but a file that is there costs
        // one `contentsOf` to check, and a file that is not costs nothing.
        var roots: [URL] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CONFIG_DIR"] {
            guard let raw = env[key], !raw.isEmpty else { continue }
            roots.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        }
        roots += WeightReader.claudeConfigDirs(home: fm.homeDirectoryForCurrentUser)
        for root in roots {
            let file = root.appendingPathComponent(".credentials.json")
            guard let data = try? Data(contentsOf: file),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return .found(json: o, account: root.lastPathComponent)
        }
        // A refusal — or an unasked question — outranks "missing": the file
        // fallback found nothing, but the Keychain may hold a login and is
        // either waiting on an answer or waiting to be asked.
        return keychain
    }

    private static func keychainCredential(account: String? = nil) -> Lookup {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        var item: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &item)
        // The one place the answer is observed is the one place it is recorded.
        keychainAllowed = allowed(after: code, was: keychainAllowed)
        guard code == errSecSuccess else { return lookup(forKeychain: code) }
        guard let found = item as? [String: Any],
              let data = found[kSecValueData as String] as? Data,
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .missing }
        return .found(json: o, account: found[kSecAttrAccount as String] as? String)
    }

    /// What one Keychain answer means for the standing permission. A success is
    /// a grant, and the clock may read quietly from then on. A refusal ends it:
    /// nothing asks again until a person does, which is the whole point — the
    /// dialog comes back after every reinstall, and somebody shipping ten builds
    /// a day should meet it at most when they go looking for it. "Not there"
    /// changes nothing, because there was nothing to refuse.
    static func allowed(after code: OSStatus, was standing: Bool) -> Bool {
        if code == errSecSuccess { return true }
        if code == errSecItemNotFound { return standing }
        return false
    }

    /// Every non-success is a refusal except the one that means the item is not
    /// there. Spelled out rather than folded into "no login": a person who has
    /// Claude Code installed and is told there is no login would go looking in
    /// the wrong place.
    static func lookup(forKeychain code: OSStatus) -> Lookup {
        code == errSecItemNotFound ? .missing : .refused(code)
    }

    /// Claude's own token, out of Claude's own field, and nothing else.
    ///
    /// This used to search for `accessToken` by name at any depth, on the theory
    /// that the credential's shape has changed before and a search survives the
    /// next change. It does not survive what is actually in that record: the same
    /// Keychain entry holds an `accessToken` for **every MCP server the user has
    /// authorised** — Figma, Supabase, whatever else — and a Swift dictionary has
    /// no order, so what came back was whichever one the hash happened to yield.
    /// AgentBar then sent it to `api.anthropic.com` as a bearer token.
    ///
    /// A credential belonging to a third party must never leave this machine in a
    /// request addressed to somebody else. The only way to promise that is to
    /// name the field, so it is named: `claudeAiOauth.accessToken`, with the two
    /// top-level spellings the file form has used. An unknown future shape means
    /// no reading — which is the failure this whole file is built to fail with.
    static func accessToken(in json: [String: Any]) -> String? {
        let claude = json["claudeAiOauth"] as? [String: Any]
        for candidate in [claude?["accessToken"], json["accessToken"], json["access_token"]] {
            if let s = candidate as? String, !s.isEmpty { return s }
        }
        return nil
    }

    /// True when the record has Claude's own section but nothing in it — signed
    /// out, rather than a shape we don't know. Worth telling apart: they send a
    /// person to two different places.
    static func loggedOut(_ json: [String: Any]) -> Bool {
        json["claudeAiOauth"] != nil && accessToken(in: json) == nil
    }

    /// One line per stored login: who it belongs to, when it was last written,
    /// and when it says it lapses. Never the token — there is nothing here that
    /// could print one. For `--quota-status`, because "invalid bearer token" is
    /// a different problem depending on whether this Mac holds one login or
    /// four.
    static func candidates() -> [String] {
        // Attributes only: asking for every item *and* its data comes back as a
        // parameter error on macOS, which is how this first printed nothing at
        // all. The data is fetched per login, below.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var item: CFTypeRef?
        let code = SecItemCopyMatching(query as CFDictionary, &item)
        guard code == errSecSuccess, let items = item as? [[String: Any]]
        else { return ["no stored login readable (\(code))"] }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "d MMM HH:mm"
        return items.map { found in
            let who = found[kSecAttrAccount as String] as? String ?? "?"
            let written = (found[kSecAttrModificationDate as String] as? Date)
                .map(f.string(from:)) ?? "?"
            var lapses = "no expiry"
            var kind = "no Claude token in it"
            if case .found(let o, _) = keychainCredential(account: who) {
                lapses = expiry(in: o).map(f.string(from:)) ?? "no expiry"
                kind = accessToken(in: o).map(self.kind) ?? "no Claude token in it"
            }
            return "login \(who): \(kind), written \(written), expires \(lapses)"
        }
    }

    /// What *kind* of credential is stored, from the scheme prefix alone — the
    /// part that is printed on Anthropic's own documentation pages. An OAuth
    /// token and an API key are both "a long string" and neither works in the
    /// other's place: one goes in `Authorization: Bearer`, the other in
    /// `x-api-key`, and "invalid bearer token" is what you get for confusing
    /// them. Nothing past the scheme is ever read out.
    static func kind(of token: String) -> String {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "sk" else { return "token of an unknown shape" }
        return parts.prefix(3).joined(separator: "-") + "-… token"
    }

    // MARK: - Saying it

    /// The full sentence, for the caption under the switch. It names what
    /// happened and, where there is one, what to do about it — a status line
    /// that says "error" has only moved the question.
    static func sentence(for status: Status, now: Date = Date()) -> String {
        switch status {
        case .off:
            return "Off. Claude's row counts tokens read from this Mac instead."
        case .asking:
            return "Asking Anthropic… a Keychain prompt, if one appears, is this."
        case .ok(let at, let account):
            let who = account.map { " · \($0)" } ?? ""
            return "Read at \(UsageCenter.when(at, now: now))\(who)."
        case .noCredential:
            return "No Claude Code login on this Mac. Sign in with the CLI, or use a token."
        case .notAsked:
            return "Claude Code's login is in the Keychain, and reading another app's item "
                + "raises a macOS password prompt — so AgentBar asks only when you press "
                + "“Check now”, never on its own."
        case .loggedOut:
            return "The stored Claude Code login is empty — as it is on any Mac whose "
                + "sessions run under their own CLAUDE_CONFIG_DIR. Use a token instead."
        case .refused(let code):
            return "macOS would not hand over the Keychain login (\(code)). Answer its "
                + "prompt with Always Allow; “Check now” raises it again."
        case .expiredToken(let when):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "d MMM HH:mm"
            return "The stored login expired at \(f.string(from: when)); Claude Code renews "
                + "it the next time it runs."
        case .declined(let code, let message):
            let said = message.map { " It said: \($0)" } ?? ""
            return "Anthropic declined the token (\(code)). Sign in with Claude Code again, "
                + "or replace the token you pasted.\(said)"
        case .rateLimited(let until):
            return "Rate-limited. Trying again at \(UsageCenter.when(until, now: now))."
        case .unreachable:
            return "Couldn't reach api.anthropic.com."
        case .unexpected(let code):
            return "api.anthropic.com answered \(code); nothing to show until that changes."
        }
    }

    /// The same fact in the width a menu row has: one clause, no advice. Nil
    /// where there is nothing to explain — the switch is off, or the number is
    /// on screen.
    static func shortReason(for status: Status) -> String? {
        switch status {
        case .off, .ok:        return nil
        case .asking:          return "asking Anthropic…"
        case .noCredential:    return "no Claude Code login found"
        case .notAsked:        return "press Check now in Settings"
        case .loggedOut:       return "the stored login is empty"
        case .refused:         return "waiting on Keychain permission"
        case .expiredToken:    return "login expired, the CLI renews it"
        case .declined:        return "login declined — sign in again"
        case .rateLimited:     return "rate-limited, trying again later"
        case .unreachable:     return "can't reach api.anthropic.com"
        case .unexpected(let code): return "api.anthropic.com answered \(code)"
        }
    }

    /// Expiry is milliseconds since the epoch where it appears at all. An expired
    /// token is not an error worth surfacing: the CLI renews it the next time it
    /// runs, and asking with it would only spend a 401.
    static func expired(_ json: [String: Any], now: Date = Date()) -> Bool {
        guard let when = expiry(in: json) else { return false }
        return when <= now
    }

    /// When the stored login lapses, or nil where it says nothing.
    ///
    /// The field is milliseconds in every shape seen so far, but a seconds value
    /// read as milliseconds lands in 1970 and makes every fresh login look
    /// expired — a silent, total failure of this feature. So the unit is decided
    /// by magnitude rather than assumed: anything that would fall before 2001
    /// read as milliseconds is seconds.
    static func expiry(in json: [String: Any]) -> Date? {
        guard let n = expiryMillis(in: json), n.isFinite, n > 0 else { return nil }
        let asMillis = Date(timeIntervalSince1970: n / 1000)
        return asMillis.timeIntervalSince1970 > 978_307_200   // 2001-01-01
            ? asMillis : Date(timeIntervalSince1970: n)
    }

    /// Named, not searched, for the same reason the token is: an `expiresAt`
    /// picked out of an MCP server's section describes that server's token, and
    /// answers a question nobody asked. A zero is "no expiry", not 1970.
    private static func expiryMillis(in json: [String: Any]) -> Double? {
        let claude = json["claudeAiOauth"] as? [String: Any]
        for candidate in [claude?["expiresAt"], json["expiresAt"], json["expires_at"]] {
            if let n = (candidate as? NSNumber)?.doubleValue, n.isFinite, n > 0 { return n }
        }
        return nil
    }
}

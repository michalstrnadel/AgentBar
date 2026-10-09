import Foundation
import Security

/// Approvals on the phone, through ntfy.
///
/// The one feature in AgentBar that sends anything about your work off the Mac, so
/// it is written around what that costs rather than around what it can do:
///
/// - **Off by default, and off means silent.** No request is made, no timer runs,
///   nothing is polled, until the person switches it on on its own Settings page.
/// - **Only what wants an answer, and by default only when you are away** — the
///   same test `Notifier` applies to a banner, because a phone buzzing for a prompt
///   the island is already showing you is noise, not reach.
/// - **You cannot approve what you cannot read.** Allow goes along only with a
///   shell command that went along whole: not truncated, no control characters, no
///   invisible character the hook's JSON dropped. An edit, a write, a plan, a
///   command too long for a phone — and everything in *Private* mode, where the
///   push says which agent waits in which project and nothing else — gets Deny only.
/// - **The topic is the key.** ntfy topics are open to whoever knows their name, so
///   the name is 130 random bits, never something a person picked, and the page
///   says in as many words that anyone holding it can read and answer. A server
///   of your own with an access token is the stronger setup and is supported.
/// - **A reply answers exactly one request, once.** Every push carries a fresh
///   one-time token; a reply is honoured only while that same request — same file,
///   same identity — is still pending, and only with a verb that push offered.
///   A replayed, late or forged reply answers nothing.
///
/// A tap lands in the seam every other surface uses, `AgentActions.answer`, and is
/// written to the ledger as the person's own decision, `via: "phone"`.
///
/// Replies come back on a second topic the phone never subscribes to (so its own
/// taps do not arrive as notifications), polled every few seconds **only while a
/// pushed request is still waiting**. The moment none is, polling stops.
final class PhoneRelay {
    static let shared = PhoneRelay()

    // MARK: - Preferences

    enum When: String, CaseIterable {
        /// Screen locked, or no keyboard or mouse for two minutes.
        case away
        case always
    }

    enum Detail: String, CaseIterable {
        /// The command goes along, and so Allow can be offered.
        case full
        /// Agent and project only. Deny only.
        case privately = "private"
    }

    enum Prefs {
        static var enabled: Bool {
            get { UserDefaults.standard.bool(forKey: "phoneEnabled") }
            set { UserDefaults.standard.set(newValue, forKey: "phoneEnabled") }
        }
        static var server: String {
            get { UserDefaults.standard.string(forKey: "phoneServer") ?? PhoneRelay.defaultServer }
            set { UserDefaults.standard.set(newValue, forKey: "phoneServer") }
        }
        /// Minted on first read and kept: a topic that changed under a phone
        /// already subscribed to it would stop delivering without saying so.
        static var topic: String {
            if let t = UserDefaults.standard.string(forKey: "phoneTopic"), PhoneRelay.validTopic(t) {
                return t
            }
            let t = PhoneRelay.newTopic()
            UserDefaults.standard.set(t, forKey: "phoneTopic")
            return t
        }
        static func regenerateTopic() {
            UserDefaults.standard.set(PhoneRelay.newTopic(), forKey: "phoneTopic")
        }
        static var when: When {
            get { When(rawValue: UserDefaults.standard.string(forKey: "phoneWhen") ?? "") ?? .away }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "phoneWhen") }
        }
        static var detail: Detail {
            get { Detail(rawValue: UserDefaults.standard.string(forKey: "phoneDetail") ?? "") ?? .full }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: "phoneDetail") }
        }
    }

    static let defaultServer = "https://ntfy.sh"
    /// How long the person has to have left the machine alone before a request is
    /// theirs to answer from the phone. Two minutes, the same as `Notifier`'s
    /// quiet summary — one idea of "away" in the app, not two.
    static let awayAfter: TimeInterval = Notifier.quietSettle
    /// The longest command a push carries whole. ntfy takes 4 096 bytes; this
    /// leaves room for the title and the agent's name, and a command longer than
    /// this is not one anybody reads properly on a phone anyway.
    static let commandLimit = 1_200

    // MARK: - Pure pieces (tested)

    /// `agentbar-` and 26 characters of base-32: 130 bits, lower case so it reads
    /// the same typed into the ntfy app by hand.
    static func newTopic() -> String {
        var bytes = [UInt8](repeating: 0, count: 17)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "agentbar-" + String(base32(bytes).prefix(26))
    }

    static func validTopic(_ t: String) -> Bool {
        t.count >= 20 && t.count <= 64
            && t.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) }
    }

    static func newNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func base32(_ bytes: [UInt8]) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var out = "", buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    /// The server as a URL AgentBar will talk to: https anywhere, plain http only to
    /// this machine or a private network — a self-hosted ntfy on the LAN or a
    /// tailnet is a legitimate setup, a cleartext hop across the internet is not.
    static func serverURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty,
              url.query == nil, url.fragment == nil, url.user == nil
        else { return nil }
        switch url.scheme?.lowercased() {
        case "https": return url
        case "http":  return isPrivateHost(host) ? url : nil
        default:      return nil
        }
    }

    static func isPrivateHost(_ host: String) -> Bool {
        let h = host.lowercased()
        if h == "localhost" || h.hasSuffix(".local") || h.hasSuffix(".ts.net") || h == "::1" { return true }
        let parts = h.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ $0 != nil && (0...255).contains($0!) }) else { return false }
        switch (parts[0]!, parts[1]!) {
        case (10, _), (127, _), (192, 168): return true
        case (172, let b) where (16...31).contains(b): return true
        case (100, let b) where (64...127).contains(b): return true   // CGNAT: Tailscale
        default: return false
        }
    }

    /// Whether a request that just arrived should go to the phone now.
    static func shouldPush(when: When, idle: TimeInterval, locked: Bool) -> Bool {
        switch when {
        case .always: return true
        case .away:   return locked || idle >= awayAfter
        }
    }

    /// A command a person can read whole on a phone: short enough to go along
    /// untruncated, and nothing in it that a lock screen draws as something else —
    /// no control characters but line breaks and tabs, no invisible format
    /// characters (a zero-width space makes `rm` and `r​m` look alike).
    static func readable(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= commandLimit else { return false }
        return command.unicodeScalars.allSatisfy { s in
            if s == "\n" || s == "\t" { return true }
            if CharacterSet.controlCharacters.contains(s) { return false }
            return s.properties.generalCategory != .format
        }
    }

    /// The verbs a push for this request offers. A plan's Allow is a keystroke in
    /// the session's own dialog, which a phone cannot make; a question's answer is
    /// a list of labels, which a notification button cannot carry; and Allow goes
    /// only with a command that went along whole (`readable`).
    static func verbs(for request: ApprovalRequest, detail: Detail) -> [String] {
        if request.questions != nil { return [] }
        if request.isPlanRequest { return ["deny"] }
        guard detail == .full, !request.droppedInvisible,
              case .bash(let command)? = request.context, readable(command)
        else { return ["deny"] }
        return ["allow", "deny"]
    }

    /// What the push says. Private: who waits where, nothing more. Full: the
    /// command whole when it is readable, otherwise the one-line summary and a
    /// note that the rest is on the Mac — which is also why it then has no Allow.
    static func body(for request: ApprovalRequest, project: String, agentName: String,
                     detail: Detail) -> String {
        let place = project.isEmpty ? "" : " in \(project)"
        guard detail == .full else {
            return "\(agentName) is waiting for you\(place). Open the Mac to see what it wants."
        }
        if case .bash(let command)? = request.context, readable(command), !request.droppedInvisible {
            return "\(agentName)\(place):\n\(command)"
        }
        if request.isPlanRequest {
            return "\(agentName)\(place) has a plan ready. Read it on the Mac to approve it."
        }
        var line = request.display.replacingOccurrences(of: "\n", with: " ")
        if line.count > 300 { line = String(line.prefix(299)) + "…" }
        return "\(agentName)\(place): \(line)\nAllow it on the Mac, where you can read all of it."
    }

    /// The JSON ntfy's publish endpoint takes. Each button is an `http` action that
    /// posts `<verb> <nonce>` to the reply topic and clears the notification.
    static func publishBody(topic: String, server: URL, title: String, message: String,
                            verbs: [String], nonce: String, plan: Bool,
                            token: String?) -> [String: Any] {
        let reply = server.appendingPathComponent(topic + "-answers").absoluteString
        var headers: [String: String] = [:]
        if let token, !token.isEmpty { headers["Authorization"] = "Bearer \(token)" }
        let actions: [[String: Any]] = verbs.map { verb in
            var a: [String: Any] = [
                "action": "http",
                "label": verb == "allow" ? "Allow" : (plan ? "Keep planning" : "Deny"),
                "url": reply, "method": "POST", "body": "\(verb) \(nonce)", "clear": true,
            ]
            if !headers.isEmpty { a["headers"] = headers }
            return a
        }
        return ["topic": topic, "title": title, "message": message,
                "priority": 4, "tags": ["robot"], "actions": actions]
    }

    struct Reply: Equatable {
        let id: String
        let verb: String
        let nonce: String
    }

    /// ntfy's poll answer: one JSON object per line. Everything that is not a
    /// `message` event of exactly `<verb> <32 hex>` is not a reply and is dropped.
    static func parseReplies(_ data: Data) -> [Reply] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            guard let o = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  o["event"] as? String == "message",
                  let id = o["id"] as? String,
                  let text = o["message"] as? String
            else { return nil }
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
            guard parts.count == 2,
                  ["allow", "deny", "ping"].contains(String(parts[0])),
                  parts[1].count == 32,
                  parts[1].allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else { return nil }
            return Reply(id: id, verb: String(parts[0]), nonce: String(parts[1]))
        }
    }

    /// One push still waiting for a tap.
    struct Pending: Equatable {
        let fileName: String
        let identity: String
        let verbs: Set<String>
    }

    /// The whole trust decision for a tap on the phone, as a function: which
    /// request, if any, this reply may answer. The nonce must be one this Mac
    /// issued and has not spent, the verb one that push offered, and the request
    /// in that file still the one the push was about — a file name reused by the
    /// next tool of the turn holds a request the person never read.
    static func target(of reply: Reply, pending: Pending?,
                       requests: [ApprovalRequest]) -> ApprovalRequest? {
        guard let p = pending, p.verbs.contains(reply.verb) else { return nil }
        return requests.first { $0.fileName == p.fileName && $0.identity == p.identity }
    }

    /// What the ntfy app opens to subscribe, for the QR code on the page.
    static func subscribeLink(server: String, topic: String) -> String {
        guard let url = serverURL(server), let host = url.host else { return "" }
        let port = url.port.map { ":\($0)" } ?? ""
        let secure = url.scheme == "https" ? "" : "?secure=false"
        return "ntfy://\(host)\(port)\(url.path)/\(topic)\(secure)"
    }

    // MARK: - State

    /// By nonce. Main queue only.
    private var pending: [String: Pending] = [:]
    /// Identities already pushed, so a request is sent once however many ticks see it.
    private var pushed: Set<String> = []
    /// ntfy's `since`: the last reply id seen, or the time polling began.
    private var since: String?
    private var pollTimer: Timer?
    /// Re-asks "is the person away yet?" while requests wait unpushed.
    private var awayTimer: Timer?
    private var polling = false
    private var testNonce: (nonce: String, sentAt: Date, done: (Result<TimeInterval, Error>) -> Void)?

    /// Fed by the app delegate — the same stores every surface reads.
    var requests: () -> [ApprovalRequest] = { [] }
    var sessions: () -> [Session] = { [] }

    /// Called whenever the pending set changes, when a preference changes, and by
    /// the away timer.
    func requestsChanged() {
        let live = requests()
        let liveIDs = Set(live.map(\.identity))
        // Forget what has been answered anywhere: its buttons must not answer the
        // next request that happens to reuse the file name.
        pending = pending.filter { liveIDs.contains($0.value.identity) }
        pushed.formIntersection(liveIDs)

        guard Prefs.enabled, let server = Self.serverURL(Prefs.server) else {
            stopTimers()
            return
        }
        let unpushed = live.filter {
            !pushed.contains($0.identity) && !Self.verbs(for: $0, detail: Prefs.detail).isEmpty
        }
        if !unpushed.isEmpty {
            if Self.shouldPush(when: Prefs.when, idle: InputIdle.seconds(), locked: ScreenLock.shared.isLocked) {
                for r in unpushed { push(r, server: server) }
                awayTimer?.invalidate(); awayTimer = nil
            } else if awayTimer == nil {
                // Not away yet. Ask again in a while — someone who walks off with a
                // prompt on screen is exactly who this feature is for.
                awayTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
                    self?.requestsChanged()
                }
            }
        } else {
            awayTimer?.invalidate(); awayTimer = nil
        }
        syncPolling()
    }

    private func push(_ r: ApprovalRequest, server: URL) {
        let detail = Prefs.detail
        let verbs = Self.verbs(for: r, detail: detail)
        let nonce = Self.newNonce()
        let session = sessions().first { $0.id == r.sessionId }
        let agent = r.agent.name
        let body = Self.publishBody(
            topic: Prefs.topic, server: server,
            title: r.isPlanRequest ? "\(agent) has a plan" : "\(agent) needs approval",
            message: Self.body(for: r, project: session?.project ?? "", agentName: agent, detail: detail),
            verbs: verbs, nonce: nonce, plan: r.isPlanRequest, token: Self.token)
        pushed.insert(r.identity)
        pending[nonce] = Pending(fileName: r.fileName, identity: r.identity, verbs: Set(verbs))
        if since == nil { since = String(Int(Date().timeIntervalSince1970) - 5) }
        publish(body, server: server) { ok in
            if !ok { NSLog("AgentBar: phone push for \(r.fileName) did not go out") }
        }
    }

    private func publish(_ body: [String: Any], server: URL, done: @escaping (Bool) -> Void) {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { done(false); return }
        var req = URLRequest(url: server, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = Self.token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        URLSession.shared.dataTask(with: req) { _, response, error in
            let ok = error == nil && ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
            DispatchQueue.main.async { done(ok) }
        }.resume()
    }

    private func syncPolling() {
        let wanted = !pending.isEmpty || testNonce != nil
        if wanted, pollTimer == nil {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                self?.poll()
            }
        } else if !wanted {
            pollTimer?.invalidate(); pollTimer = nil
            since = nil
        }
    }

    private func stopTimers() {
        awayTimer?.invalidate(); awayTimer = nil
        pending.removeAll()
        syncPolling()
    }

    private func poll() {
        guard !polling, let server = Self.serverURL(Prefs.server) else { return }
        var comps = URLComponents(url: server.appendingPathComponent(Prefs.topic + "-answers/json"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "poll", value: "1"),
                             URLQueryItem(name: "since", value: since ?? "30s")]
        guard let url = comps?.url else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        if let token = Self.token, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        polling = true
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            let ok = ((response as? HTTPURLResponse)?.statusCode ?? 0) / 100 == 2
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                guard ok, let data else { return }
                for reply in Self.parseReplies(data) {
                    self.since = reply.id
                    self.handle(reply)
                }
            }
        }.resume()
    }

    private func handle(_ reply: Reply) {
        if reply.verb == "ping", let test = testNonce, test.nonce == reply.nonce {
            testNonce = nil
            test.done(.success(Date().timeIntervalSince(test.sentAt)))
            syncPolling()
            return
        }
        // One use: the nonce is gone whatever happens next.
        let spent = pending.removeValue(forKey: reply.nonce)
        defer { syncPolling() }
        guard let request = Self.target(of: reply, pending: spent, requests: requests()),
              let session = sessions().first(where: { $0.id == request.sessionId })
        else { return }
        AgentActions.answer(ApprovalAction(request: request, behavior: reply.verb,
                                           session: session, via: "phone"))
    }

    // MARK: - Test

    enum TestError: LocalizedError {
        case badServer, notSent, timedOut
        var errorDescription: String? {
            switch self {
            case .badServer: return "That server address will not do — https, or http on your own network."
            case .notSent:   return "The server did not take the message."
            case .timedOut:  return "Nothing came back within two minutes."
            }
        }
    }

    /// Sends one notification with a single "Tap to confirm" button, and reports how
    /// long the round trip took — which proves the whole path, subscription and
    /// reply topic included, without waiting for an agent to need something.
    func sendTest(done: @escaping (Result<TimeInterval, Error>) -> Void) {
        guard let server = Self.serverURL(Prefs.server) else { done(.failure(TestError.badServer)); return }
        let nonce = Self.newNonce()
        var body = Self.publishBody(topic: Prefs.topic, server: server, title: "AgentBar",
                                    message: "This is where an approval will arrive. Tap to confirm the way back works.",
                                    verbs: [], nonce: nonce, plan: false, token: Self.token)
        var action: [String: Any] = ["action": "http", "label": "Tap to confirm",
                                     "url": server.appendingPathComponent(Prefs.topic + "-answers").absoluteString,
                                     "method": "POST", "body": "ping \(nonce)", "clear": true]
        if let token = Self.token, !token.isEmpty { action["headers"] = ["Authorization": "Bearer \(token)"] }
        body["actions"] = [action]
        testNonce = (nonce, Date(), done)
        if since == nil { since = String(Int(Date().timeIntervalSince1970) - 5) }
        publish(body, server: server) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.testNonce = nil
                self.syncPolling()
                done(.failure(TestError.notSent))
                return
            }
            self.syncPolling()
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, let t = self.testNonce, t.nonce == nonce else { return }
                self.testNonce = nil
                self.syncPolling()
                done(.failure(TestError.timedOut))
            }
        }
    }

    // MARK: - The access token, in the Keychain

    private static let keychainService = "com.michalstrnadel.agentbar.phone"

    /// Read once and kept: the poll asks for it every three seconds, and the
    /// Keychain is not something to go to that often.
    private static var cachedToken: String??

    static var token: String? {
        if let cached = cachedToken { return cached }
        let value = readToken()
        cachedToken = .some(value)
        return value
    }

    private static func readToken() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: keychainService,
                                    kSecAttrAccount as String: "ntfy",
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func setToken(_ value: String?) -> Bool {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: keychainService,
                                   kSecAttrAccount as String: "ntfy"]
        SecItemDelete(base as CFDictionary)
        cachedToken = nil
        guard let value, !value.isEmpty else { return true }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }
}

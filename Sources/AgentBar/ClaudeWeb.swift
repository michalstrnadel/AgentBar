import Cocoa
import WebKit

/// Claude's quota read the way claude.ai itself reads it — from a session you
/// sign into once, inside AgentBar.
///
/// Why this exists beside `ClaudeQuota`: that one borrows Claude Code's own
/// login out of the Keychain, which is the right thing when the CLI keeps a
/// login there. On a Mac whose sessions run under their own `CLAUDE_CONFIG_DIR`
/// that record is empty, and no amount of asking politely reaches the real one.
/// The alternative everyone else reaches for is to open the *browser's* cookie
/// jar — Chrome's, decrypted with a key out of its Keychain item, or Safari's,
/// behind Full Disk Access. Both work. Both mean this app reading another app's
/// credential store, and both still cost the person a permission dialog, so
/// they buy nothing that a sign-in does not.
///
/// So: a sign-in. One window, claude.ai's own login page, the session cookie
/// left in **AgentBar's own** cookie store where WebKit keeps it and renews it.
/// Nothing is read out of another application, nothing is copied to disk by us,
/// and the whole thing is undone by Sign out, which empties that store.
///
/// The numbers come from the same two calls the site makes:
/// `GET /api/organizations` for the account, then
/// `GET /api/organizations/<uuid>/usage`, whose body has the same shape the
/// OAuth endpoint uses — so `ClaudeQuota.parse` reads it and there is one
/// parser, not two.
enum ClaudeWeb {
    static let host = "claude.ai"
    static let cookieName = "sessionKey"

    /// Set once a sign-in has produced a session cookie. Not a secret and not
    /// the cookie: just whether it is worth asking.
    static var connected: Bool {
        get { UserDefaults.standard.bool(forKey: "claudeWebConnected") }
        set { UserDefaults.standard.set(newValue, forKey: "claudeWebConnected") }
    }

    /// The store the sign-in window writes to and the fetcher reads from. The
    /// default (persistent) store, so a session survives a restart the way it
    /// does in a browser — and so "sign out" has exactly one place to empty.
    ///
    /// **Main thread only.** Touching it is what initialises WebKit, and WebKit
    /// traps if that happens anywhere else. Every caller here goes through
    /// `onMain`; nothing may reach this property without it.
    static var store: WKHTTPCookieStore { WKWebsiteDataStore.default().httpCookieStore }

    /// Run `work` on the main thread — now, if that is where we already are.
    ///
    /// The usage refresh runs on its own serial queue, and from there the first
    /// touch of `WKWebsiteDataStore` took the whole app down inside
    /// `WebKit::InitializeWebKit2()`. It only began happening once somebody was
    /// signed in: before that, the refresh stopped at `connected` and never
    /// reached WebKit at all.
    ///
    /// Synchronous when already on the main thread, because the sign-in window's
    /// two-second poll asks for the cookie and acts on the answer, and deferring
    /// that would put a closed window's work after the window.
    static func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    // MARK: - The session

    /// The claude.ai session cookie, if the sign-in left one. Asked of WebKit,
    /// never of another application's files.
    static func session(_ done: @escaping (String?) -> Void) {
        onMain {
            store.getAllCookies { cookies in
                let match = cookies.first {
                    $0.name == cookieName && $0.domain.hasSuffix(host) && !$0.value.isEmpty
                }
                // An expired cookie is not a session; WebKit hands them over anyway.
                if let match, let expiry = match.expiresDate, expiry <= Date() {
                    done(nil); return
                }
                done(match?.value)
            }
        }
    }

    /// Empties AgentBar's own store of everything claude.ai put there. The one
    /// place a sign-in can be undone, and it undoes all of it.
    ///
    /// Everything, not just the cookie: signing out to sign back in **as
    /// somebody else** is the reason people press this, and a site that still
    /// has its local storage can put you straight back into the account you were
    /// trying to leave. So the site's whole record goes — cookies, local
    /// storage, databases, caches — and then the cookie jar is swept again by
    /// hand, because a record list can be stale.
    static func signOut(_ done: @escaping () -> Void) {
        // First, so that a failure halfway through leaves the app claiming
        // nothing rather than claiming a session it no longer has.
        connected = false
        onMain {
            let data = WKWebsiteDataStore.default()
            let types = WKWebsiteDataStore.allWebsiteDataTypes()
            data.fetchDataRecords(ofTypes: types) { records in
                let mine = records.filter {
                    $0.displayName == host || $0.displayName.hasSuffix("." + host)
                }
                data.removeData(ofTypes: types, for: mine) { sweepCookies(done) }
            }
        }
    }

    /// Always reached from `signOut`, which is already on the main thread.
    private static func sweepCookies(_ done: @escaping () -> Void) {
        store.getAllCookies { cookies in
            let mine = cookies.filter { $0.domain.hasSuffix(host) }
            guard !mine.isEmpty else { done(); return }
            var left = mine.count
            for cookie in mine {
                store.delete(cookie) {
                    left -= 1
                    if left == 0 { done() }
                }
            }
        }
    }

    // MARK: - The two calls the site makes

    /// `Error` so the two calls can be a `Result` chain; each case names a cause
    /// the settings line can put in a sentence.
    enum Failure: Equatable, Error {
        case noSession
        case declined(Int)
        case unreachable
        case unexpected(Int)
    }

    /// Account → usage, in that order, because the usage path needs the account's
    /// uuid and nothing local knows it.
    static func fetch(done: @escaping (Result<ClaudeQuota.Snapshot, Failure>) -> Void) {
        session { key in
            guard let key else { done(.failure(.noSession)); return }
            get("https://\(host)/api/organizations", key: key) { result in
                switch result {
                case .failure(let why): done(.failure(why))
                case .success(let data):
                    guard let org = organization(in: data) else {
                        done(.failure(.unexpected(200))); return
                    }
                    get("https://\(host)/api/organizations/\(org.uuid)/usage", key: key) { second in
                        switch second {
                        case .failure(let why): done(.failure(why))
                        case .success(let body):
                            guard let snap = ClaudeQuota.parse(body, account: org.name) else {
                                done(.failure(.unexpected(200))); return
                            }
                            done(.success(snap))
                        }
                    }
                }
            }
        }
    }

    /// Which account the numbers are for. An account can belong to several
    /// organisations; the site shows the first, and a percentage with the wrong
    /// name on it is worse than no name, so the name travels with the number.
    static func organization(in data: Data) -> (uuid: String, name: String?)? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        for entry in list {
            guard let uuid = entry["uuid"] as? String, !uuid.isEmpty else { continue }
            return (uuid, entry["name"] as? String)
        }
        return nil
    }

    private static func get(_ url: String, key: String,
                            done: @escaping (Result<Data, Failure>) -> Void) {
        guard let url = URL(string: url) else { done(.failure(.unexpected(0))); return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("\(cookieName)=\(key)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Ephemeral, and the cookie set by hand: the shared storage must not
        // acquire a claude.ai session as a side effect of asking.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        session.dataTask(with: request) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard let http = response as? HTTPURLResponse else {
                done(.failure(error == nil ? .unexpected(0) : .unreachable)); return
            }
            switch http.statusCode {
            case 200:
                guard let data else { done(.failure(.unexpected(200))); return }
                done(.success(data))
            case 401, 403: done(.failure(.declined(http.statusCode)))
            case let code: done(.failure(.unexpected(code)))
            }
        }.resume()
    }
}

// MARK: - Signing in

/// The sign-in window: claude.ai's own login page, in a window of ours.
///
/// It is deliberately a plain window with a web view and nothing else — no
/// injected script, no form of our own, no interception. The page is theirs, the
/// typing goes to them, and all this window does is notice when a session cookie
/// appears and then get out of the way.
final class ClaudeWebLogin: NSObject, WKNavigationDelegate, NSWindowDelegate {
    static let shared = ClaudeWebLogin()

    private var window: NSWindow?
    private var web: WKWebView?
    private var onDone: (() -> Void)?
    private var poll: Timer?

    /// A plain, current desktop Safari string. Not a disguise — this *is* WebKit,
    /// rendering their page, in a window the person opened — but the shape a site
    /// expects, so feature detection lands where it would in Safari.
    static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.5 Safari/605.1.15"

    func show(onConnected: @escaping () -> Void) {
        onDone = onConnected
        if window == nil { build() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        web?.load(URLRequest(url: URL(string: "https://\(ClaudeWeb.host)/login")!))
        // The cookie can appear without a navigation this window sees (the page
        // sets it from script mid-flow), so the check is on a clock rather than
        // hung off the delegate alone.
        poll?.invalidate()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.checkForSession()
        }
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // persistent: the session outlives the window
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 520, height: 680),
                            configuration: config)
        // WKWebView's own user agent omits the `Version/… Safari/…` tail, and a
        // site that reads it decides this is not a browser it knows. claude.ai
        // answered the first attempt with "there was an error logging you in"
        // before a single character had been typed.
        web.customUserAgent = Self.browserUserAgent
        web.navigationDelegate = self
        self.web = web

        let w = NSWindow(contentRect: web.frame,
                         styleMask: [.titled, .closable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Sign in to Claude"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = web
        w.delegate = self
        window = w
    }

    /// Closing the window is giving up on signing in, and the clock goes with it —
    /// otherwise it keeps asking for a cookie every two seconds until the next
    /// sign-in, for a window nobody can see.
    func windowWillClose(_ notification: Notification) {
        poll?.invalidate()
        poll = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        checkForSession()
    }

    private func checkForSession() {
        ClaudeWeb.session { [weak self] key in
            guard key != nil else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.poll?.invalidate()
                self.poll = nil
                ClaudeWeb.connected = true
                self.window?.close()
                self.onDone?()
            }
        }
    }
}

// MARK: - Keeping it fresh

/// The same job `ClaudeQuota` does for the OAuth path: ask on a clock, keep one
/// snapshot, say what happened. Kept apart from it because the two get their
/// numbers from different doors, and folding them together would mean one class
/// with two credential models and two failure vocabularies.
final class ClaudeWebQuota {
    static let shared = ClaudeWebQuota()

    private let lock = NSLock()
    private var snapshot: ClaudeQuota.Snapshot?
    private var nextAllowed = Date.distantPast
    private var inFlight = false
    private var _status: ClaudeQuota.Status = .off

    /// claude.ai's own page polls on about this cadence; there is no documented
    /// floor, so this stays well inside what a person sitting on the site does.
    private static let interval: TimeInterval = 300
    private static let maxAge: TimeInterval = 30 * 60

    var status: ClaudeQuota.Status {
        lock.lock(); defer { lock.unlock() }
        return _status
    }

    var onStatus: (() -> Void)?

    private func set(_ new: ClaudeQuota.Status) {
        guard _status != new else { return }
        _status = new
        DispatchQueue.main.async { [weak self] in self?.onStatus?() }
    }

    func latest(now: Date = Date()) -> ClaudeQuota.Snapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let s = snapshot, now.timeIntervalSince(s.at) < Self.maxAge else { return nil }
        return s
    }

    func refreshIfDue(now: Date = Date(), changed: @escaping () -> Void) {
        guard ClaudeQuota.enabled, ClaudeWeb.connected else {
            lock.lock(); snapshot = nil; set(.off); lock.unlock()
            return
        }
        lock.lock()
        guard !inFlight, now >= nextAllowed else { lock.unlock(); return }
        inFlight = true
        nextAllowed = now.addingTimeInterval(Self.interval)
        if snapshot == nil { set(.asking) }
        lock.unlock()

        ClaudeWeb.fetch { [weak self] result in
            guard let self else { return }
            self.lock.lock()
            self.inFlight = false
            var fresh = false
            switch result {
            case .success(let snap):
                fresh = self.snapshot?.windows != snap.windows
                self.snapshot = snap
                self.set(.ok(at: snap.at, account: snap.account))
            case .failure(let why):
                self.set(Self.status(for: why))
            }
            self.lock.unlock()
            if fresh { changed() }
        }
    }

    /// Ask now — the button, and the first call after a sign-in.
    func checkNow(changed: @escaping () -> Void) {
        lock.lock(); nextAllowed = .distantPast; lock.unlock()
        refreshIfDue(changed: changed)
    }

    /// The web path's failures in the vocabulary the settings line already
    /// speaks, so one sentence covers both doors.
    static func status(for failure: ClaudeWeb.Failure) -> ClaudeQuota.Status {
        switch failure {
        case .noSession:          return .loggedOut
        case .declined(let code): return .declined(code: code, message: nil)
        case .unreachable:        return .unreachable
        case .unexpected(let c):  return .unexpected(c)
        }
    }
}

import Cocoa

/// The part of every menu that is about AgentBar itself rather than about any one
/// session: colour, sounds, appearance, diagnostics, Settings, the update row,
/// feedback and Quit.
///
/// Both surfaces offer it — the menu bar's dropdown and the island's ⋯ menu — and
/// in either single-surface mode the one that is up is the only menu there is. For
/// a long time each built its own copy, and the copies drifted: 1.34.0 shipped
/// with an island "Check for Updates…" that checked and then had nowhere to say
/// what it found, so nobody in Island-only mode could ever update. Sharing one
/// helper fixed that row; this makes the whole section one list, so the next
/// divergence is a failing test (`AppMenuModelTests`) instead of a release note.
///
/// The model is plain data computed from `Inputs`, which makes it testable without
/// AppKit state. `AppMenuRenderer` turns it into NSMenuItems; each surface hands
/// the renderer its own target and selector, and its handler resolves the item
/// back to an `AppMenuAction` and calls `perform()`. What a surface shows only for
/// itself (the menu bar's Open ▸ and shortcut row; the island's Take a break; both
/// surfaces' Today and New task…) stays in that surface's builder, outside this list.
enum AppMenuModel {
    /// Everything the section is drawn from, gathered in one place so a test can
    /// feed both surfaces the same state and compare what they render.
    struct Inputs: Equatable {
        var update: UpdateChecker.Status
        var appVersion: String
        var systemColor: Bool
        var soundsOn: Bool
        var diagnosticsFailures: Int
        var macOSVersion: String
        /// The version whose notes the menu still offers (`ReleaseNotes.menuOffer`).
        var whatsNew: String? = nil

        static var current: Inputs {
            Inputs(update: UpdateChecker.shared.status,
                   appVersion: AppMenuModel.appVersion,
                   systemColor: IconColor.system,
                   soundsOn: SoundCenter.enabled,
                   diagnosticsFailures: Diagnostics.failures,
                   macOSVersion: AppMenuModel.macOSVersion,
                   whatsNew: ReleaseNotes.menuOffer(current: AppMenuModel.appVersion,
                                                    releases: ReleaseNotes.bundled))
        }
    }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
    }

    static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// The shared section, top to bottom. Separators are part of it, so the gap
    /// between "how AgentBar looks" and "AgentBar the app" is the same on both.
    static func appSection(_ i: Inputs) -> [AppMenuEntry] {
        [
            AppMenuEntry(id: "color", title: "Color", symbol: "paintpalette", children: [
                AppMenuEntry(id: "color.color", title: "Color", action: .chooseColor(system: false),
                             on: !i.systemColor),
                AppMenuEntry(id: "color.system", title: "System", action: .chooseColor(system: true),
                             on: i.systemColor),
            ]),
            // One-click mute/unmute; volume and the cue details live in Settings.
            AppMenuEntry(id: "sounds", title: "Sounds", symbol: "speaker.wave.2",
                         action: .toggleSounds, on: i.soundsOn,
                         toolTip: i.soundsOn
                            ? "Cues when a session needs approval, asks a question or finishes — volume in Settings"
                            : "Off — click for a soft cue when a session needs approval, asks or finishes"),
            // Where AgentBar shows itself (menu bar / island / both), plus the
            // first-run blurb — the same window, reachable again.
            AppMenuEntry(id: "appearance", title: "Appearance…", symbol: "macwindow.on.rectangle",
                         action: .openAppearance),
            diagnosticsEntry(failures: i.diagnosticsFailures),
            AppMenuEntry(id: "settings", title: "Settings…", symbol: "gearshape",
                         action: .openSettings),
            .separator("sep.app"),
            updateEntry(i.update, appVersion: i.appVersion),
        ] + notesEntries(i) + [
            // A way to say something that is not a bug report. It opens the
            // project's Discussions in the browser and nothing else: the app makes
            // no request of its own, and the prefilled body is two version numbers.
            AppMenuEntry(id: "feedback", title: "Send Feedback…", symbol: "bubble.left",
                         action: .sendFeedback,
                         toolTip: "Opens a new discussion on GitHub in your browser"),
            AppMenuEntry(id: "quit", title: "Quit AgentBar", action: .quit, keyEquivalent: "q"),
        ]
    }

    /// Carries the verdict of the last background pass rather than only opening
    /// Settings: a silent failure that waits to be looked for is still silent.
    static func diagnosticsEntry(failures broken: Int) -> AppMenuEntry {
        AppMenuEntry(
            id: "diagnostics",
            title: broken == 0
                ? "Diagnostics…"
                : "Diagnostics — \(broken) problem\(broken == 1 ? "" : "s")…",
            symbol: broken == 0 ? "stethoscope" : "exclamationmark.triangle",
            action: .openDiagnostics,
            toolTip: broken == 0
                ? "Check that every agent's hooks are wired and working."
                : "Something is stopping an agent from reporting. Open for the details and the fix.")
    }

    /// One row that is the whole update UI: check → checking → result / install.
    /// The current version rides along as a badge, so no separate "Version" row.
    /// Carries an icon so the bottom section (Quit gets a system icon on new macOS)
    /// keeps one consistent icon gutter instead of ragged indents.
    ///
    /// While there is nothing to click (checking, downloading, a fresh "Up to
    /// date") the row has no action and renders disabled, which is the point: a
    /// row that looks clickable and does nothing is worse than a quiet one.
    static func updateEntry(_ status: UpdateChecker.Status, appVersion: String) -> AppMenuEntry {
        var e = AppMenuEntry(id: "update", title: "", symbol: "arrow.triangle.2.circlepath",
                             badge: appVersion)
        switch status {
        case .idle:
            e.title = "Check for Updates…"
            e.action = .checkForUpdates
        case .checking:
            e.title = "Checking for updates…"
        case .upToDate:
            e.title = "Up to date"
            e.symbol = "checkmark.circle"
        case .available(let v):
            e.title = "Update to \(v) — Install & Relaunch"
            e.accent = true
            e.action = .installUpdate
            e.symbol = "arrow.down.circle.fill"
            e.badge = nil
        case .ready(let v):
            // Downloaded and verified, waiting for a quiet moment to install by
            // itself; the click is for whoever would rather not wait.
            e.title = "Update to \(v) ready — Relaunch now"
            e.accent = true
            e.action = .installUpdate
            e.toolTip = "Installs by itself once nothing is waiting on you "
                + "and you have been away for five minutes."
            e.symbol = "arrow.down.circle.fill"
            e.badge = nil
        case .downloading(let v):
            e.title = "Downloading \(v)…"
            e.symbol = "arrow.down.circle"
            e.badge = nil
        case .failed(let reason):
            e.title = "\(reason) — Retry"
            e.action = .checkForUpdates
            e.symbol = "exclamationmark.arrow.triangle.2.circlepath"
        }
        return e
    }

    /// Release notes, in the menu only while there is something to read: what the
    /// update on offer brings, before it is installed, and — for two weeks after an
    /// update arrived — what it brought, until the notes have been opened. Never
    /// more than one row, and nothing on the menu bar's mark: an update is not news
    /// that earns an interruption (CLAUDE.md rule 2).
    static func notesEntries(_ i: Inputs) -> [AppMenuEntry] {
        switch i.update {
        case .available(let v), .downloading(let v), .ready(let v):
            return [AppMenuEntry(id: "notes", title: "What's in \(v)…", symbol: "doc.text",
                                 action: .openWhatsNew,
                                 toolTip: "The release notes, before you install it")]
        default:
            guard let v = i.whatsNew else { return [] }
            return [AppMenuEntry(id: "notes", title: "What's New in \(v)…", symbol: "sparkles",
                                 action: .openWhatsNew, badge: "New")]
        }
    }

    /// Where Send Feedback goes: a new discussion in the General category
    /// (Discussions are enabled on the repo, and `general` is a real category slug —
    /// an unknown one drops the visitor on the category picker instead).
    ///
    /// The body carries the two version numbers a reply would ask for first, and
    /// nothing else — no paths, no user name, no session data. It is only a
    /// prefill: the person sees it in the browser and can delete it before posting.
    static func feedbackURL(appVersion: String, macOSVersion: String) -> URL {
        var c = URLComponents(string: "https://github.com/michalstrnadel/AgentBar/discussions/new")!
        c.queryItems = [
            URLQueryItem(name: "category", value: "general"),
            URLQueryItem(name: "body", value: "\n\n---\nAgentBar \(appVersion) · macOS \(macOSVersion)"),
        ]
        return c.url!
    }
}

/// What a shared row does when clicked. Surfaces never switch on this to decide
/// titles or state — the model already did — only to run it.
enum AppMenuAction: Equatable {
    case chooseColor(system: Bool)
    case toggleSounds
    case openAppearance
    case openDiagnostics
    case openSettings
    case checkForUpdates
    case installUpdate
    case openWhatsNew
    case sendFeedback
    case quit

    func perform() {
        switch self {
        case .chooseColor(let system):
            IconColor.system = system
        case .toggleSounds:
            // A just-enabled cue set says hello, so the click is audibly
            // confirmed; the Settings window (if open) follows.
            SoundCenter.enabled.toggle()
            if SoundCenter.enabled { SoundCenter.shared.preview() }
            SettingsWindow.shared.refreshIfVisible()
        case .openAppearance:
            WelcomeWindow.shared.show()
        case .openDiagnostics:
            // Settings re-runs the checks every time it is shown.
            SettingsWindow.shared.show(page: .diagnostics)
        case .openSettings:
            SettingsWindow.shared.show()
        case .checkForUpdates:
            UpdateChecker.shared.check(manual: true)
        case .installUpdate:
            UpdateChecker.shared.installAvailable()
        case .openWhatsNew:
            SettingsWindow.shared.show(page: .whatsNew)
        case .sendFeedback:
            NSWorkspace.shared.open(AppMenuModel.feedbackURL(appVersion: AppMenuModel.appVersion,
                                                             macOSVersion: AppMenuModel.macOSVersion))
        case .quit:
            NSApp.terminate(nil)
        }
    }
}

/// One row of the shared section, as data.
struct AppMenuEntry: Equatable {
    var id: String
    var title: String
    /// Drawn in the accent colour — reserved for an update waiting to be installed.
    var accent = false
    var symbol: String?
    /// nil renders the row disabled.
    var action: AppMenuAction?
    /// nil draws no checkmark column state at all.
    var on: Bool?
    var toolTip: String?
    var badge: String?
    var keyEquivalent = ""
    var children: [AppMenuEntry] = []
    var isSeparator = false

    static func separator(_ id: String) -> AppMenuEntry {
        AppMenuEntry(id: id, title: "", isSeparator: true)
    }
}

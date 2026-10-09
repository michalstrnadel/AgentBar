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
/// surfaces' Today and New Task…) stays in that surface's builder, outside this list.
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
        var keepAwake = KeepAwakeMenu()

        static var current: Inputs {
            Inputs(update: UpdateChecker.shared.status,
                   appVersion: AppMenuModel.appVersion,
                   systemColor: IconColor.system,
                   soundsOn: SoundCenter.enabled,
                   diagnosticsFailures: Diagnostics.failures,
                   macOSVersion: AppMenuModel.macOSVersion,
                   whatsNew: ReleaseNotes.menuOffer(current: AppMenuModel.appVersion,
                                                    releases: ReleaseNotes.bundled),
                   keepAwake: .current)
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
            AppMenuEntry(id: "color", title: "Icon Color", symbol: "paintpalette", children: [
                AppMenuEntry(id: "color.color", title: "Colorful", action: .chooseColor(system: false),
                             on: !i.systemColor),
                AppMenuEntry(id: "color.system", title: "Monochrome", action: .chooseColor(system: true),
                             on: i.systemColor),
            ]),
            // One-click mute/unmute; volume and the cue details live in Settings.
            AppMenuEntry(id: "sounds", title: "Sounds", symbol: "speaker.wave.2",
                         action: .toggleSounds, on: i.soundsOn,
                         toolTip: i.soundsOn
                            ? "Cues when a session needs approval, asks a question or finishes — volume in Settings"
                            : "Off — click for a soft cue when a session needs approval, asks or finishes"),
            keepAwakeEntry(i.keepAwake),
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

    /// Keep Mac Awake: every mode one pick away, the live one ticked, and what is
    /// left on the badge. Picking the ticked mode again turns it off; the island's
    /// cup is the one-click toggle.
    static func keepAwakeEntry(_ k: KeepAwakeMenu) -> AppMenuEntry {
        // What it is doing, first: the one line that answers "is it on, and why".
        let on = k.current != nil || k.held
        var children = [AppMenuEntry(id: "awake.status", title: k.reason,
                                     symbol: on ? "cup.and.saucer.fill" : "moon.zzz")]
        children += KeepAwakeChoice.allCases.map { c in
            AppMenuEntry(id: "awake.\(c.rawValue)", title: c.title(untilMinutes: k.untilMinutes),
                         action: .keepAwake(c), on: k.current == c,
                         toolTip: k.current == c ? "On — pick again to turn it off" : c.help)
        }
        children.append(.separator("awake.sep"))
        children.append(AppMenuEntry(id: "awake.display", title: "Keep Screen On",
                                     action: .keepAwakeToggleDisplay, on: k.display,
                                     toolTip: k.display ? "On — the screen stays lit while Keep Awake is on"
                                        : "Off — the screen dims and locks as usual; the Mac keeps working"))
        children.append(AppMenuEntry(id: "awake.sleepdone", title: "Sleep When Agents Are Done",
                                     action: .keepAwakeToggleSleepWhenDone, on: k.sleepWhenDone,
                                     toolTip: "While Agents Work: once they finish and you've been away five "
                                        + "minutes, the Mac goes to sleep"))
        // The ellipsis says what macOS convention says it says: another step
        // follows, here the password.
        children.append(AppMenuEntry(id: "awake.lid",
                                     title: k.lid ? "Stay Awake With Lid Closed" : "Stay Awake With Lid Closed…",
                                     action: .keepAwakeToggleLid, on: k.lid,
                                     toolTip: k.lid ? "On — closing the lid won't stop your agents. Click to turn off."
                                        : "Close the lid and your agents keep working. Asks for your password; "
                                          + "turns off by itself when Keep Awake ends."))
        children.append(.separator("awake.sep2"))
        if on {
            children.append(AppMenuEntry(id: "awake.off", title: "Turn Off", action: .keepAwakeOff,
                                         toolTip: k.held ? "Off until what started it goes away" : nil))
        }
        if k.lidLeftover {
            children.append(AppMenuEntry(
                id: "awake.restore", title: "Sleep Still Disabled — Restore…",
                symbol: "exclamationmark.triangle", action: .keepAwakeRestoreLid,
                toolTip: "An earlier closed-lid session left sleep off. Asks for your password once."))
        }
        children.append(AppMenuEntry(id: "awake.settings", title: "Keep Awake Settings…",
                                     action: .openKeepAwakeSettings))
        return AppMenuEntry(id: "awake", title: "Keep Mac Awake",
                            symbol: on ? "cup.and.saucer.fill" : "cup.and.saucer",
                            on: on, toolTip: k.reason, badge: k.badge,
                            children: children)
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
            // What to do about it, not only that it happened.
            e.toolTip = "Nothing was changed. Check your connection and retry, or get the "
                + "latest from github.com/michalstrnadel/AgentBar/releases."
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
    case keepAwake(KeepAwakeChoice)
    case keepAwakeOff
    case keepAwakeRestoreLid
    case keepAwakeToggleDisplay
    case keepAwakeToggleLid
    case keepAwakeToggleSleepWhenDone
    case openKeepAwakeSettings

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
            // The click closes the menu that would have shown the answer.
            UpdatePrompt.shared.check()
        case .installUpdate:
            UpdateChecker.shared.installAvailable()
        case .openWhatsNew:
            SettingsWindow.shared.show(page: .whatsNew)
        case .sendFeedback:
            NSWorkspace.shared.open(AppMenuModel.feedbackURL(appVersion: AppMenuModel.appVersion,
                                                             macOSVersion: AppMenuModel.macOSVersion))
        case .quit:
            NSApp.terminate(nil)
        case .keepAwake(let choice):
            KeepAwake.shared.pick(choice)
            SettingsWindow.shared.refreshIfVisible()
        case .keepAwakeOff:
            KeepAwake.shared.stop()
            SettingsWindow.shared.refreshIfVisible()
        case .keepAwakeRestoreLid:
            LidSleep.shared.restoreLeftover { _ in
                KeepAwake.shared.reevaluate()
                SettingsWindow.shared.refreshIfVisible()
            }
        case .keepAwakeToggleDisplay:
            KeepAwake.shared.setKeepDisplayOn(!KeepAwakePrefs.settings().keepDisplayOn)
            SettingsWindow.shared.refreshIfVisible()
        case .keepAwakeToggleLid:
            KeepAwake.shared.setLid(!KeepAwakePrefs.lid())
            SettingsWindow.shared.refreshIfVisible()
        case .keepAwakeToggleSleepWhenDone:
            KeepAwakePrefs.setSleepWhenDone(!KeepAwakePrefs.settings().sleepWhenDone)
            KeepAwake.shared.settingsChanged()
            SettingsWindow.shared.refreshIfVisible()
        case .openKeepAwakeSettings:
            SettingsWindow.shared.show(page: .keepAwake)
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

/// What the Keep Mac Awake row is drawn from, as plain values.
struct KeepAwakeMenu: Equatable {
    var current: KeepAwakeChoice?
    var untilMinutes = 18 * 60
    var reason = "Off"
    var badge: String?
    var display = false
    var lid = false
    var lidLeftover = false
    /// A trigger holds the Mac up (no click did).
    var held = false
    var sleepWhenDone = false

    static var current: KeepAwakeMenu {
        let k = KeepAwake.shared
        return KeepAwakeMenu(current: k.currentChoice, untilMinutes: KeepAwakePrefs.untilMinutes(),
                             reason: k.isOn ? k.decision.reason : "Off — the Mac sleeps as usual",
                             badge: k.badge, display: KeepAwakePrefs.settings().keepDisplayOn,
                             lid: KeepAwakePrefs.lid() || LidSleep.shared.isOn,
                             lidLeftover: LidSleep.shared.hasLeftover,
                             held: k.decision.trigger != nil,
                             sleepWhenDone: KeepAwakePrefs.settings().sleepWhenDone)
    }
}

extension KeepAwakeChoice {
    /// The tooltip of the choice's menu row.
    var help: String {
        switch self {
        case .whileAgentsWork: return "Awake while a session on this Mac works, and 5 minutes after its last turn"
        case .fifteenMinutes:  return "Awake for the next 15 minutes"
        case .thirtyMinutes:   return "Awake for the next 30 minutes"
        case .oneHour:         return "Awake for the next hour"
        case .twoHours:        return "Awake for the next two hours"
        case .untilTime:       return "Awake until this time — change it in Keep Awake Settings"
        case .indefinite:      return "Awake until you turn it off — no time limit"
        }
    }
}

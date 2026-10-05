import Cocoa

/// Settings ▸ What's New: the version that is running and the update on offer, the
/// notes of the update before it installs, then the notes of what arrived — the
/// releases not yet read on top, tagged, and a few before them for context.
///
/// It is the one place an update has room to explain itself, so it is also where
/// the menu's "What's New in …" row and `agentbar://settings/whats-new` lead.
/// Opening it is what marks the notes read (`ReleaseNotes.markSeen`); nothing else
/// does, and nothing opens it but the person.
extension SettingsWindow {
    /// The releases shown below the unread ones: enough to see what came just
    /// before, and no more — the full history is a link away.
    static let olderNotesShown = 3

    func watchNotes() {
        guard updateObserver == nil else { return }
        updateObserver = NotificationCenter.default.addObserver(
            forName: UpdateChecker.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncWhatsNew(markingSeen: false)
        }
        notesObserver = NotificationCenter.default.addObserver(
            forName: ReleaseNotes.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncNotesDot()
        }
    }

    func stopWatchingNotes() {
        for o in [updateObserver, notesObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(o)
        }
        updateObserver = nil
        notesObserver = nil
        freshNotes = []
    }

    func syncNotesDot() {
        let unread = !ReleaseNotes.unseen(current: AppMenuModel.appVersion,
                                          releases: ReleaseNotes.bundled).isEmpty
        sidebarItems.first { $0.page == .whatsNew }?.showsDot = unread
    }

    /// The page from scratch. `markingSeen` when it is on screen: the unread notes
    /// are drawn with their tag first, then counted as read.
    func syncWhatsNew(markingSeen: Bool) {
        guard let host = whatsNewHost else { return }
        let current = AppMenuModel.appVersion
        let all = ReleaseNotes.bundled
        let unseen = ReleaseNotes.unseen(current: current, releases: all)
        if markingSeen { freshNotes.formUnion(unseen.map(\.version)) }

        for old in host.arrangedSubviews { old.removeFromSuperview() }
        func add(_ v: NSView) {
            host.addArrangedSubview(v)
            if !(v is NSTextField) { v.widthAnchor.constraint(equalTo: host.widthAnchor).isActive = true }
        }

        add(SettingsChrome.card(statusRows(current: current)))

        if let next = UpdateChecker.shared.upcoming {
            add(SettingsChrome.header(WhatsNewPage.upcomingHeader(next.version)))
            if next.releases.isEmpty {
                add(SettingsChrome.caption(WhatsNewPage.noUpcomingNotes))
            }
            for r in next.releases { add(releaseCard(r, tag: nil)) }
        }

        let shown = WhatsNewPage.shown(all, current: current,
                                       unread: Set(unseen.map(\.version)).union(freshNotes),
                                       older: Self.olderNotesShown)
        if all.isEmpty {
            add(SettingsChrome.caption(WhatsNewPage.noBundledNotes))
        } else {
            add(SettingsChrome.header(WhatsNewPage.installedHeader(unread: shown.unread.count)))
            for r in shown.unread { add(releaseCard(r, tag: "New")) }
            for r in shown.older { add(releaseCard(r, tag: nil)) }
        }
        let more = SettingsChrome.smallButton("All releases on GitHub", target: self,
                                              action: #selector(openAllReleases))
        more.toolTip = ReleaseNotes.allReleasesURL.absoluteString
        add(SettingsChrome.customRow(buttonStrip([more]), height: 28))

        if markingSeen { ReleaseNotes.markSeen(current: current) }
        sidebarItems.first { $0.page == .whatsNew }?.showsDot =
            !ReleaseNotes.unseen(current: current, releases: all).isEmpty
    }

    /// "AgentBar 1.39.0" and the one button that fits, then what the updater is
    /// doing. The sentence has a row of its own: under the name, the caption's
    /// width leaves room for a switch, and "Check for Updates" was cut to "Chec…".
    private func statusRows(current: String) -> [NSView] {
        let u = UpdateChecker.shared
        let button = SettingsChrome.smallButton(WhatsNewPage.buttonTitle(u.status), target: self,
                                                action: #selector(whatsNewUpdateClicked))
        button.isEnabled = WhatsNewPage.buttonEnabled(u.status)
        return [SettingsChrome.row("AgentBar \(current)", control: button),
                SettingsChrome.noteRow(SettingsChrome.caption(
                    WhatsNewPage.statusLine(u.status, autoUpdate: u.autoUpdate)))]
    }

    /// One release: its number, a tag, its date, and its notes.
    private func releaseCard(_ r: ReleaseNotes.Release, tag: String?) -> NSView {
        let date = NSTextField(labelWithString: r.date.map { ReleaseNotes.displayDate($0) } ?? "")
        date.font = .systemFont(ofSize: 11.5)
        date.textColor = .secondaryLabelColor
        let title = SettingsChrome.row(r.version, control: date, accessory: tag.map(pill))
        var rows: [NSView] = [title]
        if !r.blocks.isEmpty {
            let width = SettingsChrome.cardWidth - SettingsChrome.rowInset * 2
            rows.append(SettingsChrome.customRow(ReleaseNotesView(r, width: width), height: 0))
        }
        return SettingsChrome.card(rows)
    }

    /// The accent-filled tag beside an unread release.
    private func pill(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .semibold)
        label.textColor = .white
        let box = NSStackView(views: [label])
        box.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        return box
    }

    private func buttonStrip(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc func whatsNewUpdateClicked() {
        switch UpdateChecker.shared.status {
        case .available, .ready: UpdateChecker.shared.installAvailable()
        default: UpdateChecker.shared.check(manual: true)
        }
    }

    @objc func openAllReleases() {
        NSWorkspace.shared.open(ReleaseNotes.allReleasesURL)
    }
}

/// The words on Settings ▸ What's New, worked out without a window.
enum WhatsNewPage {
    static let noBundledNotes = "This build carries no release notes — every release's are on GitHub."
    static let noUpcomingNotes = "Its release came without notes."

    static func upcomingHeader(_ v: String) -> String { "Coming in \(v)" }

    static func installedHeader(unread: Int) -> String {
        unread == 0 ? "Recent releases"
            : unread == 1 ? "New since you last looked" : "New since you last looked — \(unread) releases"
    }

    /// The line under the version: what the updater is doing, in a sentence.
    static func statusLine(_ s: UpdateChecker.Status, autoUpdate: Bool) -> String {
        switch s {
        case .available(let v):
            return autoUpdate ? "\(v) is out and downloads by itself. Its notes are below."
                : "\(v) is out. Its notes are below."
        case .downloading(let v): return "Downloading \(v)…"
        case .ready(let v): return "\(v) is ready and installs itself once nothing is waiting on you."
        case .checking: return "Checking for updates…"
        case .upToDate: return "This is the newest release."
        case .failed(let reason): return reason + "."
        case .idle:
            return autoUpdate ? "Updates install themselves when nothing is waiting on you."
                : "Updates wait for you to install them — Settings ▸ General."
        }
    }

    static func buttonTitle(_ s: UpdateChecker.Status) -> String {
        switch s {
        case .available: return "Install & Relaunch"
        case .ready: return "Relaunch now"
        case .downloading: return "Downloading…"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .idle, .failed: return "Check for Updates"
        }
    }

    static func buttonEnabled(_ s: UpdateChecker.Status) -> Bool {
        switch s {
        case .downloading, .checking, .upToDate: return false
        default: return true
        }
    }

    /// The installed releases the page lists: every unread one, then up to `older`
    /// before them. Never one newer than the running copy — a dev build's changelog
    /// may run ahead of its version.
    static func shown(_ all: [ReleaseNotes.Release], current: String, unread: Set<String>,
                      older: Int) -> (unread: [ReleaseNotes.Release], older: [ReleaseNotes.Release]) {
        let installed = ReleaseNotes.between(all, after: nil, upTo: current)
        let fresh = installed.filter { unread.contains($0.version) }
        let rest = installed.filter { !unread.contains($0.version) }
        // With nothing unread the running release leads, so the page is never empty.
        return (fresh, Array(rest.prefix(fresh.isEmpty ? older + 1 : older)))
    }
}

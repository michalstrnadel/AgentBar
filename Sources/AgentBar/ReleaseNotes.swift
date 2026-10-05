import Foundation

/// What changed, for the person whose AgentBar just changed under them.
///
/// An update installs itself at a quiet moment (`UpdateChecker`), so the release
/// that arrives is one nobody chose to read about. The notes are the CHANGELOG —
/// the same text the GitHub release carries — bundled into the app at build time
/// (`Scripts/build.sh`), so they are the notes of the code that is running, signed
/// with it, and readable offline. Nothing announces them: a row in the menu and a
/// dot in the Settings sidebar wait until they are looked at (CLAUDE.md rule 2 —
/// a window that opens itself after an update is exactly what that rule forbids).
///
/// This file is pure: parsing, and the bookkeeping of what has been seen. Drawing
/// is `ReleaseNotesView`; the page is Settings ▸ What's New.
enum ReleaseNotes {
    struct Release: Equatable {
        var version: String
        /// `YYYY-MM-DD` as the changelog writes it; nil for an undated section.
        var date: String?
        var blocks: [Block]
    }

    /// The handful of Markdown shapes the changelog is written in. Anything else —
    /// an HTML line for the GitHub page's picture — is left out rather than shown
    /// as source.
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String, level: Int)
    }

    // MARK: - Parsing

    /// Every versioned section, newest first, the way the file is written.
    /// `## Unreleased` and anything before the first version are skipped: a dev
    /// build must not present work in progress as something that shipped.
    static func parse(_ markdown: String) -> [Release] {
        var out: [Release] = []
        var current: Release?
        var para: [String] = []
        var bullet: (text: [String], level: Int)?

        func flush() {
            if let b = bullet, !b.text.isEmpty {
                current?.blocks.append(.bullet(b.text.joined(separator: " "), level: b.level))
            }
            bullet = nil
            if !para.isEmpty { current?.blocks.append(.paragraph(para.joined(separator: " "))) }
            para = []
        }
        func close() {
            flush()
            if let r = current { out.append(r) }
            current = nil
        }

        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                close()
                if let (v, d) = versionHeader(line) { current = Release(version: v, date: d, blocks: []) }
                continue
            }
            guard current != nil else { continue }
            if trimmed.isEmpty { flush(); continue }
            if line.hasPrefix("### ") {
                flush()
                current?.blocks.append(.heading(String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)))
                continue
            }
            if trimmed.hasPrefix("<") { continue }
            let indent = line.prefix { $0 == " " }.count
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                flush()
                bullet = ([String(trimmed.dropFirst(2))], indent >= 2 ? 1 : 0)
                continue
            }
            if bullet != nil, indent > 0 {
                bullet?.text.append(trimmed)
                continue
            }
            if bullet != nil { flush() }
            para.append(trimmed)
        }
        close()
        return out
    }

    /// `## 1.38.0 - 2026-10-05` → ("1.38.0", "2026-10-05"). A heading that does
    /// not start with a version is not a release.
    static func versionHeader(_ line: String) -> (String, String?)? {
        let rest = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let version = rest.prefix { $0.isNumber || $0 == "." }
        guard version.split(separator: ".").count == 3,
              version.split(separator: ".").allSatisfy({ !$0.isEmpty }) else { return nil }
        let tail = rest.dropFirst(version.count).trimmingCharacters(in: .whitespaces)
        var date: String?
        if tail.hasPrefix("-") || tail.hasPrefix("—") {
            let d = tail.dropFirst().trimmingCharacters(in: .whitespaces)
            if d.count >= 10 { date = String(d.prefix(10)) }
        }
        return (String(version), date)
    }

    /// The releases newer than `old` and no newer than `new`, newest first.
    /// `old == nil` means everything up to `new`.
    static func between(_ all: [Release], after old: String?, upTo new: String) -> [Release] {
        all.filter { r in
            !UpdateChecker.isNewer(r.version, than: new)
                && (old.map { UpdateChecker.isNewer(r.version, than: $0) } ?? true)
        }
    }

    /// The newest release older than `version` — where someone who upgraded
    /// before AgentBar kept track most likely came from.
    static func previous(to version: String, in all: [Release]) -> String? {
        all.first { UpdateChecker.isNewer(version, than: $0.version) }?.version
    }

    /// The bundle's own changelog, parsed once. Empty when the file is missing
    /// (a `swift run` build has no Resources): the page then says so instead of
    /// showing nothing.
    static let bundled: [Release] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md") else { return [] }
        return load(url)
    }()

    /// A changelog on disk — the running bundle's, or a staged update's.
    static func load(_ url: URL) -> [Release] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count < 4 << 20,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// The changelog inside an app bundle, for an update that is staged and
    /// verified: its notes are the ones it will install, every version since this
    /// one included, not only the newest release's.
    static func inBundle(_ app: URL) -> [Release] {
        load(app.appendingPathComponent("Contents/Resources/CHANGELOG.md"))
    }

    static let allReleasesURL = URL(string: "https://github.com/michalstrnadel/AgentBar/releases")!

    /// "5 October 2026" for "2026-10-05"; the raw text if it will not parse.
    static func displayDate(_ ymd: String, locale: Locale = Locale(identifier: "en_GB")) -> String {
        let p = DateFormatter()
        p.locale = Locale(identifier: "en_US_POSIX")
        p.timeZone = TimeZone(identifier: "UTC")
        p.dateFormat = "yyyy-MM-dd"
        guard let d = p.date(from: ymd) else { return ymd }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }

    // MARK: - What has been seen

    static let didChange = Notification.Name("AgentBarReleaseNotesDidChange")
    /// How long the menu offers a release's notes. The page keeps them for good,
    /// and its sidebar dot stays until they are opened; a menu row that never went
    /// away would become furniture nobody reads.
    static let menuOffer: TimeInterval = 14 * 86_400

    private static let seenKey = "releaseNotesSeen"
    private static let sinceKey = "releaseNotesUnseenSince"

    /// The newest version whose notes were looked at, or that never needed it (the
    /// version first installed). nil only before the first launch that knew.
    static func seen(_ d: UserDefaults = .standard) -> String? { d.string(forKey: seenKey) }

    /// Called once per launch, before anything is drawn. A fresh install has
    /// nothing to catch up on — the welcome window is its introduction. A copy
    /// upgraded from before this bookkeeping existed has no record of where it
    /// came from, so the newest release's notes count as unseen and older ones as
    /// read: offering a month of changelog to someone who lived through it is noise.
    static func noteLaunch(current: String, existingInstall: Bool, releases: [Release],
                           defaults d: UserDefaults = .standard, now: Date = Date()) {
        if seen(d) == nil {
            d.set(existingInstall ? (previous(to: current, in: releases) ?? "0") : current, forKey: seenKey)
        }
        if UpdateChecker.isNewer(current, than: seen(d) ?? current) {
            if d.object(forKey: sinceKey) == nil { d.set(now, forKey: sinceKey) }
        } else {
            d.removeObject(forKey: sinceKey)
        }
    }

    /// The releases this person has not seen the notes of, newest first. Empty
    /// after a downgrade, a fresh install, or once the page was opened.
    static func unseen(current: String, releases: [Release],
                       defaults d: UserDefaults = .standard) -> [Release] {
        guard let s = seen(d), UpdateChecker.isNewer(current, than: s) else { return [] }
        return between(releases, after: s, upTo: current)
    }

    /// The version the menu offers notes for, while it still does.
    static func menuOffer(current: String, releases: [Release], defaults d: UserDefaults = .standard,
                          now: Date = Date()) -> String? {
        guard !unseen(current: current, releases: releases, defaults: d).isEmpty,
              let since = d.object(forKey: sinceKey) as? Date,
              now.timeIntervalSince(since) < menuOffer else { return nil }
        return current
    }

    /// The page was shown: everything up to `current` has been seen.
    static func markSeen(current: String, defaults d: UserDefaults = .standard) {
        let had = d.object(forKey: sinceKey) != nil
            || UpdateChecker.isNewer(current, than: seen(d) ?? current)
        if !UpdateChecker.isNewer(seen(d) ?? "0", than: current) { d.set(current, forKey: seenKey) }
        d.removeObject(forKey: sinceKey)
        if had { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    /// Whether this Mac ran AgentBar before this launch: a preference only the app
    /// writes, or the hook copies it keeps in its folder.
    static func looksLikeExistingInstall(defaults d: UserDefaults = .standard,
                                         root: URL = AgentBarHome.root()) -> Bool {
        for key in ["presentationMode", "showWelcomeOnLaunch", "autoUpdate", "updateInstallAttempt"]
        where d.object(forKey: key) != nil { return true }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("hooks").path)
    }
}

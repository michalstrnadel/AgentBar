import AppKit
import Foundation
import Testing
@testable import AgentBar

/// What Settings ▸ What's New and the menu say after an update. The notes are the
/// changelog, so the changelog itself is held to the shape the app can read.
@Suite struct ReleaseNotesTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func defaults() throws -> UserDefaults {
        try #require(UserDefaults(suiteName: "agentbar-notes-\(UUID().uuidString)"))
    }

    private static let sample = """
    # Changelog

    Intro that is not a release.

    ## Unreleased

    - Work in progress.

    ## 1.39.0 - 2026-10-06

    A paragraph that wraps
    onto a second line.

    <p align="center"><img src="x.gif"></p>

    ### Added

    - **Release notes** in Settings — with `code`, a [link](https://example.com)
      and a continuation line.
      - A nested point
        that wraps too.
    - Another.

    ### Fixed

    * Star bullets count.

    ## 1.38.0 - 2026-10-05

    - Older.

    ## 1.37.1

    - Undated.
    """

    @Test func theChangelogParsesIntoReleases() {
        let r = ReleaseNotes.parse(Self.sample)
        #expect(r.map(\.version) == ["1.39.0", "1.38.0", "1.37.1"])
        #expect(r[0].date == "2026-10-06")
        #expect(r[2].date == nil)
        #expect(r[0].blocks == [
            .paragraph("A paragraph that wraps onto a second line."),
            .heading("Added"),
            .bullet("**Release notes** in Settings — with `code`, a [link](https://example.com) and a continuation line.",
                    level: 0),
            .bullet("A nested point that wraps too.", level: 1),
            .bullet("Another.", level: 0),
            .heading("Fixed"),
            .bullet("Star bullets count.", level: 0),
        ])
    }

    @Test func crlfAndJunkHeadingsAreHandled() {
        let r = ReleaseNotes.parse("## 2.0.0 - 2027-01-01\r\n\r\n- One.\r\n## Notes\r\n- Not a release.\r\n## 2.0\r\n")
        #expect(r.map(\.version) == ["2.0.0"])
        #expect(r[0].blocks == [.bullet("One.", level: 0)])
        #expect(ReleaseNotes.versionHeader("## 1.2.3 — 2026-01-02")! == ("1.2.3", "2026-01-02"))
        #expect(ReleaseNotes.versionHeader("## 1..3") == nil)
    }

    @Test func betweenIsExclusiveBelowAndInclusiveAbove() {
        let r = ReleaseNotes.parse(Self.sample)
        #expect(ReleaseNotes.between(r, after: "1.37.1", upTo: "1.39.0").map(\.version) == ["1.39.0", "1.38.0"])
        #expect(ReleaseNotes.between(r, after: nil, upTo: "1.38.0").map(\.version) == ["1.38.0", "1.37.1"])
        #expect(ReleaseNotes.previous(to: "1.39.0", in: r) == "1.38.0")
        #expect(ReleaseNotes.previous(to: "1.37.1", in: r) == nil)
    }

    /// A fresh install has read everything; an install from before the bookkeeping
    /// has read all but the newest release.
    @Test func aFreshInstallHasNothingUnread() throws {
        let d = try defaults()
        let r = ReleaseNotes.parse(Self.sample)
        ReleaseNotes.noteLaunch(current: "1.39.0", existingInstall: false, releases: r, defaults: d)
        #expect(ReleaseNotes.unseen(current: "1.39.0", releases: r, defaults: d).isEmpty)
        #expect(ReleaseNotes.menuOffer(current: "1.39.0", releases: r, defaults: d) == nil)
    }

    @Test func anUpgradeFromBeforeTrackingShowsOnlyTheNewest() throws {
        let d = try defaults()
        let r = ReleaseNotes.parse(Self.sample)
        ReleaseNotes.noteLaunch(current: "1.39.0", existingInstall: true, releases: r, defaults: d)
        #expect(ReleaseNotes.unseen(current: "1.39.0", releases: r, defaults: d).map(\.version) == ["1.39.0"])
        #expect(ReleaseNotes.menuOffer(current: "1.39.0", releases: r, defaults: d) == "1.39.0")
    }

    /// Two updates while nobody looked: both are unread, and opening the page reads both.
    @Test func unreadReleasesAccumulateUntilOpened() throws {
        let d = try defaults()
        let r = ReleaseNotes.parse(Self.sample)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        ReleaseNotes.noteLaunch(current: "1.37.1", existingInstall: false, releases: r, defaults: d, now: t0)
        ReleaseNotes.noteLaunch(current: "1.38.0", existingInstall: true, releases: r, defaults: d, now: t0)
        ReleaseNotes.noteLaunch(current: "1.39.0", existingInstall: true, releases: r, defaults: d,
                                now: t0.addingTimeInterval(86_400))
        #expect(ReleaseNotes.unseen(current: "1.39.0", releases: r, defaults: d).map(\.version)
                == ["1.39.0", "1.38.0"])
        // The menu's two weeks run from the first unread update, not the latest.
        #expect(ReleaseNotes.menuOffer(current: "1.39.0", releases: r, defaults: d,
                                       now: t0.addingTimeInterval(13 * 86_400)) == "1.39.0")
        #expect(ReleaseNotes.menuOffer(current: "1.39.0", releases: r, defaults: d,
                                       now: t0.addingTimeInterval(15 * 86_400)) == nil)
        ReleaseNotes.markSeen(current: "1.39.0", defaults: d)
        #expect(ReleaseNotes.unseen(current: "1.39.0", releases: r, defaults: d).isEmpty)
        #expect(ReleaseNotes.menuOffer(current: "1.39.0", releases: r, defaults: d, now: t0) == nil)
    }

    /// Going back to an older copy is not news, and does not forget what was read.
    @Test func aDowngradeOffersNothing() throws {
        let d = try defaults()
        let r = ReleaseNotes.parse(Self.sample)
        ReleaseNotes.noteLaunch(current: "1.39.0", existingInstall: false, releases: r, defaults: d)
        ReleaseNotes.noteLaunch(current: "1.38.0", existingInstall: true, releases: r, defaults: d)
        #expect(ReleaseNotes.unseen(current: "1.38.0", releases: r, defaults: d).isEmpty)
        ReleaseNotes.markSeen(current: "1.38.0", defaults: d)
        #expect(ReleaseNotes.seen(d) == "1.39.0")
    }

    @Test func theRenderedNotesKeepTheirMarkup() {
        let r = ReleaseNotes.parse(Self.sample)[0]
        let s = ReleaseNotesView.render(r.blocks)
        #expect(s.string.hasPrefix("A paragraph that wraps onto a second line.\nAdded\n•\tRelease notes in Settings"))
        #expect(!s.string.contains("**"))
        #expect(!s.string.contains("`"))
        let ns = s.string as NSString
        let link = s.attribute(.link, at: ns.range(of: "link").location, effectiveRange: nil) as? URL
        #expect(link == URL(string: "https://example.com"))
        let code = s.attribute(.font, at: ns.range(of: "code").location, effectiveRange: nil) as? NSFont
        #expect(code?.isFixedPitch == true)
        #expect(s.string.contains("◦\tA nested point"))
    }

    /// A repository path links to the file on GitHub; a scheme that would run
    /// something on click links nowhere.
    @Test func onlyWebLinksAreClickable() {
        let p = NSParagraphStyle()
        let rel = ReleaseNotesView.inline("[docs](docs/protocol.md)", size: 12, weight: .regular,
                                          color: .labelColor, style: p)
        #expect((rel.attribute(.link, at: 0, effectiveRange: nil) as? URL)?.absoluteString
                == "https://github.com/michalstrnadel/AgentBar/blob/main/docs/protocol.md")
        for bad in ["[x](file:///etc/passwd)", "[x](agentbar://settings)", "[x](/etc/hosts)"] {
            let s = ReleaseNotesView.inline(bad, size: 12, weight: .regular, color: .labelColor, style: p)
            #expect(s.attribute(.link, at: 0, effectiveRange: nil) == nil, "\(bad)")
        }
    }

    @Test func theReleaseBodyReadsAsOneRelease() {
        let r = UpdateChecker.bodyRelease("<p>pic</p>\n\n### Added\n\n- A thing.", version: "2.0.0")
        #expect(r.map(\.version) == ["2.0.0"])
        #expect(r[0].blocks == [.heading("Added"), .bullet("A thing.", level: 0)])
        #expect(UpdateChecker.bodyRelease(nil, version: "2.0.0").isEmpty)
        #expect(UpdateChecker.bodyRelease("<p>only a picture</p>", version: "2.0.0").isEmpty)
    }

    @Test func theUpcomingNotesFollowTheUpdate() {
        let u = UpdateChecker(.init(
            download: { _, _ in }, stage: { u, _ in u }, verify: { _ in nil },
            autoInstallSupported: { false }, install: { _ in }, idleSeconds: { 0 },
            now: Date.init, main: { $0() },
            defaults: UserDefaults(suiteName: "agentbar-notes-\(UUID().uuidString)")!))
        #expect(u.upcoming == nil)
        u.found(latest: "999.0.0", zip: nil, manual: true, notes: "- Big.")
        #expect(u.upcoming?.version == "999.0.0")
        #expect(u.upcoming?.releases.first?.blocks == [.bullet("Big.", level: 0)])
    }

    @Test func thePageListsUnreadThenAFewBefore() {
        let r = ReleaseNotes.parse(Self.sample)
        let none = WhatsNewPage.shown(r, current: "1.39.0", unread: [], older: 1)
        #expect(none.unread.isEmpty)
        #expect(none.older.map(\.version) == ["1.39.0", "1.38.0"])
        let some = WhatsNewPage.shown(r, current: "1.38.0", unread: ["1.38.0"], older: 1)
        #expect(some.unread.map(\.version) == ["1.38.0"])
        #expect(some.older.map(\.version) == ["1.37.1"])
        #expect(WhatsNewPage.installedHeader(unread: 2) == "New since you last looked — 2 releases")
        #expect(WhatsNewPage.buttonTitle(.ready("2.0.0")) == "Relaunch now")
        #expect(!WhatsNewPage.buttonEnabled(.downloading("2.0.0")))
        #expect(WhatsNewPage.statusLine(.idle, autoUpdate: false).contains("Settings ▸ General"))
    }

    @Test func datesReadAsDates() {
        #expect(ReleaseNotes.displayDate("2026-10-05") == "5 October 2026")
        #expect(ReleaseNotes.displayDate("soon") == "soon")
    }

    // MARK: - The real changelog

    /// The app reads its notes from CHANGELOG.md, so a release whose section the
    /// parser cannot find is a release with no notes in the field.
    @Test func theRealChangelogHasTheBuildsVersionOnTop() throws {
        let text = try String(contentsOf: Self.repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let build = try String(contentsOf: Self.repo.appendingPathComponent("Scripts/build.sh"), encoding: .utf8)
        let version = try #require(build.split(separator: "\n")
            .first { $0.hasPrefix("VERSION=\"") }
            .map { $0.dropFirst(9).prefix { $0 != "\"" } })
        let releases = ReleaseNotes.parse(text)
        #expect(releases.first?.version == String(version))
        #expect(releases.first?.date != nil, "date the top section before releasing")
        #expect(releases.count > 40)
        for r in releases.prefix(10) {
            #expect(!r.blocks.isEmpty, "\(r.version) has no notes")
        }
        // Newest first, every version once.
        for (a, b) in zip(releases, releases.dropFirst()) {
            #expect(UpdateChecker.isNewer(a.version, than: b.version), "\(a.version) before \(b.version)")
        }
    }

    /// `Scripts/dev/release-notes.sh` writes what GitHub shows; it must be the same
    /// section the app parses, so the two can never say different things.
    @Test func theReleaseScriptCutsTheSameSection() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.repo.appendingPathComponent("Scripts/dev/release-notes.sh").path, "1.37.0"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let body = String(decoding: data, as: UTF8.self)
        #expect(!body.contains("## 1.37.0"))
        #expect(!body.contains("## 1.36.1"))
        let text = try String(contentsOf: Self.repo.appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let fromApp = ReleaseNotes.parse(text).first { $0.version == "1.37.0" }
        #expect(UpdateChecker.bodyRelease(body, version: "1.37.0").first?.blocks == fromApp?.blocks)
    }
}

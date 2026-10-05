import AppKit
import Testing
@testable import AgentBar

/// The menu bar's dropdown and the island's ⋯ menu offer the same app section.
/// 1.34.0 shipped an island update row that could check but never show what it
/// found, because each surface built its own copy; these tests are what makes the
/// next divergence fail CI instead of shipping.
@MainActor @Suite struct AppMenuModelTests {
    nonisolated static let statuses: [UpdateChecker.Status] = [
        .idle, .checking, .upToDate, .available("9.9.9"), .downloading("9.9.9"),
        .ready("9.9.9"), .failed("Couldn't reach GitHub"),
    ]

    static func inputs(_ status: UpdateChecker.Status, systemColor: Bool = false,
                       sounds: Bool = true, failures: Int = 0) -> AppMenuModel.Inputs {
        AppMenuModel.Inputs(update: status, appVersion: "1.34.0", systemColor: systemColor,
                            soundsOn: sounds, diagnosticsFailures: failures,
                            macOSVersion: "26.0.1")
    }

    /// Everything a person can see or click on a row, minus the wiring (target and
    /// selector), which is the one thing each surface is supposed to own.
    struct Snapshot: Equatable, CustomStringConvertible {
        var title: String
        var separator: Bool
        var enabled: Bool
        var clickable: Bool
        var command: AppMenuAction?
        var state: NSControl.StateValue
        var key: String
        var toolTip: String?
        var hasImage: Bool
        var children: [Snapshot]

        var description: String { "\(title)\(enabled ? "" : " (disabled)")" }
    }

    static func snapshot(_ items: [NSMenuItem]) -> [Snapshot] {
        items.map { item in
            Snapshot(title: item.title, separator: item.isSeparatorItem, enabled: item.isEnabled,
                     clickable: item.action != nil, command: AppMenuRenderer.action(of: item),
                     state: item.state, key: item.keyEquivalent, toolTip: item.toolTip,
                     hasImage: item.image != nil,
                     children: snapshot(item.submenu?.items ?? []))
        }
    }

    static func menuBar(_ i: AppMenuModel.Inputs) -> [NSMenuItem] {
        MenuBuilder.appSection(i, controller: nil)
    }

    static func island(_ i: AppMenuModel.Inputs) -> [NSMenuItem] {
        IslandController.appSection(i, target: nil)
    }

    @Test(arguments: statuses)
    func bothSurfacesRenderTheSameSection(_ status: UpdateChecker.Status) {
        for (color, sounds, failures) in [(false, true, 0), (true, false, 2)] {
            let i = Self.inputs(status, systemColor: color, sounds: sounds, failures: failures)
            #expect(Self.snapshot(Self.menuBar(i)) == Self.snapshot(Self.island(i)))
        }
    }

    @Test func theSectionHasTheRowsBothSurfacesPromise() {
        let titles = Self.snapshot(Self.island(Self.inputs(.idle))).map(\.title)
        #expect(titles == ["Color", "Sounds", "Appearance…", "Diagnostics…", "Settings…", "",
                           "Check for Updates…", "Send Feedback…", "Quit AgentBar"])
    }

    @Test(arguments: statuses)
    func everyUpdateStatusSaysSomethingAndIsClickableOnlyWhenThereIsSomethingToDo(
        _ status: UpdateChecker.Status
    ) {
        let rows = Self.snapshot(Self.menuBar(Self.inputs(status)))
        let update = rows[6]
        let expected: (String, AppMenuAction?) = {
            switch status {
            case .idle:           return ("Check for Updates…", .checkForUpdates)
            case .checking:       return ("Checking for updates…", nil)
            case .upToDate:       return ("Up to date", nil)
            case .available:      return ("Update to 9.9.9 — Install & Relaunch", .installUpdate)
            case .downloading:    return ("Downloading 9.9.9…", nil)
            case .ready:          return ("Update to 9.9.9 ready — Relaunch now", .installUpdate)
            case .failed:         return ("Couldn't reach GitHub — Retry", .checkForUpdates)
            }
        }()
        #expect(update.title == expected.0)
        #expect(update.command == expected.1)
        #expect(update.enabled == (expected.1 != nil))
        #expect(update.clickable == (expected.1 != nil))
        // The rows around it do not move with the update state; an update on offer
        // adds its notes right under it, and nothing else.
        let offered: Bool = {
            switch status {
            case .available, .downloading, .ready: return true
            default: return false
            }
        }()
        #expect(rows.count == (offered ? 10 : 9))
        if offered {
            #expect(rows[7].title == "What's in 9.9.9…")
            #expect(rows[7].command == .openWhatsNew)
        }
        #expect(rows.last?.title == "Quit AgentBar")
    }

    /// Release notes nobody has read get one row, under the update row, on both
    /// surfaces — and an update on offer takes its place rather than adding a second.
    @Test func unreadNotesGetOneRow() {
        var i = Self.inputs(.idle)
        i.whatsNew = "1.39.0"
        let rows = Self.snapshot(Self.menuBar(i))
        #expect(rows == Self.snapshot(Self.island(i)))
        #expect(rows[7].title == "What's New in 1.39.0…")
        #expect(rows[7].command == .openWhatsNew)
        #expect(rows.count == 10)
        i.update = .ready("1.40.0")
        let both = Self.snapshot(Self.menuBar(i))
        #expect(both.filter { $0.command == .openWhatsNew }.map(\.title) == ["What's in 1.40.0…"])
    }

    @Test func checkmarksFollowTheInputs() {
        let rows = Self.snapshot(Self.island(Self.inputs(.idle, systemColor: true, sounds: false)))
        #expect(rows[0].children.map(\.state) == [.off, .on])
        #expect(rows[0].children.map(\.command) == [.chooseColor(system: false),
                                                    .chooseColor(system: true)])
        #expect(rows[1].state == .off)
        let on = Self.snapshot(Self.island(Self.inputs(.idle, sounds: true)))
        #expect(on[1].state == .on)
    }

    @Test func diagnosticsCarriesTheVerdict() {
        #expect(Self.snapshot(Self.menuBar(Self.inputs(.idle, failures: 1)))[3].title
                == "Diagnostics — 1 problem…")
        #expect(Self.snapshot(Self.menuBar(Self.inputs(.idle, failures: 3)))[3].title
                == "Diagnostics — 3 problems…")
    }

    @Test func eachSurfaceWiresItsOwnSelector() {
        let bar = Self.menuBar(Self.inputs(.idle)).first { $0.title == "Send Feedback…" }
        let island = Self.island(Self.inputs(.idle)).first { $0.title == "Send Feedback…" }
        #expect(bar?.action == #selector(StatusItemController.appMenuClicked(_:)))
        #expect(island?.action == #selector(IslandController.appMenuClicked(_:)))
    }

    /// An open menu is refreshed in place when an update check answers: same rows,
    /// new state, and nothing left over from the old one.
    @Test func refreshRewritesTheUpdateRowInPlace() {
        let menu = NSMenu()
        for item in Self.island(Self.inputs(.checking)) { menu.addItem(item) }
        let before = menu.items.count
        AppMenuRenderer.refresh(menu, with: AppMenuModel.appSection(Self.inputs(.available("9.9.9"))),
                                target: nil, action: IslandController.appMenuAction)
        #expect(menu.items.count == before)
        let row = Self.snapshot(menu.items)[6]
        #expect(row.title == "Update to 9.9.9 — Install & Relaunch")
        #expect(row.command == .installUpdate)
        AppMenuRenderer.refresh(menu, with: AppMenuModel.appSection(Self.inputs(.downloading("9.9.9"))),
                                target: nil, action: IslandController.appMenuAction)
        let after = Self.snapshot(menu.items)[6]
        #expect(after.command == nil)
        #expect(!after.clickable)
        #expect(after.title == "Downloading 9.9.9…")
        #expect(after.toolTip != "Installs by itself once nothing is waiting on you "
                + "and you have been away for five minutes.")
    }

    @Test func feedbackOpensAGeneralDiscussionWithOnlyVersions() throws {
        let url = AppMenuModel.feedbackURL(appVersion: "1.34.0", macOSVersion: "26.0.1")
        let parts = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(parts.host == "github.com")
        #expect(parts.path == "/michalstrnadel/AgentBar/discussions/new")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(query["category"] == "general")
        #expect(Set(query.keys) == ["category", "body"])
        let body = try #require(query["body"])
        #expect(body.contains("AgentBar 1.34.0"))
        #expect(body.contains("macOS 26.0.1"))
        // Nothing that identifies the person or their machine.
        #expect(!body.contains(NSUserName()))
        #expect(!body.contains(NSHomeDirectory()))
        #expect(!body.contains("/"))
    }
}

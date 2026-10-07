import Foundation
import Testing
@testable import AgentBar

/// The welcome window on launch: a first run always shows it, and after that only
/// a launch the person made — never one a hook or an update made in the background.
@Suite struct WelcomeLaunchTests {
    private func defaults(_ values: [String: Any]) -> UserDefaults {
        let name = "welcome-launch-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test func aFirstRunShowsItHoweverItStarted() {
        let fresh = defaults([:])
        #expect(WelcomeWindow.showsOnLaunch(arguments: ["AgentBar"], defaults: fresh))
        #expect(WelcomeWindow.showsOnLaunch(arguments: ["AgentBar", "--background"], defaults: fresh))
    }

    @Test func askedForOnEveryLaunchItShowsOnlyWhenThePersonOpenedIt() {
        let on = defaults(["welcomeShownOnce": true, "showWelcomeOnLaunch": true])
        #expect(WelcomeWindow.showsOnLaunch(arguments: ["AgentBar"], defaults: on))
        // A hook starting the app for a session — /compact included — or an update.
        #expect(!WelcomeWindow.showsOnLaunch(arguments: ["AgentBar", "--background"], defaults: on))
    }

    @Test func seenOnceAndNotAskedForItStaysAway() {
        let off = defaults(["welcomeShownOnce": true])
        #expect(!WelcomeWindow.showsOnLaunch(arguments: ["AgentBar"], defaults: off))
        let turnedOff = defaults(["welcomeShownOnce": true, "showWelcomeOnLaunch": false])
        #expect(!WelcomeWindow.showsOnLaunch(arguments: ["AgentBar"], defaults: turnedOff))
    }
}

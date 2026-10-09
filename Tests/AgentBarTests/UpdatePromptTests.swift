import Testing
@testable import AgentBar

/// What the Check for Updates… window says in each updater state.
@Suite struct UpdatePromptTests {
    private func content(_ s: UpdateChecker.Status) -> UpdatePrompt.Content? {
        UpdatePrompt.content(s, current: "1.51.1")
    }

    @Test func idleKeepsWhatWasShown() {
        #expect(content(.idle) == nil)
    }

    @Test func checkingShowsItIsWorking() throws {
        let c = try #require(content(.checking))
        #expect(c.busy)
        #expect(c.buttons.map(\.action) == [.close])
    }

    @Test func upToDateNamesTheVersion() throws {
        let c = try #require(content(.upToDate))
        #expect(!c.busy)
        #expect(c.message.contains("1.51.1"))
        #expect(c.buttons.last?.action == .close)
    }

    @Test func availableDefaultsToInstall() throws {
        let c = try #require(content(.available("1.52.0")))
        #expect(c.title.contains("1.52.0"))
        #expect(c.buttons.last?.action == .install)
    }

    @Test func readyOffersRelaunch() throws {
        let c = try #require(content(.ready("1.52.0")))
        #expect(c.buttons.last?.action == .install)
        #expect(try #require(content(.downloading("1.52.0"))).busy)
    }

    @Test func failureOffersRetry() throws {
        let c = try #require(content(.failed("GitHub is limiting requests")))
        #expect(c.title == "GitHub is limiting requests")
        #expect(c.buttons.last?.action == .retry)
    }
}

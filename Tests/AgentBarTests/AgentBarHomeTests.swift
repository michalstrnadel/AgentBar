import Foundation
import Testing
@testable import AgentBar

/// `AGENTBAR_HOME` moves every store at once, so what counts as a usable value is
/// the whole feature — and a value that does not count must mean `~/.agentbar`,
/// never somewhere nobody chose.
@Suite struct AgentBarHomeTests {
    @Test func unsetOrEmptyMeansTheDefault() {
        #expect(AgentBarHome.override(in: [:]) == nil)
        #expect(AgentBarHome.override(in: ["AGENTBAR_HOME": ""]) == nil)
    }

    @Test func aRelativePathIsNotAPlaceAnybodyChose() {
        #expect(AgentBarHome.override(in: ["AGENTBAR_HOME": "sandbox"]) == nil)
        #expect(AgentBarHome.override(in: ["AGENTBAR_HOME": "~/sandbox"]) == nil)
    }

    @Test func anAbsolutePathIsTakenPlainly() {
        #expect(AgentBarHome.override(in: ["AGENTBAR_HOME": "/tmp/ab/"])?.path == "/tmp/ab")
        #expect(AgentBarHome.override(in: ["AGENTBAR_HOME": "/tmp/x/../ab"])?.path == "/tmp/ab")
    }

    /// A test that hands a function its own home means that home, whatever the
    /// process running the tests was started with.
    @Test func aTemporaryHomeIsNeverRedirected() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("h-\(UUID())")
        #expect(AgentBarHome.root(home: tmp) == tmp.appendingPathComponent(".agentbar", isDirectory: true))
        #expect(WiringPrefs.url(home: tmp).path == tmp.path + "/.agentbar/wire-disabled")
    }

    /// Every store hangs off the one root, so moving it moves all of them.
    @Test func everyStoreLivesUnderTheRoot() {
        let root = AgentBarHome.root().path
        for url in [SessionStore.stateDir, RequestStore.requestsDir, RequestStore.answersDir,
                    RulesStore.fileURL, DecisionLedger.fileURL, HistoryStore.fileURL,
                    ConfigBackup.defaultLog, SoundPack.directory, WiringPrefs.url()] {
            #expect(url.path.hasPrefix(root + "/"), "\(url.path)")
        }
    }
}

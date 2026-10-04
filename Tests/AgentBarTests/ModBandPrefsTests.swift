import Foundation
import Testing
@testable import AgentBar

/// The band's switch is a file the mod reads from inside Claude Code; the two must
/// agree on what "on" means, and the switch must not eat keys it does not own.
@Suite struct ModBandPrefsTests {
    private func root() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-band-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func offUnlessTheFileSaysSo() throws {
        let r = root()
        defer { try? FileManager.default.removeItem(at: r) }
        #expect(!ModBandPrefs.isOn(root: r))
        try FileManager.default.createDirectory(at: r.appendingPathComponent("mods"),
                                                withIntermediateDirectories: true)
        for text in ["{ not json", #"{"band": "yes"}"#, #"{"band": 1}"#] {
            try Data(text.utf8).write(to: ModBandPrefs.url(root: r))
            #expect(!ModBandPrefs.isOn(root: r), "\(text)")
        }
    }

    @Test func theSwitchKeepsOtherKeys() throws {
        let r = root()
        defer { try? FileManager.default.removeItem(at: r) }
        try FileManager.default.createDirectory(at: r.appendingPathComponent("mods"),
                                                withIntermediateDirectories: true)
        try Data(#"{"future": 3}"#.utf8).write(to: ModBandPrefs.url(root: r))
        try ModBandPrefs.set(true, root: r)
        #expect(ModBandPrefs.isOn(root: r))
        let o = try JSONSerialization.jsonObject(with: Data(contentsOf: ModBandPrefs.url(root: r))) as? [String: Any]
        #expect(o?["future"] as? Int == 3)
        try ModBandPrefs.set(false, root: r)
        #expect(!ModBandPrefs.isOn(root: r))
    }
}

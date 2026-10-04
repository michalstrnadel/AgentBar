import Foundation

/// The one setting the Claude Code mod reads: whether it draws the line above Claude
/// Code's prompt when another session waits on you. It lives in a file, not in
/// AgentBar's preferences, because the mod runs inside Claude Code and can read a
/// file but not this app's defaults — `<root>/mods/config.json`, `{"band": true}`.
/// Off unless that file says so, exactly as the mod reads it. Other keys in the file
/// are kept: a later mod may have its own, and this switch owns only `band`.
enum ModBandPrefs {
    static func url(root: URL = AgentBarHome.root()) -> URL {
        root.appendingPathComponent("mods/config.json")
    }

    static func isOn(root: URL = AgentBarHome.root()) -> Bool {
        guard let data = try? Data(contentsOf: url(root: root)),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        // Exactly a JSON `true`, as the mod's `cfg.band === true` reads it: Foundation
        // would happily bridge a `1` to `true`, and the two sides would disagree.
        guard let n = o["band"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
        return n.boolValue
    }

    /// Atomic, like every other file AgentBar writes for a reader it does not own.
    /// A file that does not parse is replaced rather than left to keep the band in
    /// a state nobody can see from here.
    static func set(_ on: Bool, root: URL = AgentBarHome.root()) throws {
        let target = url(root: root)
        var o: [String: Any] = [:]
        if let data = try? Data(contentsOf: target),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            o = existing
        }
        o["band"] = on
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: target, options: .atomic)
    }
}

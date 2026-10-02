import Foundation

/// Where AgentBar's own state lives: `~/.agentbar`, unless `AGENTBAR_HOME` names
/// another directory. Every store asks here, so one variable moves all of it —
/// sessions, requests, answers, rules, the ledger, history, the change record.
///
/// The variable exists for one job: running a second copy next to the installed one
/// (a dev build, a test of the island with made-up sessions) without either copy
/// seeing the other's files. Before it, the app resolved its home from the account,
/// so `HOME=` isolated nothing and every live test wrote into the person's real
/// ledger. The hooks and the CLI read the same variable (`docs/protocol.md`).
///
/// It replaces `~/.agentbar` itself, not the home directory: the agents' own config
/// files are still where the agents keep them. That is why a copy running under it
/// is a **sandbox** and wires nothing (`HookInstaller`): pointing a real agent's
/// config at a throwaway directory is exactly the leak the variable is here to stop.
enum AgentBarHome {
    static let variable = "AGENTBAR_HOME"

    /// The override in `environment`, if it is usable. Only an absolute path counts:
    /// a relative one would resolve against whatever directory the app happened to
    /// be launched from, which is not a place anybody chose.
    static func override(in environment: [String: String]) -> URL? {
        guard let raw = environment[variable], !raw.isEmpty, raw.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
    }

    /// Read once: the environment of a running process does not change, and a store
    /// that moved mid-session would leave its watcher on the old folder.
    static let overridden: URL? = override(in: ProcessInfo.processInfo.environment)

    /// True when this copy runs on a state directory of its own.
    static var isSandbox: Bool { overridden != nil }

    private static let realHome = FileManager.default.homeDirectoryForCurrentUser

    /// The state root for `home`. The override applies to the real home only: a
    /// test that hands a function a temporary home means that home, whatever the
    /// environment of the process running the test says.
    static func root(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let overridden, home.standardizedFileURL == realHome.standardizedFileURL {
            return overridden
        }
        return home.appendingPathComponent(".agentbar", isDirectory: true)
    }

    /// `root()/path`.
    static func url(_ path: String, isDirectory: Bool = false,
                    home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        root(home: home).appendingPathComponent(path, isDirectory: isDirectory)
    }
}

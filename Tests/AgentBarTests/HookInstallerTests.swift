import Foundation
import Testing
@testable import AgentBar

/// The two silent failures that motivated `agentbar doctor`, both of which came
/// down to a node path written into a config that outlives the next node upgrade.
/// Neither had a test, and neither announced itself when it broke — the rows just
/// stopped appearing.
@Suite struct HookInstallerTests {
    private static let script = "/Users/x/.agentbar/hooks/codex/notify.js"

    // MARK: - Codex: a moved interpreter has to be repaired, not preserved

    /// The regression. A config that is already ours but names a node that no longer
    /// exists must be rewritten; the old code returned at the marker and left it.
    // MARK: - The hooks block, which is the real Codex integration

    /// Codex speaks Claude's hook dialect, so the whole integration is one block of
    /// TOML pointing at the shared scripts. These assert the two promises the notify
    /// line already keeps: everything outside survives byte for byte, and a second
    /// copy is never appended.
    @Test func codexHooksBlockCarriesEveryEventAndItsOwnTimeout() {
        let plan = HookInstaller.codexHooksPlan(config: "model = \"o3\"\n",
                                                node: "/opt/homebrew/bin/node", dir: "/h")
        guard case .write(let next, let replaced) = plan else {
            Issue.record("a fresh config must produce a write, got \(plan)"); return
        }
        #expect(!replaced)
        #expect(next.hasPrefix("model = \"o3\"\n"))
        for e in HookInstaller.codexEvents {
            #expect(next.contains("[[hooks.\(e.event)]]"))
        }
        // The blocking one outlasts permission.js's own 600s wait, so the hook gives
        // up first and falls through to Codex's prompt rather than being killed.
        #expect(next.contains("command = \"\\\"/opt/homebrew/bin/node\\\" \\\"/h/codex/hook.js\\\" permission.js\"\ntimeout = 630"))
        // Codex clamps SessionEnd to 3s; asking for more earns a warning every session.
        #expect(next.contains("\"/h/codex/hook.js\\\" lifecycle.js end\"\ntimeout = 3"))
        #expect(next.contains("statusMessage = \"Waiting for you in AgentBar\""))
    }

    @Test func codexHooksBlockIsIdempotent() {
        guard case .write(let once, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(HookInstaller.codexHooksPlan(config: once, node: "/n", dir: "/h") == .unchanged)
    }

    /// A node that moved rewrites the block where it stands, rather than appending a
    /// second one — the same repair the notify line gets, for the same reason.
    @Test func codexHooksBlockIsReplacedInPlaceNotAppended() {
        guard case .write(let old, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/old/node", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        let trailing = old + "\n[profiles.mine]\nmodel = \"o4\"\n"
        guard case .write(let next, let replaced) = HookInstaller.codexHooksPlan(
            config: trailing, node: "/new/node", dir: "/h") else {
            Issue.record("expected a rewrite"); return
        }
        #expect(replaced)
        #expect(!next.contains("/old/node"))
        #expect(next.components(separatedBy: HookInstaller.codexBegin).count - 1 == 1)
        // Everything the user put after our block is still there, untouched.
        #expect(next.hasSuffix("[profiles.mine]\nmodel = \"o4\"\n"))
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The trap this release had to fix first: the marker check used to match the path
    /// anywhere in the file, so once the hooks block existed — which carries the same
    /// path — a config with no `notify` key was read as "already wired" and notify was
    /// never installed at all.
    @Test func theHooksBlockDoesNotHideAMissingNotify() {
        guard case .write(let withHooks, _) = HookInstaller.codexHooksPlan(
            config: "model = \"o3\"\n", node: "/n", dir: "/h") else {
            Issue.record("expected a write"); return
        }
        #expect(withHooks.contains("/.agentbar/hooks/codex/") == false)   // dir is /h here
        let real = withHooks.replacingOccurrences(of: "/h/codex/", with: "/u/.agentbar/hooks/codex/")
        let plan = HookInstaller.codexPlan(config: real, node: "/n",
                                           script: "/u/.agentbar/hooks/codex/notify.js",
                                           isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("notify must still be installed beside the hooks block, got \(plan)")
            return
        }
        #expect(!repaired)
        #expect(next.contains("notify = [\"/n\", \"/u/.agentbar/hooks/codex/notify.js\"]"))
    }

    @Test func codexRepairsAnInterpreterThatHasMoved() {
        let stale = "model = \"o3\"\nnotify = [\"/Users/x/.nvm/versions/node/v20.11.0/bin/node\", \"\(Self.script)\"]\n"
        let plan = HookInstaller.codexPlan(config: stale, node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in false })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a dead interpreter must produce a write, got \(plan)"); return
        }
        #expect(repaired)
        #expect(next.contains("notify = [\"/opt/homebrew/bin/node\""))
        #expect(!next.contains("v20.11.0"))
        // Codex accepts exactly one notify key, and the rest of the file is the
        // user's — repairing must not append or disturb anything.
        #expect(next.components(separatedBy: "notify = [").count - 1 == 1)
        #expect(next.hasPrefix("model = \"o3\"\n"))
    }

    /// The other half: a working interpreter must not be rewritten on every launch,
    /// or `install-hooks` stops being idempotent and churns the user's config.
    @Test func codexLeavesAWorkingInterpreterAlone() {
        let fine = "notify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n"
        #expect(HookInstaller.codexPlan(config: fine, node: "/usr/local/bin/node",
                                        script: Self.script, isExecutable: { _ in true }) == .unchanged)
    }

    @Test func codexAppendsToAConfigThatHasNoNotifyYet() {
        let plan = HookInstaller.codexPlan(config: "model = \"o3\"", node: "/opt/homebrew/bin/node",
                                           script: Self.script, isExecutable: { _ in true })
        guard case .write(let next, let repaired) = plan else {
            Issue.record("a fresh config must be written, got \(plan)"); return
        }
        #expect(!repaired)
        // The file had no trailing newline; appending to it must not join two keys.
        #expect(next == "model = \"o3\"\nnotify = [\"/opt/homebrew/bin/node\", \"\(Self.script)\"]\n")
    }

    /// Someone else's notify hook stays theirs even when ours is dead — a status
    /// bridge must never take a key the user pointed somewhere on purpose.
    @Test func codexRefusesToTakeOverAForeignNotify() {
        #expect(HookInstaller.codexPlan(config: "notify = [\"/usr/bin/say\", \"done\"]\n",
                                        node: "/opt/homebrew/bin/node", script: Self.script,
                                        isExecutable: { _ in false }) == .foreignNotify)
    }

    /// …on any line, not only the first. Without `(?m)` the pattern saw a notify only
    /// at the very start of the file, and a second key appended below the user's made
    /// a config.toml that TOML, and so Codex, refuses to load.
    @Test func aForeignNotifyOnALaterLineIsStillForeign() {
        #expect(HookInstaller.codexPlan(config: "model = \"o3\"\nnotify = [\"/usr/bin/say\", \"done\"]\n",
                                        node: "/opt/homebrew/bin/node", script: Self.script,
                                        isExecutable: { _ in true }) == .foreignNotify)
    }

    /// A bare key written after a `[table]` header belongs to that table, so notify
    /// appended to a file with an MCP server in it was that server's notify.
    @Test func notifyGoesAboveTheFirstTable() {
        let config = "model = \"o3\"\n\n[mcp_servers.github]\ncommand = \"gh\"\n"
        guard case .write(let next, _) = HookInstaller.codexPlan(
            config: config, node: "/n", script: Self.script, isExecutable: { _ in true }) else {
            Issue.record("expected a write"); return
        }
        let notify = next.range(of: "notify = [")!.lowerBound
        #expect(notify < next.range(of: "[mcp_servers.github]")!.lowerBound)
        #expect(next.hasSuffix("[mcp_servers.github]\ncommand = \"gh\"\n"))
    }

    /// …and one an older release already put below a table is moved up, once.
    @Test func aNotifyStrandedInATableIsMovedToTheTop() {
        let ours = "notify = [\"/n\", \"\(Self.script)\"]"
        let stranded = "model = \"o3\"\n[mcp_servers.github]\ncommand = \"gh\"\n\(ours)\n"
        guard case .write(let next, let repaired) = HookInstaller.codexPlan(
            config: stranded, node: "/n", script: Self.script, isExecutable: { _ in true }) else {
            Issue.record("expected a move"); return
        }
        #expect(repaired)
        #expect(next == "model = \"o3\"\n\(ours)\n[mcp_servers.github]\ncommand = \"gh\"\n")
        #expect(HookInstaller.codexPlan(config: next, node: "/n", script: Self.script,
                                        isExecutable: { _ in true }) == .unchanged)
    }

    /// Our marker in a shape the line pattern can't read (a comment, hand-edited
    /// formatting) must fall through to "leave it", never to "append a second key".
    @Test func codexDoesNotAppendWhenTheMarkerIsThereInAnUnreadableShape() {
        let odd = "# wired by agentbar: /Users/x/.agentbar/hooks/codex/notify.js\n"
        #expect(HookInstaller.codexPlan(config: odd, node: "/opt/homebrew/bin/node",
                                        script: Self.script, isExecutable: { _ in false }) == .unchanged)
    }

    // MARK: - firstQuoted

    @Test(arguments: [
        ("notify = [\"/usr/bin/node\", \"/x/notify.js\"]", "/usr/bin/node"),
        ("notify = [\"\", \"/x\"]", ""),
    ])
    func firstQuotedReadsTheInterpreter(_ line: String, _ want: String) {
        #expect(HookInstaller.firstQuoted(line) == want)
    }

    @Test(arguments: ["notify = []", "", "no quotes here", "\"unterminated"])
    func firstQuotedIsNilWithoutAClosedPair(_ line: String) {
        #expect(HookInstaller.firstQuoted(line) == nil)
    }

    // MARK: - Node paths

    /// A path that does not resolve comes back untouched. An nvm-only machine has no
    /// stable alias at all, and inventing one would write a path that isn't there —
    /// `agentbar doctor` reports the situation instead.
    @Test func anUnresolvablePathIsReturnedUnchanged() {
        #expect(HookInstaller.stableNodeAlias(for: "/nope/not/a/node") == "/nope/not/a/node")
    }

    /// The actual fix: a version-pinned path that names the same binary as a stable
    /// alias must come back as the alias. Built from whatever node this machine has.
    @Test func aVersionPinnedPathIsSwappedForItsStableAlias() throws {
        let fm = FileManager.default
        guard let stable = HookInstaller.stableNodePaths.first(where: { fm.isExecutableFile(atPath: $0) }),
              let real = HookInstaller.realPath(stable)
        else { return }   // no node on this machine: nothing to assert against

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-node-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        // Stand in for ~/.nvm/versions/node/v20.11.0/bin/node: a different path that
        // resolves to the very same interpreter.
        let pinned = dir.appendingPathComponent("node")
        try fm.createSymbolicLink(at: pinned, withDestinationURL: URL(fileURLWithPath: real))

        let resolved = HookInstaller.stableNodeAlias(for: pinned.path)
        #expect(resolved != pinned.path, "a pinned path with a stable alias must not survive")
        #expect(HookInstaller.realPath(resolved) == real)
        #expect(HookInstaller.stableNodePaths.contains(resolved))
    }
}

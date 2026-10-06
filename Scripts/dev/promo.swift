// Promo harness: the product video, GIFs and stills for a release — drawn from the
// REAL views (island rows, approval card, the break game, settings cards, release
// notes), offscreen, with made-up sessions. No window ever reaches the screen, and
// none of the machine's own sessions, projects or plugins appear in a frame.
//
// Build & run (from repo root; ffmpeg on PATH):
//   D=$(mktemp -d)
//   swiftc -O -parse-as-library -target arm64-apple-macos12.0 \
//     $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") \
//     Scripts/dev/promo.swift -o "$D/promo"
//   AGENTBAR_HOME="$D/home" "$D/promo" promo/<date>     # from the repo root
import AppKit

@main
enum Promo {
    static var outDir = URL(fileURLWithPath: ".")
    static let now = Date()

    static func main() {
        outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "promo")
        for sub in ["", "stills", "gifs", "video"] {
            try? FileManager.default.createDirectory(at: outDir.appendingPathComponent(sub),
                                                     withIntermediateDirectories: true)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        seedLedger()

        let a = Art()
        // `--assets`: the bare pictures and the game as clips, for the video studio.
        if CommandLine.arguments.contains("--assets") {
            Assets.write(a)
            print("done → \(outDir.path)")
            return
        }
        // `--hunt`: Bug Hunt, played by its autopilot, as a GIF and an MP4.
        if CommandLine.arguments.contains("--hunt") {
            HuntClip.write()
            print("done → \(outDir.path)")
            return
        }
        // `--game`: the Take a break film alone.
        if CommandLine.arguments.contains("--game") {
            let film = GameFilm.scenes(a)
            for (size, name) in [(NSSize(width: 1080, height: 1080), "square"),
                                 (NSSize(width: 1920, height: 1080), "wide"),
                                 (NSSize(width: 1080, height: 1920), "story")] {
                Video.render(film, size: size, name: "take-a-break-\(name)")
            }
            Video.stills(film, size: NSSize(width: 1080, height: 1080), suffix: "game-square")
            print("done → \(outDir.path)")
            return
        }
        let scenes = Storyboard.scenes(a)
        for (size, name) in [(NSSize(width: 1080, height: 1080), "square"),
                             (NSSize(width: 1920, height: 1080), "wide"),
                             (NSSize(width: 1080, height: 1920), "story")] {
            Video.render(scenes, size: size, name: "agentbar-today-\(name)")
        }
        Video.stills(scenes, size: NSSize(width: 1080, height: 1080), suffix: "square")
        Video.stills(scenes, size: NSSize(width: 1600, height: 900), suffix: "wide")
        Gifs.render(a)
        print("done → \(outDir.path)")
    }

    // MARK: - A believable record for the Claude Code card

    /// Rows the card counts, in a scratch AGENTBAR_HOME: Claude Code rules, auto
    /// mode, the permission mode, and a mod holding a command.
    static func seedLedger() {
        guard AgentBarHome.isSandbox else {
            fatalError("run with AGENTBAR_HOME set to a scratch folder: the card reads its ledger")
        }
        let url = DecisionLedger.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var lines: [String] = []
        var n = 0
        func row(_ by: String, _ decision: String, _ shape: String, _ display: String, rule: String = "") {
            n += 1
            let o: [String: Any] = [
                "v": 1, "agent": "claude", "via": "claude", "by": by, "claudeRule": rule,
                "decision": decision, "shape": shape, "display": display, "tool": "Bash",
                "cwd": "/work/api", "project": "api", "sessionId": "promo", "rule": "",
                "toolUseId": "toolu_promo_\(n)", "ts": Int(now.timeIntervalSince1970) - n * 140,
                "waited": 0, "would": "",
            ]
            lines.append(String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!)
        }
        for _ in 0..<14 { row("rule", "allow", "bash:git status", "Bash: git status", rule: "Bash(git status:*)") }
        for _ in 0..<8 { row("rule", "allow", "bash:npm test", "Bash: npm test", rule: "Bash(npm test:*)") }
        for _ in 0..<9 { row("auto", "allow", "bash:mkdir", "Bash: mkdir -p dist") }
        for _ in 0..<5 { row("mode", "allow", "bash:ls", "Bash: ls src") }
        for _ in 0..<2 { row("hook", "deny", "bash:rm", "Bash: rm -r build") }
        try! (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Pictures of the real views

final class Art {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("agentbar-promo-\(getpid())")
    let rowW: CGFloat = IslandController.expandedWidth - IslandContentView.hPad * 2
    let ts = Int(Date().timeIntervalSince1970)

    lazy var icon: NSImage = NSImage(contentsOfFile: "Resources/AppIcon.icns")
        ?? NSImage(size: NSSize(width: 256, height: 256))

    init() { try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true) }

    // MARK: Pieces

    func session(_ name: String, _ o: [String: Any]) -> Session {
        var obj = o
        obj["sessionId"] = name
        obj["cwd"] = "/tmp"
        obj["pid"] = 1
        obj["started"] = true
        obj["ts"] = obj["ts"] ?? ts
        obj["term_program"] = "WarpTerminal"
        let url = tmp.appendingPathComponent("\(name).json")
        try! JSONSerialization.data(withJSONObject: obj).write(to: url)
        return Session(fileURL: url)!
    }

    func request(_ name: String, _ o: [String: Any]) -> ApprovalRequest {
        let url = tmp.appendingPathComponent("\(name).json")
        try! JSONSerialization.data(withJSONObject: o).write(to: url)
        return ApprovalRequest(fileURL: url)!
    }

    func mark(_ agent: String) -> NSImage? { IconRenderer.shared.sprite(for: Agent.byID(agent)).restingColor }

    func sized(_ v: NSView, _ w: CGFloat) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }

    func row(_ s: Session, hero: Bool = false) -> NSView {
        sized(IslandRowView(session: s, mark: mark(s.agentID), style: hero ? .hero : .compact,
                            onClick: { _ in }), rowW)
    }

    /// The island's footer as it is drawn: quota meters, the joystick, ⋯.
    func footer(joystickLit: Bool = false) -> NSView {
        let claude = UsageCenter.Reading(provider: "Claude", text: "64% left",
                                         windows: [UsageWindow(name: "5h", usedPercent: 36,
                                                               resetsAt: Date().addingTimeInterval(7_200)),
                                                   UsageWindow(name: "weekly", usedPercent: 41,
                                                               resetsAt: Date().addingTimeInterval(400_000))])
        let codex = UsageCenter.Reading(provider: "Codex", text: "88% left",
                                        windows: [UsageWindow(name: "5h", usedPercent: 12,
                                                              resetsAt: Date().addingTimeInterval(9_000))])
        var views: [NSView] = []
        if let meters = UsageMeterView(readings: [claude, codex], style: .islandFooter,
                                       tooltipReadings: [claude, codex]) {
            meters.translatesAutoresizingMaskIntoConstraints = false
            meters.heightAnchor.constraint(equalToConstant: meters.frame.height).isActive = true
            meters.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            views.append(meters)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        views.append(spacer)
        let joy = NSImageView(image: NSImage(systemSymbolName: "gamecontroller", accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))!)
        joy.contentTintColor = joystickLit ? .controlAccentColor : NSColor.white.withAlphaComponent(0.55)
        views.append(joy)
        let dots = NSTextField(labelWithString: "⋯")
        dots.font = .systemFont(ofSize: 15, weight: .semibold)
        dots.textColor = NSColor.white.withAlphaComponent(0.55)
        views.append(dots)
        let f = NSStackView(views: views)
        f.orientation = .horizontal
        f.spacing = 10
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: rowW).isActive = true
        return f
    }

    /// An open island hanging from a notch, holding `rows`.
    func island(_ rows: [NSView], footer: NSView?) -> NSImage {
        let ear = IslandShape.earWidth
        let width = IslandShape.panelWidth(body: IslandController.expandedWidth, ear: ear)
        let content = IslandContentView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        content.appearance = NSAppearance(named: .darkAqua)
        content.flushTop = true
        content.earWidth = ear
        content.collapsedHeight = 30
        content.topInset = 10
        content.setFooter(footer)
        content.setRows(rows)
        return snap(content, NSSize(width: width, height: content.contentHeight))
    }

    func snap(_ view: NSView, _ explicit: NSSize? = nil, appearance: NSAppearance.Name = .darkAqua) -> NSImage {
        view.appearance = NSAppearance(named: appearance)
        if explicit == nil { view.layoutSubtreeIfNeeded() }
        let size = explicit ?? view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    // MARK: The island moments

    lazy var codexAsk = session("codex-ask", [
        "agent": "codex", "state": "permission", "label": "Bash: npm publish --tag next",
        "project": "webshop", "started_at": ts - 600, "prompt": "cut the 2.4 release and publish it",
    ])
    lazy var codexRequest = request("codex-ask-p1", [
        "sessionId": "codex-ask", "agent": "codex", "toolName": "Bash",
        "display": "Bash: npm publish --tag next",
        "toolInputPretty": "{\"command\": \"npm publish --tag next\"}",
        "context": ["kind": "bash", "command": "npm publish --tag next"],
        "pid": 1, "hookPid": 1, "ts": ts, "cwd": "/tmp",
    ])

    lazy var held: NSImage = {
        var s = session("held", [
            "agent": "claude", "state": "tool", "label": "Running command", "project": "api",
            "started_at": ts - 1_500, "prompt": "clean the build and rerun the integration suite",
            "model": "claude-opus-5-5",
        ])
        s.state = .permission
        s.heldByMod = true
        s.label = "Held before it runs: rm -r build"
        let gem = session("gem", ["agent": "gemini", "state": "thinking", "label": "Thinking…",
                                  "project": "landing", "started_at": ts - 300, "prompt": "tighten the hero copy"])
        let cdx = session("cdx", ["agent": "codex", "state": "tool", "label": "Running tests",
                                  "project": "webshop", "started_at": ts - 900, "prompt": "fix the flaky cart test"])
        return island([row(s, hero: true), row(gem), row(cdx)], footer: footer())
    }()

    lazy var context: NSImage = {
        var s = session("ctx", [
            "agent": "claude", "state": "thinking", "label": "Thinking…", "project": "api",
            "started_at": ts - 4_200, "prompt": "port the billing worker to the new queue",
            "model": "claude-opus-5-5",
        ])
        s.contextPercent = 88
        s.modSeen = true
        let cdx = session("cdx2", ["agent": "codex", "state": "done", "label": "", "project": "webshop",
                                   "started_at": ts - 2_000, "recap": "All 214 tests pass."])
        return island([row(s, hero: true), row(cdx)], footer: footer())
    }()

    lazy var approval: NSImage = {
        let card = IslandApprovalView(request: codexRequest, deferTitle: "Answer in terminal",
                                      width: rowW - 12, onChoose: { _ in })
        let wrap = NSStackView(views: [card])
        wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
        return island([row(codexAsk, hero: true), wrap], footer: footer(joystickLit: true))
    }()

    lazy var joystick: NSImage = {
        let gem = session("gem3", ["agent": "gemini", "state": "thinking", "label": "Thinking…",
                                   "project": "landing", "started_at": ts - 300, "prompt": "tighten the hero copy"])
        let cdx = session("cdx3", ["agent": "codex", "state": "tool", "label": "Running tests",
                                   "project": "webshop", "started_at": ts - 900, "prompt": "fix the flaky cart test"])
        return island([row(gem, hero: true), row(cdx)], footer: footer(joystickLit: true))
    }()

    // MARK: The game, frame by frame

    lazy var gameView: BreakGameView = {
        let v = BreakGameView(defaults: UserDefaults(suiteName: "agentbar-promo-\(getpid())")!)
        v.game = BreakGame(seed: 2026)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: BreakGameView.size.width).isActive = true
        v.heightAnchor.constraint(equalToConstant: BreakGameView.size.height).isActive = true
        return v
    }()
    private var gameContent: IslandContentView?

    /// Advances the game one 30 fps frame (two model steps) and draws the island.
    func gameFrame(advance: Bool = true, paused: Bool = false) -> NSImage {
        if advance {
            for _ in 0..<2 {
                gameView.autopilot()
                gameView.game.input = .init(left: gameView.left, right: gameView.right)
                gameView.game.step(dt: 1.0 / 60)
            }
        }
        gameView.paused = paused
        if gameContent == nil {
            let ear = IslandShape.earWidth
            let width = IslandShape.panelWidth(body: IslandController.expandedWidth, ear: ear)
            let c = IslandContentView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            c.appearance = NSAppearance(named: .darkAqua)
            c.flushTop = true
            c.earWidth = ear
            c.collapsedHeight = 30
            c.topInset = 10
            c.setFooter(nil)
            c.setRows([gameView])
            gameContent = c
        }
        let c = gameContent!
        gameView.needsDisplay = true
        return snap(c, NSSize(width: c.frame.width > 0 ? c.frame.width : 486, height: c.contentHeight))
    }

    // MARK: Settings cards

    lazy var claudeCodePage: NSImage = {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = SettingsChrome.Space.gap
        col.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        func add(_ v: NSView) {
            col.addArrangedSubview(v)
            if !(v is NSTextField) {
                v.widthAnchor.constraint(equalToConstant: SettingsChrome.cardWidth).isActive = true
            }
        }
        let heading = NSTextField(labelWithString: "Claude Code")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        add(heading)
        add(SettingsChrome.card([SettingsChrome.customRow(AnsweredWithoutYouView())]))
        let band = NSSwitch()
        band.controlSize = .small
        band.state = .on
        add(SettingsChrome.card([SettingsChrome.row(
            "Show other agents waiting, above Claude Code's prompt",
            "One line inside Claude Code while another session needs you, with a key to jump to it. Never answers it.",
            control: band)]))
        add(SettingsChrome.header(AgentsPage.pluginsTitle))
        let blast = PluginInventory.Plugin(key: "blast-radius@m", name: "blast-radius", configDirs: [],
                                           installPath: "/p", kind: .mod,
                                           events: [.init(name: "tool.call", filter: ["tool": "Bash"])],
                                           estimated: false, ours: false)
        let ours = PluginInventory.Plugin(key: "agentbar@inline", name: "agentbar", configDirs: [],
                                          installPath: "/p", kind: .mod, events: [], estimated: false, ours: true)
        let badge = NSTextField(labelWithString: AgentsPage.pluginBadge(blast))
        badge.font = .systemFont(ofSize: 10.5, weight: .medium)
        badge.textColor = .secondaryLabelColor
        add(SettingsChrome.card([
            SettingsChrome.row(blast.name, AgentsPage.pluginDetail(blast, showDirs: false), control: badge),
            SettingsChrome.noteRow(SettingsChrome.caption(AgentsPage.alsoLoaded([ours]) ?? "")),
        ]))
        let page = SettingsSurface(fill: { NSColor(white: 0.13, alpha: 1) })
        page.translatesAutoresizingMaskIntoConstraints = false
        col.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: page.topAnchor), col.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: page.leadingAnchor), col.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        ])
        // Twice: the card reads its ledger once it is in a window.
        _ = snap(page)
        return snap(page)
    }()

    lazy var whatsNew: NSImage = {
        let text = (try? String(contentsOfFile: "CHANGELOG.md", encoding: .utf8)) ?? ""
        let releases = ReleaseNotes.parse(text).filter { ["1.41.0", "1.40.0"].contains($0.version) }
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = SettingsChrome.Space.gap
        col.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        let heading = NSTextField(labelWithString: "What's New")
        heading.font = .systemFont(ofSize: 20, weight: .bold)
        col.addArrangedSubview(heading)
        let header = SettingsChrome.header("New since you last looked — 2 releases")
        col.addArrangedSubview(header)
        for r in releases {
            var r = r
            // The first section of each, so the card reads at a glance.
            if let cut = r.blocks.dropFirst().firstIndex(where: { if case .heading = $0 { return true }; return false }) {
                r.blocks = Array(r.blocks[..<cut])
            }
            // The heading and the first point: a card read at a glance, not a page.
            r.blocks = Array(r.blocks.prefix { if case .bullet = $0 { return false }; return true }.suffix(1))
                + Array(r.blocks.filter { if case .bullet = $0 { return true }; return false }.prefix(1))
                .map { b -> ReleaseNotes.Block in
                    guard case .bullet(let s, let l) = b else { return b }
                    // Up to the end of its first sentence after the bold lead.
                    let cut = s.range(of: ". ", range: s.index(s.startIndex, offsetBy: min(60, s.count))..<s.endIndex)
                    return .bullet(cut.map { String(s[..<$0.lowerBound]) + "." } ?? s, level: l)
                }
            let date = NSTextField(labelWithString: r.date.map { ReleaseNotes.displayDate($0) } ?? "")
            date.font = .systemFont(ofSize: 11.5)
            date.textColor = .secondaryLabelColor
            let pill = NSTextField(labelWithString: " New ")
            pill.font = .systemFont(ofSize: 10.5, weight: .semibold)
            pill.textColor = .white
            pill.drawsBackground = true
            pill.backgroundColor = .controlAccentColor
            let width = SettingsChrome.cardWidth - SettingsChrome.rowInset * 2
            let card = SettingsChrome.card([
                SettingsChrome.row(r.version, control: date, accessory: pill),
                SettingsChrome.customRow(ReleaseNotesView(r, width: width), height: 0),
            ])
            col.addArrangedSubview(card)
            card.widthAnchor.constraint(equalToConstant: SettingsChrome.cardWidth).isActive = true
        }
        let page = SettingsSurface(fill: { NSColor(white: 0.13, alpha: 1) })
        page.translatesAutoresizingMaskIntoConstraints = false
        col.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: page.topAnchor), col.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            col.leadingAnchor.constraint(equalTo: page.leadingAnchor), col.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        ])
        return snap(page)
    }()

    // MARK: The band, inside Claude Code

    /// A terminal running Claude Code with the mod's band above the prompt. The
    /// band's words are the mod's own (`bandLine`); the transcript around it is
    /// set dressing.
    lazy var terminal: NSImage = {
        let size = NSSize(width: 860, height: 520)
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        let frame = CGRect(origin: .zero, size: size)
        ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.clip()
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1).setFill()
        frame.fill()
        NSColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1).setFill()
        NSRect(x: 0, y: size.height - 38, width: size.width, height: 38).fill()
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 18 + CGFloat(i) * 20, y: size.height - 25, width: 12, height: 12)).fill()
        }
        func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ color: NSColor, size f: CGFloat = 15,
                  weight: NSFont.Weight = .regular) {
            NSAttributedString(string: s, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: f, weight: weight), .foregroundColor: color,
            ]).draw(at: NSPoint(x: x, y: y))
        }
        let dim = NSColor(white: 0.55, alpha: 1), body = NSColor(white: 0.88, alpha: 1)
        let orange = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        text("claude — api", size.width / 2 - 52, size.height - 27, dim, size: 13)
        var y = size.height - 80
        text("> clean the build and rerun the integration suite", 28, y, dim); y -= 34
        text("⏺", 28, y, orange); text("Reading tests/integration/checkout.test.ts", 50, y, body); y -= 26
        text("⏺", 28, y, orange); text("Bash(npm run test:integration)", 50, y, body); y -= 24
        text("  ⎿  48 passed, 0 failed (12.4s)", 28, y, dim); y -= 34
        text("⏺", 28, y, orange); text("All green. Want me to push the branch?", 50, y, body)

        // The band: the mod's own line and its Jump button.
        let bandY: CGFloat = 132
        let line = "◆ Codex needs your approval · webshop"
        text(line, 28, bandY, NSColor(srgbRed: 0.96, green: 0.77, blue: 0.26, alpha: 1), weight: .semibold)
        let jump = NSRect(x: 520, y: bandY - 5, width: 92, height: 28)
        NSColor(white: 1, alpha: 0.12).setFill()
        NSBezierPath(roundedRect: jump, xRadius: 6, yRadius: 6).fill()
        text("1: Jump", jump.minX + 14, bandY, body, weight: .semibold)

        let box = NSRect(x: 20, y: 54, width: size.width - 40, height: 56)
        NSColor(white: 0.4, alpha: 1).setStroke()
        let p = NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8)
        p.lineWidth = 1.2
        p.stroke()
        text("❯", 38, 73, body)
        NSColor(white: 0.85, alpha: 1).setFill()
        NSRect(x: 60, y: 72, width: 9, height: 19).fill()
        text("⏵⏵ auto mode on · shift+tab to cycle", 28, 22, dim, size: 12.5)
        img.unlockFocus()
        return img
    }()
}

// MARK: - The storyboard

struct Scene {
    var duration: Double
    var title: String
    var subtitle: String
    /// What the scene shows at local time `t` (seconds), or nil for a title card.
    var picture: (Double) -> NSImage?
    /// Island scenes hang from the notch at the top; the rest float in the middle.
    var hangs = false
    var titleCard = false
}

enum Storyboard {
    static func scenes(_ a: Art) -> [Scene] {
        // The game is played once, in order, and each frame is kept: the video and
        // the GIFs show the same game.
        var play: [NSImage] = []
        for _ in 0..<Int(6.0 * 30) { play.append(a.gameFrame()) }
        let pausedFrame = a.gameFrame(advance: false, paused: true)
        var resume: [NSImage] = []
        for _ in 0..<Int(2.6 * 30) { resume.append(a.gameFrame()) }
        Gifs.play = play
        Gifs.resume = resume
        Gifs.paused = pausedFrame

        func at(_ frames: [NSImage]) -> (Double) -> NSImage? {
            { t in frames[min(max(Int(t * 30), 0), frames.count - 1)] }
        }
        return [
            Scene(duration: 2.8, title: "AgentBar", subtitle: "What we shipped today · 1.38 → 1.41",
                  picture: { _ in a.icon }, titleCard: true),
            Scene(duration: 3.6, title: "See what Claude Code decides without you",
                  subtitle: "Your rules, its mode, hooks — and now auto mode, counted.",
                  picture: { _ in a.claudeCodePage }),
            Scene(duration: 3.2, title: "A held command is a wait, not work",
                  subtitle: "When a mod holds rm -r for you, the island says so.",
                  picture: { _ in a.held }, hangs: true),
            Scene(duration: 3.2, title: "Other agents waiting — inside Claude Code",
                  subtitle: "One line above the prompt, one key to jump. It never answers.",
                  picture: { _ in a.terminal }),
            Scene(duration: 2.8, title: "Live quota and context",
                  subtitle: "Straight from Claude Code — ctx 88% before it compacts.",
                  picture: { _ in a.context }, hangs: true),
            Scene(duration: 3.0, title: "Release notes, where you look",
                  subtitle: "Settings ▸ What's New — before and after every update.",
                  picture: { _ in a.whatsNew }),
            Scene(duration: 2.0, title: "Need a break?", subtitle: "The joystick, next to ⋯.",
                  picture: { _ in a.joystick }, hangs: true),
            Scene(duration: 6.0, title: "Take a break", subtitle: "Clawd vs. the bugs — right in the island.",
                  picture: at(play), hangs: true),
            Scene(duration: 1.0, title: "Take a break", subtitle: "Clawd vs. the bugs — right in the island.",
                  picture: { _ in pausedFrame }, hangs: true),
            Scene(duration: 3.2, title: "…and it steps aside for work",
                  subtitle: "The moment an agent needs you, the game pauses and the ask is right there.",
                  picture: { _ in a.approval }, hangs: true),
            Scene(duration: 2.6, title: "Back to the break", subtitle: "Score intact.",
                  picture: at(resume), hangs: true),
            Scene(duration: 3.2, title: "AgentBar 1.41",
                  subtitle: "Free & open source · github.com/michalstrnadel/AgentBar",
                  picture: { _ in a.icon }, titleCard: true),
        ]
    }
}

// MARK: - Frames, video, stills

enum Video {
    static let fps = 30.0
    static let fade = 0.35

    /// Frames go straight into ffmpeg as raw RGBA — none touch the disk. (The first
    /// version wrote PNGs to the temp folder and filled a nearly full disk.)
    static func render(_ scenes: [Scene], size: NSSize, name: String) {
        let mp4 = Promo.outDir.appendingPathComponent("video/\(name).mp4")
        let pipe = FFmpegPipe(size: size, output: ["-c:v", "libx264", "-preset", "slow", "-crf", "17",
                                                   "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4.path])
        for (si, scene) in scenes.enumerated() {
            for f in 0..<Int(scene.duration * fps) {
                autoreleasepool {
                    pipe.send(frame(scene, t: Double(f) / fps, size: size, first: si == 0,
                                    last: si == scenes.count - 1))
                }
            }
        }
        pipe.finish()
        print("wrote \(mp4.path)")
    }

    static func stills(_ scenes: [Scene], size: NSSize, suffix: String) {
        for (i, s) in scenes.enumerated() where !s.titleCard || i == 0 {
            let img = frame(s, t: s.duration * 0.7, size: size, first: false, last: false)
            let slug = s.title.lowercased().filter { $0.isLetter || $0 == " " }
                .split(separator: " ").prefix(5).joined(separator: "-")
            write(img, to: Promo.outDir.appendingPathComponent(String(format: "stills/%02d-%@-%@.png", i, slug, suffix)))
        }
    }

    /// One frame: the backdrop, the picture easing in, the words under it, and a
    /// fade at the scene's edges.
    static func frame(_ s: Scene, t: Double, size: NSSize, first: Bool, last: Bool) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.interpolationQuality = .high
        backdrop(ctx, size, notch: s.hangs)

        let enter = ease(min(t / 0.55, 1))
        let alpha = min(t / fade, (s.duration - t) / fade, 1)
        let wide = size.width > size.height * 1.2
        let tall = size.height > size.width * 1.2
        let titleSize: CGFloat = s.titleCard ? (wide ? 92 : 84) : (wide ? 54 : 50)
        let subSize: CGFloat = s.titleCard ? 30 : (wide ? 27 : 25)
        let textBlock: CGFloat = s.titleCard ? 0 : (tall ? 330 : wide ? 210 : 230)

        var picBottom: CGFloat?
        if let pic = s.picture(t) {
            let maxW = size.width * (s.titleCard ? 0.22 : (wide ? 0.62 : 0.86))
            let maxH = (size.height - textBlock - (s.hangs ? 40 : 120)) * (s.titleCard ? 0.32 : 1)
            var scale = min(maxW / pic.size.width, maxH / pic.size.height)
            if s.hangs { scale = min(scale, 2.1) }
            let w = pic.size.width * scale, h = pic.size.height * scale
            let lift = CGFloat(1 - enter) * 26
            // A floating picture and its words are one block, centred in the frame.
            let floatTop = (size.height + h + (wide ? 56 : 64) + titleSize + subSize * 2.6) / 2
            var rect: NSRect
            if s.hangs {
                rect = NSRect(x: (size.width - w) / 2, y: size.height - 34 - h + lift, width: w, height: h)
            } else if s.titleCard {
                rect = NSRect(x: (size.width - w) / 2, y: size.height * 0.56 - lift, width: w, height: h)
            } else {
                rect = NSRect(x: (size.width - w) / 2, y: floatTop - h - lift, width: w, height: h)
                // A floating window: soft shadow and rounded corners.
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 50,
                              color: NSColor.black.withAlphaComponent(0.6 * alpha).cgColor)
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).fill()
                ctx.restoreGState()
                ctx.saveGState()
                NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).addClip()
                pic.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
                ctx.restoreGState()
                rect = .zero
            }
            if !s.titleCard {
                picBottom = s.hangs ? size.height - 34 - h : floatTop - h
            }
            if rect != .zero {
                if s.hangs {
                    ctx.saveGState()
                    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 60,
                                  color: NSColor.black.withAlphaComponent(0.7 * alpha).cgColor)
                    pic.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
                    ctx.restoreGState()
                } else {
                    pic.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
                }
            }
        }

        // Under the picture, close enough to belong to it; never below the frame.
        let titleY: CGFloat = s.titleCard ? size.height * 0.36
            : max(picBottom.map { $0 - titleSize - (wide ? 56 : 64) } ?? (textBlock - 70), subSize * 2.6 + 50)
        let words = CGFloat(ease(min(max((t - 0.12) / 0.5, 0), 1)))
        drawCentered(s.title, y: titleY + (1 - words) * 14, width: size.width, font:
            .systemFont(ofSize: titleSize, weight: .bold), color: NSColor.white.withAlphaComponent(alpha * words))
        drawCentered(s.subtitle, y: titleY - subSize * 1.9 + (1 - words) * 14, width: size.width,
                     font: .systemFont(ofSize: subSize, weight: .medium),
                     color: NSColor(white: 0.72, alpha: alpha * words))
        img.unlockFocus()
        return img
    }

    /// Near-black with Clawd's warmth glowing behind the subject; a menu bar and a
    /// notch for the scenes that hang from one.
    static func backdrop(_ ctx: CGContext, _ size: NSSize, notch: Bool) {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let base = CGGradient(colorsSpace: space, colors: [
            NSColor(srgbRed: 0.055, green: 0.05, blue: 0.07, alpha: 1).cgColor,
            NSColor(srgbRed: 0.10, green: 0.07, blue: 0.09, alpha: 1).cgColor,
        ] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(base, start: CGPoint(x: 0, y: 0), end: CGPoint(x: size.width, y: size.height), options: [])
        let glow = CGGradient(colorsSpace: space, colors: [
            NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0.28).cgColor,
            NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 0).cgColor,
        ] as CFArray, locations: [0, 1])!
        let c = CGPoint(x: size.width / 2, y: size.height * 0.62)
        ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c,
                               endRadius: max(size.width, size.height) * 0.55, options: [])
        guard notch else { return }
        NSColor(white: 0.0, alpha: 0.55).setFill()
        NSRect(x: 0, y: size.height - 34, width: size.width, height: 34).fill()
        let items = ["", "File", "Edit", "View", "Window"]
        var x: CGFloat = 26
        for (i, s) in items.enumerated() {
            let str = i == 0 ? "" : s
            let a = NSAttributedString(string: str, attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: i == 1 ? .semibold : .regular),
                .foregroundColor: NSColor(white: 0.85, alpha: 0.8)])
            a.draw(at: NSPoint(x: x, y: size.height - 26))
            x += a.size().width + 22
        }
        let clock = NSAttributedString(string: "Mon 5 Oct  14:41", attributes: [
            .font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor(white: 0.85, alpha: 0.8)])
        clock.draw(at: NSPoint(x: size.width - clock.size().width - 26, y: size.height - 26))
    }

    static func drawCentered(_ s: String, y: CGFloat, width: CGFloat, font: NSFont, color: NSColor) {
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let h = a.boundingRect(with: NSSize(width: width - 120, height: 400), options: [.usesLineFragmentOrigin]).height
        a.draw(with: NSRect(x: 60, y: y, width: width - 120, height: h), options: [.usesLineFragmentOrigin])
    }

    static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }

    static func write(_ img: NSImage, to url: URL) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    static func ffmpeg(_ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-loglevel", "error"] + args
        try! p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 { print("ffmpeg failed: \(args.last ?? "")") }
    }
}

// MARK: - GIFs: the island alone, small enough to post

enum Gifs {
    static var play: [NSImage] = []
    static var resume: [NSImage] = []
    static var paused: NSImage?

    static func render(_ a: Art) {
        // The game on its own; then the whole yield, play → ask → back.
        write(play, name: "take-a-break")
        var yield = Array(play.suffix(60))
        if let p = paused { yield += Array(repeating: p, count: 15) }
        yield += Array(repeating: a.approval, count: 54)
        yield += resume
        write(yield, name: "take-a-break-steps-aside")
        for (img, name) in [(a.held, "held-before-it-runs"), (a.approval, "steps-aside-for-an-ask"),
                            (a.context, "context-and-quota"), (a.joystick, "joystick"),
                            (a.claudeCodePage, "settings-claude-code"), (a.whatsNew, "settings-whats-new"),
                            (a.terminal, "band-in-claude-code"), (play[120], "take-a-break")] {
            Video.write(onDark(img), to: Promo.outDir.appendingPathComponent("stills/ui-\(name).png"))
        }
    }

    /// An island picture on a canvas the same for every frame, hanging from a notch.
    static func onDark(_ img: NSImage, canvas: NSSize? = nil) -> NSImage {
        let size = canvas ?? NSSize(width: img.size.width + 80, height: img.size.height + 60)
        let out = NSImage(size: size)
        out.lockFocus()
        NSColor(srgbRed: 0.07, green: 0.06, blue: 0.08, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        img.draw(in: NSRect(x: (size.width - img.size.width) / 2, y: size.height - img.size.height - 20,
                            width: img.size.width, height: img.size.height))
        out.unlockFocus()
        return out
    }

    static func write(_ frames: [NSImage], name: String) {
        guard !frames.isEmpty else { return }
        // Even, for x264.
        let w = (frames.map(\.size.width).max()! + 60).rounded(.up) / 2 * 2
        let h = (frames.map(\.size.height).max()! + 50).rounded(.up) / 2 * 2
        let canvas = NSSize(width: (w / 2).rounded() * 2, height: (h / 2).rounded() * 2)
        let gif = Promo.outDir.appendingPathComponent("gifs/\(name).gif")
        let mp4 = Promo.outDir.appendingPathComponent("gifs/\(name).mp4")
        for out in [
            ["-vf", "fps=20,scale=600:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a",
             "-loop", "0", gif.path],
            ["-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", mp4.path],
        ] {
            let pipe = FFmpegPipe(size: canvas, output: out)
            for f in frames { autoreleasepool { pipe.send(onDark(f, canvas: canvas)) } }
            pipe.finish()
        }
        print("wrote \(gif.path)")
    }
}

/// ffmpeg reading raw RGBA frames from its stdin.
final class FFmpegPipe {
    private let process = Process()
    private let input = Pipe()
    private let width: Int, height: Int
    private let ctx: CGContext

    init(size: NSSize, output: [String]) {
        width = Int(size.width)
        height = Int(size.height)
        ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        process.arguments = ["-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgba",
                             "-s", "\(width)x\(height)", "-r", "30", "-i", "-"] + output
        process.standardInput = input
        try! process.run()
    }

    func send(_ img: NSImage) {
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        img.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        input.fileHandleForWriting.write(Data(bytes: ctx.data!, count: width * height * 4))
    }

    func finish() {
        input.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { print("ffmpeg failed (\(process.terminationStatus))") }
    }
}

// MARK: - The Take a break film

/// A whole break, played by the autopilot: the joystick, the bugs, a cleared wave,
/// an agent asking (and the game stepping aside), back again, and the high score.
/// The game is simulated first as states — cheap to keep — and drawn frame by frame
/// from them, so the film can cut to the moments that matter in one honest game.
enum GameFilm {
    struct Moment { var game: BreakGame; var newHigh: Bool }

    /// Plays seeds until one reaches wave 2 and then ends, keeping every 30 fps state.
    static func play() -> [BreakGame] {
        let probe = BreakGameView(defaults: UserDefaults(suiteName: "agentbar-promo-film-\(getpid())")!)
        for seed in UInt64(1)...200 {
            probe.game = BreakGame(seed: seed)
            var states: [BreakGame] = []
            var cleared = false
            for _ in 0..<(30 * 150) {
                for _ in 0..<2 {
                    probe.autopilot()
                    probe.game.input = .init(left: probe.left, right: probe.right)
                    if probe.game.step(dt: 1.0 / 60).waveCleared { cleared = true }
                }
                states.append(probe.game)
                if probe.game.phase == .over { break }
            }
            if cleared, probe.game.phase == .over, states.count > 30 * 25 {
                print("film: seed \(seed), \(states.count / 30) s, score \(probe.game.score)")
                return states
            }
        }
        fatalError("no seed reached wave 2")
    }

    static func scenes(_ a: Art) -> [Scene] {
        let states = play()
        let v = a.gameView
        func frame(_ g: BreakGame, paused: Bool = false, high: Bool = false) -> NSImage {
            v.game = g
            v.newHigh = high
            return a.gameFrame(advance: false, paused: paused)
        }
        func clip(_ from: Int, _ seconds: Double, high: Bool = false) -> (Double) -> NSImage? {
            { t in frame(states[min(from + Int(t * 30), states.count - 1)], high: high) }
        }
        let waveAt = states.firstIndex { if case .intro = $0.phase { return true }; return false } ?? 300
        let overAt = states.firstIndex { $0.phase == .over } ?? states.count - 1
        let yieldAt = min(waveAt + 150, overAt - 120)
        let pausedState = states[yieldAt]

        return [
            Scene(duration: 3.0, title: "Take a break", subtitle: "A tiny arcade game, inside AgentBar's island.",
                  picture: { _ in poster }, titleCard: true),
            Scene(duration: 2.4, title: "One click", subtitle: "The joystick, next to ⋯.",
                  picture: { _ in a.joystick }, hangs: true),
            Scene(duration: 7.0, title: "Clawd vs. the bugs", subtitle: "Arrows to move, Space to fire.",
                  picture: clip(max(waveAt - 30 * 9, 0), 7), hangs: true),
            Scene(duration: 3.4, title: "Clear the wave", subtitle: "The next one comes faster.",
                  picture: clip(max(waveAt - 30, 0), 3.4), hangs: true),
            Scene(duration: 4.0, title: "Divers pay double", subtitle: "Catch a falling token for 100 more.",
                  picture: clip(waveAt + 60, 4), hangs: true),
            Scene(duration: 1.0, title: "An agent needs you", subtitle: "",
                  picture: { _ in frame(pausedState, paused: true) }, hangs: true),
            Scene(duration: 3.4, title: "The game steps aside", subtitle: "The ask is right there. Answer it.",
                  picture: { _ in a.approval }, hangs: true),
            Scene(duration: 3.0, title: "Back to the break", subtitle: "Score intact.",
                  picture: clip(yieldAt, 3), hangs: true),
            Scene(duration: 3.2, title: "New high score", subtitle: "Kept on your Mac.",
                  picture: clip(overAt, 3.2, high: true), hangs: true),
            Scene(duration: 3.4, title: "AgentBar 1.41",
                  subtitle: "Free & open source · github.com/michalstrnadel/AgentBar",
                  picture: { _ in a.icon }, titleCard: true),
        ]
    }

    /// The poster: the three bugs over Clawd's ship, big pixels.
    static let poster: NSImage = {
        let px: CGFloat = 9
        let size = NSSize(width: 11 * px * 3 + px * 8, height: 7 * px * 2 + px * 10)
        let img = NSImage(size: size)
        img.lockFocus()
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.interpolationQuality = .none
        for (i, kind) in [BreakGame.Kind.drone, .boss, .wasp].enumerated() {
            if let art = BreakGameArt.bugs[kind]?.first, let cg = BreakGameArt.image(art, pixel: px) {
                ctx.draw(cg, in: CGRect(x: CGFloat(i) * (11 * px + px * 4), y: size.height - 7 * px,
                                        width: 11 * px, height: 7 * px))
            }
        }
        if let ship = BreakGameArt.image(BreakGameArt.ship, pixel: px) {
            ctx.draw(ship, in: CGRect(x: (size.width - 11 * px) / 2, y: 0, width: 11 * px, height: 7 * px))
        }
        NSColor(srgbRed: 0.96, green: 0.77, blue: 0.26, alpha: 1).setFill()
        NSRect(x: size.width / 2 - px / 2, y: 7 * px + px * 2, width: px, height: px * 3).fill()
        img.unlockFocus()
        return img
    }()
}

// MARK: - Assets for the video studio

/// The pictures with nothing behind them (transparent PNG at 2×) and the game as
/// VP9 clips with alpha, plus a JSON of where the moments are, so a film made
/// elsewhere can tilt, zoom and cut them without redrawing anything.
enum Assets {
    static func write(_ a: Art) {
        let dir = Promo.outDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (img, name) in [(a.held, "island-held"), (a.approval, "island-approval"),
                            (a.context, "island-context"), (a.joystick, "island-joystick"),
                            (a.claudeCodePage, "settings-claude-code"), (a.whatsNew, "settings-whats-new"),
                            (a.terminal, "terminal-band"), (GameFilm.poster, "game-poster"), (a.icon, "app-icon")] {
            Video.write(img, to: dir.appendingPathComponent("\(name).png"))
            print("wrote \(name).png \(Int(img.size.width))×\(Int(img.size.height))")
        }
        let states = GameFilm.play()
        let v = a.gameView
        func frame(_ g: BreakGame, paused: Bool = false, high: Bool = false) -> NSImage {
            v.game = g
            v.newHigh = high
            return a.gameFrame(advance: false, paused: paused)
        }
        let waveAt = states.firstIndex { if case .intro = $0.phase { return true }; return false } ?? 300
        let overAt = states.firstIndex { $0.phase == .over } ?? states.count - 1
        let yieldAt = min(waveAt + 150, overAt - 120)
        Video.write(frame(states[yieldAt], paused: true), to: dir.appendingPathComponent("game-paused.png"))

        func clip(_ name: String, _ frames: [BreakGame], high: Bool = false) {
            let first = frame(frames[0], high: high)
            let px = NSSize(width: first.size.width * 2, height: (first.size.height * 2 / 2).rounded() * 2)
            let pipe = FFmpegPipe(size: px, output: [
                "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "0", "-crf", "20",
                "-row-mt", "1", "-auto-alt-ref", "0", dir.appendingPathComponent("\(name).webm").path])
            for g in frames { autoreleasepool { pipe.send(frame(g, high: high)) } }
            pipe.finish()
            print("wrote \(name).webm \(frames.count) frames")
        }
        clip("game-play", Array(states[..<overAt]))
        clip("game-over", Array(repeating: states[overAt], count: 30 * 4), high: true)
        // Bug Hunt: the title, and the game played by its hunter in A and in B.
        let title = HuntGameView(defaults: UserDefaults(suiteName: "agentbar-promo-hunt-title-\(getpid())")!)
        title.frame = NSRect(origin: .zero, size: HuntGameView.size)
        Video.write(HuntClip.snapshot(title), to: dir.appendingPathComponent("hunt-title.png"))
        HuntClip.write(to: dir.appendingPathComponent("hunt-a.mp4"), mode: .a, seconds: 40, seed: 2026,
                       output: ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
        HuntClip.write(to: dir.appendingPathComponent("hunt-b.mp4"), mode: .b, seconds: 20, seed: 7,
                       output: ["-c:v", "libx264", "-crf", "12", "-preset", "slow", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
        let marks: [String: Any] = ["fps": 30, "frames": overAt, "waveCleared": waveAt,
                                    "yield": yieldAt, "score": states[overAt].score]
        try? JSONSerialization.data(withJSONObject: marks, options: [.prettyPrinted, .sortedKeys])
            .write(to: dir.appendingPathComponent("game-marks.json"))
    }
}

// MARK: - Bug Hunt

/// Bug Hunt played by its autopilot for a while, streamed straight into ffmpeg:
/// the same seed every run, so the GIF and the MP4 are the same game.
enum HuntClip {
    static let seconds = 26.0

    static func write() {
        for (name, out) in [
            ("gif", ["-vf", "fps=20,scale=432:-1:flags=neighbor,split[a][b];[a]palettegen=max_colors=96:stats_mode=full[p];[b][p]paletteuse=dither=none",
                     "-loop", "0"]),
            ("mp4", ["-c:v", "libx264", "-crf", "16", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]),
        ] {
            write(to: Promo.outDir.appendingPathComponent("gifs/bug-hunt.\(name)"), mode: .a, seconds: seconds,
                  seed: 2026, output: out)
        }
    }

    /// Bug Hunt played by its hunter from the title on, at 30 fps, 2×.
    static func write(to url: URL, mode: HuntGame.Mode, seconds: Double, seed: UInt64, output: [String]) {
        let pipe = FFmpegPipe(size: NSSize(width: HuntGameView.size.width * 2, height: HuntGameView.size.height * 2),
                              output: output + [url.path])
        let v = HuntGameView(defaults: UserDefaults(suiteName: "agentbar-promo-hunt-\(getpid())-\(seed)")!)
        v.game = HuntGame(seed: seed)
        v.game.start(mode)
        v.frame = NSRect(origin: .zero, size: HuntGameView.size)
        for _ in 0..<Int(seconds * 30) {
            for _ in 0..<2 {
                v.autopilot(dt: 1.0 / 60)
                v.advance(dt: 1.0 / 60)
            }
            autoreleasepool { pipe.send(snapshot(v)) }
        }
        pipe.finish()
        print("wrote \(url.path)")
    }

    static func snapshot(_ v: NSView) -> NSImage {
        let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
        v.cacheDisplay(in: v.bounds, to: rep)
        let img = NSImage(size: v.bounds.size)
        img.addRepresentation(rep)
        return img
    }
}

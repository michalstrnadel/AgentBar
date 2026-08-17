// Render harness: draws the REAL island views (not mockups) into PNGs, so UI
// changes can be reviewed pixel-accurately without launching the app — fake
// sessions and requests round-trip through the real decoders on the way in.
// Build & run (from repo root):
//   swiftc -target arm64-apple-macos12.0 \
//     $(find Sources/AgentBar -name "*.swift" ! -name "main.swift") \
//     Scripts/dev/render-preview.swift -o /tmp/render-preview
//   /tmp/render-preview <outDir>
import AppKit


@main
enum RenderPreview {
    static func main() {
        let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

        // MARK: - Fake sessions via real decoder (round-trips the state-file protocol)

        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentbar-harness-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        func makeSession(_ name: String, _ obj: [String: Any]) -> Session {
            let url = tmpDir.appendingPathComponent("\(name).json")
            let data = try! JSONSerialization.data(withJSONObject: obj)
            try! data.write(to: url)
            guard let s = Session(fileURL: url) else { fatalError("session \(name) failed to decode") }
            return s
        }

        let now = Int(Date().timeIntervalSince1970)

        let heroPermission = makeSession("hero-perm", [
            "agent": "claude", "state": "permission", "label": "Edit: src/auth/middleware.ts",
            "project": "auth-api", "cwd": "/tmp", "sessionId": "hero-perm", "pid": 1,
            "started": true, "ts": now, "started_at": now - 1680,
            "prompt": "fix the auth bug in middleware", "model": "claude-opus-5",
            "term_program": "WarpTerminal",
        ])
        let compactWorking = makeSession("compact-work", [
            "agent": "codex", "state": "tool", "label": "Running command",
            "project": "webshop", "cwd": "/tmp", "sessionId": "compact-work", "pid": 1,
            "started": true, "ts": now, "started_at": now - 300,
            "prompt": "optimize the checkout queries",
        ])
        let compactDone = makeSession("compact-done", [
            "agent": "gemini", "state": "done", "label": "",
            "project": "landing", "cwd": "/tmp", "sessionId": "compact-done", "pid": 1,
            "started": true, "ts": now, "started_at": now - 5400,
        ])

        // MARK: - Rendering

        func render(_ view: NSView, name: String, size explicit: NSSize? = nil) {
            view.appearance = NSAppearance(named: .darkAqua)
            let size: NSSize
            if let explicit {
                size = explicit
            } else {
                view.layoutSubtreeIfNeeded()
                size = view.fittingSize
            }
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()

            // Host in a borderless window (never shown) so appearance + layer trees resolve.
            let window = NSWindow(contentRect: view.frame, styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = view

            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                print("FAIL rep \(name)"); return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                print("FAIL png \(name)"); return
            }
            let out = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
            try! png.write(to: out)
            print("wrote \(out.path) (\(Int(size.width))x\(Int(size.height)))")
        }

        /// Wrap rows in the island's dark slab so screenshots show the real background.
        func renderSlab(_ rows: [NSView], name: String, width: CGFloat = 460) {
            let content = IslandContentView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
            content.appearance = NSAppearance(named: .darkAqua)
            content.topInset = 10
            content.setRows(rows)
            render(content, name: name, size: NSSize(width: width, height: content.contentHeight))
        }

        func mark(for agentID: String) -> NSImage? {
            IconRenderer.shared.sprite(for: Agent.byID(agentID)).restingColor
        }

        let rowW: CGFloat = 460 - IslandContentView.hPad * 2

        func sized(_ v: NSView, _ w: CGFloat = 0) -> NSView {
            v.translatesAutoresizingMaskIntoConstraints = false
            if w > 0 { v.widthAnchor.constraint(equalToConstant: w).isActive = true }
            return v
        }

        // Scene 1: baseline — hero + approval card + compact rows (current behaviour).
        do {
            let hero = IslandRowView(session: heroPermission, mark: mark(for: "claude"),
                                     style: .hero, onClick: { _ in })
            let c1 = IslandRowView(session: compactWorking, mark: mark(for: "codex"),
                                   style: .compact, onClick: { _ in })
            let c2 = IslandRowView(session: compactDone, mark: mark(for: "gemini"),
                                   style: .compact, onClick: { _ in })
            renderSlab([sized(hero, rowW), sized(c1, rowW), sized(c2, rowW)],
                       name: "01-baseline-rows")
        }

        // MARK: - Question cards

        func makeRequest(_ name: String, _ obj: [String: Any]) -> ApprovalRequest {
            let url = tmpDir.appendingPathComponent("\(name).json")
            try! JSONSerialization.data(withJSONObject: obj).write(to: url)
            guard let r = ApprovalRequest(fileURL: url) else { fatalError("request \(name) failed") }
            return r
        }

        let questionSession = makeSession("q-sess", [
            "agent": "claude", "state": "question", "label": "❓ Which auth strategy should the new API use?",
            "project": "auth-api", "cwd": "/tmp", "sessionId": "q-sess", "pid": 1,
            "started": true, "ts": now, "started_at": now - 240,
            "prompt": "add authentication to the API", "model": "claude-opus-5",
            "term_program": "WarpTerminal",
        ])

        let singleQ = makeRequest("q-sess-p1", [
            "sessionId": "q-sess", "agent": "claude", "toolName": "AskUserQuestion",
            "display": "Question: Which auth strategy should the new API use?",
            "toolInputPretty": "{}",
            "context": ["kind": "question", "questions": [[
                "question": "Which auth strategy should the new API use?",
                "header": "Auth",
                "multiSelect": false,
                "options": [
                    ["label": "JWT tokens", "description": "Stateless, works across services"],
                    ["label": "Server sessions", "description": "Simple, revocable, needs sticky state"],
                    ["label": "OAuth via provider", "description": ""],
                ],
            ]]],
            "pid": 1, "hookPid": 1, "ts": now,
        ])

        let multiQ = makeRequest("q-sess-p2", [
            "sessionId": "q-sess", "agent": "claude", "toolName": "AskUserQuestion",
            "display": "Question: Which layers should the refactor touch?",
            "toolInputPretty": "{}",
            "context": ["kind": "question", "questions": [
                ["question": "Which layers should the refactor touch?", "header": "Layers",
                 "multiSelect": true,
                 "options": [["label": "API", "description": ""], ["label": "UI", "description": ""],
                             ["label": "Database", "description": "Includes a migration"]]],
                ["question": "Ship behind a feature flag?", "header": "",
                 "multiSelect": false,
                 "options": [["label": "Yes", "description": ""], ["label": "No", "description": ""]]],
            ]],
            "pid": 1, "hookPid": 1, "ts": now,
        ])

        let cardW = rowW - 12

        // Scene 2: single question, single-select — taps answer instantly.
        do {
            guard let qs = singleQ.questions else { fatalError("no questions decoded") }
            let hero = IslandRowView(session: questionSession, mark: mark(for: "claude"),
                                     style: .hero, onClick: { _ in })
            let card = IslandQuestionCardView(questions: qs, selections: [],
                                              deferTitle: "Answer in terminal", width: cardW,
                                              onAnswer: { _ in }, onSelect: { _ in }, onDefer: {})
            let wrap = NSStackView(views: [card])
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
            renderSlab([sized(hero, rowW), wrap], name: "02-question-single")
        }

        // Scene 3: multi question with multiSelect + selections in progress.
        do {
            guard let qs = multiQ.questions else { fatalError("no questions decoded") }
            let hero = IslandRowView(session: questionSession, mark: mark(for: "claude"),
                                     style: .hero, onClick: { _ in })
            let card = IslandQuestionCardView(questions: qs, selections: [[0, 2], []],
                                              deferTitle: "Answer in terminal", width: cardW,
                                              onAnswer: { _ in }, onSelect: { _ in }, onDefer: {})
            let wrap = NSStackView(views: [card])
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 0)
            renderSlab([sized(hero, rowW), wrap], name: "03-question-multi")
        }

        // Scene 4: done hero with a recap — "You: …" asks, "Claude: …" answers.
        do {
            let doneSession = makeSession("done-recap", [
                "agent": "claude", "state": "done", "label": "",
                "project": "auth-api", "cwd": "/tmp", "sessionId": "done-recap", "pid": 1,
                "started": true, "ts": now, "started_at": now - 1980,
                "prompt": "fix the auth bug in middleware", "model": "claude-opus-5",
                "term_program": "WarpTerminal",
                "recap": "Fixed the token check in middleware.ts and added 3 regression tests — all green.",
            ])
            let hero = IslandRowView(session: doneSession, mark: mark(for: "claude"),
                                     style: .hero, onClick: { _ in })
            let c1 = IslandRowView(session: compactWorking, mark: mark(for: "codex"),
                                   style: .compact, onClick: { _ in })
            renderSlab([sized(hero, rowW), sized(c1, rowW)], name: "04-done-recap")
        }

        // Scene 5: the Settings window's content, captured offscreen. Reflection pokes
        // at the private window to avoid ever ordering it onto the user's screen.
        do {
            let settings = SettingsWindow.shared
            // build() + reload() without show(): call show()'s internals via the only
            // public path, then immediately take the window off screen.
            settings.show()
            if let w = (Mirror(reflecting: settings).children.first { $0.label == "window" }?
                .value as? NSWindow?) ?? nil {
                w.orderOut(nil)
                if let content = w.contentView {
                    let size = content.fittingSize
                    content.frame = NSRect(origin: .zero, size: size)
                    content.layoutSubtreeIfNeeded()
                    if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                        content.cacheDisplay(in: content.bounds, to: rep)
                        if let png = rep.representation(using: .png, properties: [:]) {
                            try! png.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("05-settings.png"))
                            print("wrote \(outDir)/05-settings.png (\(Int(size.width))x\(Int(size.height)))")
                        }
                    }
                }
                w.close()
            }
        }

        print("done")

    }
}

import Carbon.HIToolbox
import Cocoa

/// AgentBar's Settings: a sidebar of seven pages — General, Notifications,
/// Shortcuts, Usage, Approvals, Rules and Diagnostics — each a short column of
/// grouped rows.
///
/// It used to be one scroll with every section stacked down it, which has two
/// faults that compound: everything is visible at once, so nothing is findable,
/// and each switch carried a paragraph, so the window grew until Diagnostics sat
/// off the bottom of the screen. A page you scroll is a document; this is a
/// window.
///
/// Every control still writes UserDefaults directly and fires `onChange`, so
/// changes apply live and the app delegate fans them out to whichever surfaces
/// care. Diagnostics is the odd one out: it sets nothing, it reports — see
/// `DiagnosticsView`. The furniture (cards, rows, the sidebar) is
/// `SettingsChrome`; this file owns what the controls *mean*.
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()
    /// Wide enough that a diagnostic's detail and its fix each sit on one or two
    /// lines rather than a paragraph.
    static let minWidth: CGFloat = 470
    var onChange: (() -> Void)?

    enum Page: String, CaseIterable {
        case general, agents, notifications, shortcuts, usage, approvals, rules
        // Spelled the way `agentbar://settings/claude-code` reads: links are lowercase.
        case claudeCode = "claude-code"
        case diagnostics

        var title: String {
            switch self {
            case .general:     return "General"
            case .agents:      return "Agents"
            case .notifications: return "Notifications"
            case .shortcuts:   return "Shortcuts"
            case .usage:       return "Usage"
            case .approvals:   return "Approvals"
            case .rules:       return "Rules"
            case .claudeCode:  return "Claude Code"
            case .diagnostics: return "Diagnostics"
            }
        }

        /// The tile colour, the way the system's settings list tells its panes
        /// apart at a glance. Meaning where there is meaning — the one that can
        /// interrupt you is red, the one that reports is orange — and a quiet
        /// grey where there is none.
        var tint: NSColor {
            switch self {
            case .general:       return .systemGray
            // The one page that writes into other programs' files.
            case .agents:        return .systemTeal
            case .notifications: return .systemRed
            case .shortcuts:     return NSColor.darkGray
            case .usage:         return .systemBlue
            case .approvals:     return .systemGreen
            // The one page where something acts on your behalf, so it does not
            // share a colour with the page that only remembers.
            case .rules:         return .systemIndigo
            // Claude's own colour: the one page about one vendor says whose it is.
            case .claudeCode:    return Agent.byID("claude").brand
            case .diagnostics:   return .systemOrange
            }
        }

        var symbol: String {
            switch self {
            case .general:     return "gearshape"
            case .agents:      return "point.3.connected.trianglepath.dotted"
            case .notifications: return "bell"
            case .shortcuts:   return "keyboard"
            case .usage:       return "speedometer"
            case .approvals:   return "checkmark.shield"
            case .rules:       return "list.bullet.rectangle"
            case .claudeCode:  return "sparkle"
            case .diagnostics: return "stethoscope"
            }
        }
    }

    private var window: NSWindow?
    private var enableBox: NSSwitch!
    private var allowRecorder: ShortcutRecorder!
    private var denyRecorder: ShortcutRecorder!
    private var launchBox: NSSwitch!
    private var launchRecorder: ShortcutRecorder!
    private var soundsBox: NSSwitch!
    private var volumeSlider: NSSlider!
    private var testButton: NSButton!
    private var volumeRow: NSStackView!
    private var soundFolderButton: NSButton!
    private var soundPackStatus: NSTextField!
    private var hideIslandBox: NSSwitch!
    private var hideAwayBox: NSSwitch!
    private var personalityBox: NSSwitch!
    private var modBandBox: NSSwitch!
    private var diagnostics: DiagnosticsView!
    private var configChangesButton: NSButton!
    /// The Agents card, rebuilt by `syncAgents` — its subtitles say each agent's
    /// state, and a row's subtitle is fixed once the row is made.
    private var agentsHost: NSStackView!
    /// The Claude Code page's plugin card, rebuilt by `syncPlugins` when the reading lands.
    private var pluginsHost: NSStackView!
    /// The plugins card's last reading (`PluginInventory`), nil until the first one
    /// lands; the page shows a loading line meanwhile. Read again when it is older
    /// than a minute, so a plugin installed while Settings was closed shows up.
    private var plugins: [PluginInventory.Plugin]?
    private var pluginsReadAt: Date?
    private var pluginsReading = false
    private var copyExampleButton: NSButton!
    private var claudeQuotaBox: NSSwitch!
    private var quotaStatus: NSTextField!
    private var quotaCheck: NSButton!
    private var quotaToken: NSButton!
    private var quotaConnect: NSButton!
    private var rememberBox: NSSwitch!
    private var notifyApprovalsBox: NSSwitch!
    private var notifyFailuresBox: NSSwitch!
    private var notifyQuietBox: NSSwitch!
    private var autoUpdateBox: NSSwitch!

    private var sidebarItems: [SidebarItem] = []
    private var pageViews: [Page: NSView] = [:]
    private var pageHost: NSView!
    private(set) var page: Page = .general

    /// Lives in one place because the caption is rebuilt from scratch whenever macOS
    /// has something to say about authorization — two copies of it drifted once.
    static let notifyCaptionText =
        "Only for what wants an answer — nothing is announced just for finishing. "
        + "The summary waits until you have been away from the keyboard for two minutes."
    private var notifyCaption: NSTextField!
    private var rulesBox: NSSwitch!
    private var exportButton: NSButton!
    private var rulesPageButton: NSButton!
    private var rulesView: RulesView!
    private var notifySettingsButton: NSButton!
    private var notifyTestButton: NSButton!

    func show() {
        if window == nil { build() }
        cancelCaptures() // a stale recorder must not swallow keys after re-show
        // Only while this window is open: the quota's status has exactly one
        // reader, and a closure held past that would redraw a window nobody is
        // looking at.
        ClaudeQuota.shared.onStatus = { [weak self] in self?.syncQuota() }
        ClaudeWebQuota.shared.onStatus = { [weak self] in self?.syncQuota() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// The window on one page — what `agentbar://settings/<page>` opens. `nil`
    /// leaves it on whichever page it was last on, as `show()` does. Showing a page
    /// changes nothing on it; every switch there still waits for a click.
    func show(page: Page?) {
        show()
        if let page { select(page) }
    }

    /// The menu quick-toggle flips the same defaults this window shows; a visible
    /// stale checkbox would look like the click didn't land.
    func refreshIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    /// Every recorder, the launcher's included: a capture abandoned by clicking
    /// away keeps an app-wide key monitor swallowing keystrokes and every global
    /// shortcut suspended until something ends it.
    private func cancelCaptures() {
        for recorder in [allowRecorder, denyRecorder, launchRecorder] { recorder?.cancelCapture() }
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: SettingsChrome.sidebarWidth + SettingsChrome.contentWidth,
                                height: SettingsChrome.minWindowHeight),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        w.title = "AgentBar Settings"
        // The string stays, for the Window menu and for anything reading the
        // window aloud; the drawing does not. AppKit centres a title across the
        // whole window, and a third of this one is sidebar — see
        // `SettingsChrome.title`, which puts the page's name over the page.
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.center()

        buildControls()

        // ---- the sidebar ----
        sidebarItems = Page.allCases.map {
            SidebarItem(page: $0, target: self, action: #selector(pick(_:)))
        }
        let list = NSStackView(views: sidebarItems)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 4
        list.translatesAutoresizingMaskIntoConstraints = false
        for item in sidebarItems {
            item.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(list)

        // ---- the page ----
        pageHost = NSView()
        pageHost.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()          // top-down, like the island's row list
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(pageHost)
        scroll.documentView = doc

        // Not a CGColor assigned once: the page is white in one appearance and
        // near-black in the other, and a flattened colour keeps whichever was
        // current when the window was built.
        let content = SettingsSurface(fill: { .textBackgroundColor })
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)

        let root = NSView(frame: NSRect(x: 0, y: 0,
                                        width: SettingsChrome.sidebarWidth
                                            + SettingsChrome.contentWidth,
                                        height: SettingsChrome.minWindowHeight))
        root.addSubview(sidebar)
        root.addSubview(content)
        w.contentView = root

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: SettingsChrome.sidebarWidth),
            // Clear of the traffic lights and no further: the gap was wide enough
            // to read as a search field somebody forgot to put in.
            list.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 38),
            list.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 10),
            list.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -10),

            content.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            // Nothing is drawn in the band above the page — the sidebar's
            // selected row is what names it, the way System Settings does it.
            // The band is kept because the traffic lights are in it.
            scroll.topAnchor.constraint(equalTo: content.topAnchor,
                                        constant: SettingsChrome.titleBand
                                            + SettingsChrome.Space.page),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            doc.widthAnchor.constraint(equalTo: scroll.widthAnchor),
            pageHost.topAnchor.constraint(equalTo: doc.topAnchor),
            pageHost.leadingAnchor.constraint(equalTo: doc.leadingAnchor,
                                              constant: SettingsChrome.Space.page),
            pageHost.trailingAnchor.constraint(equalTo: doc.trailingAnchor,
                                               constant: -SettingsChrome.Space.page),
            pageHost.bottomAnchor.constraint(equalTo: doc.bottomAnchor,
                                             constant: -SettingsChrome.Space.page),
        ])

        for p in Page.allCases { pageViews[p] = buildPage(p) }
        window = w
        select(page)
        sizeToTallestPage()
        clampToScreen()
    }

    /// Every control, made once. Which page each one lands on is `buildPage`'s
    /// business, and what it means is the rest of this file's.
    private func buildControls() {
        soundsBox = SettingsChrome.toggle(target: self, action: #selector(toggleSounds))
        volumeSlider = NSSlider(value: 0.5, minValue: 0, maxValue: 1,
                                target: self, action: #selector(volumeChanged(_:)))
        volumeSlider.isContinuous = true
        volumeSlider.widthAnchor.constraint(equalToConstant: 168).isActive = true
        volumeSlider.setAccessibilityLabel("Sound volume")
        testButton = SettingsChrome.smallButton("Test", target: self, action: #selector(testClicked))
        volumeRow = NSStackView(views: [speakerGlyph("speaker.fill"), volumeSlider,
                                        speakerGlyph("speaker.wave.3.fill"), testButton])
        volumeRow.orientation = .horizontal
        volumeRow.alignment = .centerY
        volumeRow.spacing = 8
        volumeRow.setCustomSpacing(12, after: volumeRow.arrangedSubviews[2])
        soundFolderButton = SettingsChrome.smallButton("Open folder…", target: self,
                                                       action: #selector(openSoundFolder))
        soundFolderButton.toolTip = "~/.agentbar/sounds — a file named permission, question, "
            + "done or ack replaces that cue. Up to 2 MB and 3 seconds."
        soundPackStatus = SettingsChrome.caption("")

        hideIslandBox = SettingsChrome.toggle(target: self, action: #selector(toggleHideIsland))
        hideAwayBox = SettingsChrome.toggle(target: self, action: #selector(toggleHideAway))
        personalityBox = SettingsChrome.toggle(target: self, action: #selector(togglePersonality))
        modBandBox = SettingsChrome.toggle(target: self, action: #selector(toggleModBand))
        autoUpdateBox = SettingsChrome.toggle(target: self, action: #selector(toggleAutoUpdate))

        enableBox = SettingsChrome.toggle(target: self, action: #selector(toggleEnabled))
        launchBox = SettingsChrome.toggle(target: self, action: #selector(toggleLauncher))
        allowRecorder = ShortcutRecorder(defaultsKey: "allowHotKey", fallback: .defaultAllow)
        denyRecorder = ShortcutRecorder(defaultsKey: "denyHotKey", fallback: .defaultDeny)
        launchRecorder = ShortcutRecorder(defaultsKey: "launchHotKey", fallback: .defaultLaunch)
        for recorder in [allowRecorder!, denyRecorder!, launchRecorder!] {
            recorder.onCaptureChange = { [weak self, weak recorder] capturing in
                guard let self else { return }
                if capturing {
                    // One recorder at a time, and while recording the current combo
                    // must reach the recorder, not the Carbon hotkey — suspend,
                    // then re-register on the way out.
                    let others: [ShortcutRecorder?] = [self.allowRecorder, self.denyRecorder,
                                                       self.launchRecorder]
                    for other in others where other !== recorder { other?.cancelCapture() }
                    HotKeyCenter.shared.suspend()
                } else {
                    self.onChange?()
                }
            }
            recorder.rejectCombo = { [weak self, weak recorder] combo in
                // No two of them may share one chord. The type is spelled out
                // because implicitly-unwrapped optionals in a literal infer as
                // [AnyObject] on some toolchains and the member lookup then fails
                // only on the machine you are not building on.
                guard let self else { return false }
                let all: [ShortcutRecorder?] = [self.allowRecorder, self.denyRecorder,
                                                self.launchRecorder]
                return all.contains { $0 !== recorder && $0?.combo == combo }
            }
            recorder.onRecord = { [weak self] in self?.onChange?() }
        }

        // Off by default, and the ask for permission happens on the tick, never at
        // launch — see Notifier.start().
        notifyApprovalsBox = SettingsChrome.toggle(target: self,
                                                   action: #selector(toggleNotifications(_:)))
        notifyFailuresBox = SettingsChrome.toggle(target: self,
                                                  action: #selector(toggleNotifications(_:)))
        notifyQuietBox = SettingsChrome.toggle(target: self,
                                               action: #selector(toggleNotifications(_:)))
        notifyCaption = SettingsChrome.caption(Self.notifyCaptionText)
        // Telling someone where a switch lives is not the same as taking them there.
        // Shown only when macOS has actually refused, so it is never a button that
        // opens a pane with nothing to do in it.
        notifySettingsButton = SettingsChrome.smallButton("Open System Settings", target: self,
                                                          action: #selector(openNotificationSettings))
        notifySettingsButton.isHidden = true
        // Same affordance the Sounds section has, for the same reason: "is this
        // reaching me?" deserves an answer that isn't "wait for an agent to need
        // something". It also separates suppressed-by-Focus from broken, which from
        // the outside look identical.
        notifyTestButton = SettingsChrome.smallButton("Send a test", target: self,
                                                      action: #selector(sendTestNotification))
        notifyTestButton.toolTip = "Nothing appears? A Focus is probably on — macOS files "
            + "banners in Notification Center instead of showing them."

        claudeQuotaBox = SettingsChrome.toggle(target: self, action: #selector(toggleClaudeQuota))
        // Everywhere else a failed reading is silent, because an error message
        // where a number belongs is worse than an empty space. Here it is the
        // opposite: this is the switch that caused it, and a switch that does
        // nothing and says nothing cannot be told from a broken one.
        quotaStatus = SettingsChrome.caption("")
        quotaCheck = SettingsChrome.smallButton("Check now", target: self,
                                                action: #selector(checkQuotaNow))
        quotaCheck.toolTip = "Asks straight away instead of waiting for the next five-minute "
            + "turn — and it is the only thing that opens Claude Code's Keychain login, which "
            + "macOS guards with a password prompt. Nothing here raises that on its own."
        // For the machine whose sessions run under their own CLAUDE_CONFIG_DIR: the
        // CLI keeps that login somewhere AgentBar cannot read, and no amount of
        // asking politely changes it. A token handed over on purpose does.
        quotaToken = SettingsChrome.smallButton("Use a token…", target: self,
                                                action: #selector(editQuotaToken))
        // The one that needs no terminal and no permission dialog: claude.ai's
        // own login page, in a window of ours, and the session stays in
        // AgentBar's cookie store. See `ClaudeWeb`.
        quotaConnect = SettingsChrome.smallButton("Sign in to Claude…", target: self,
                                                  action: #selector(connectClaudeWeb))
        quotaConnect.toolTip = "Opens claude.ai's login page. The session stays in "
            + "AgentBar and is used for nothing but reading your usage."

        rememberBox = SettingsChrome.toggle(target: self, action: #selector(toggleRemember))
        rulesBox = SettingsChrome.toggle(target: self, action: #selector(toggleRules))
        exportButton = SettingsChrome.smallButton("Export…", target: self,
                                                  action: #selector(exportDecisions))
        rulesPageButton = SettingsChrome.smallButton("Open Rules", target: self,
                                                     action: #selector(showRulesPage))
        rulesView = RulesView()
        rulesView.onResize = { [weak self] in self?.refit() }
        rulesView.onNew = { [weak self] in self?.addRule() }
        rulesView.onEdit = { [weak self] rule in self?.addRule(RuleSheet.Prefill(rule)) }

        diagnostics = DiagnosticsView()
        diagnostics.onResize = { [weak self] in self?.refit() }
        configChangesButton = SettingsChrome.smallButton("Show changes…", target: self,
                                                         action: #selector(showConfigChanges))
        configChangesButton.toolTip = "What AgentBar wrote into each agent's settings, as a "
            + "diff, where it kept the file as it was — and what a re-install would change now."
        copyExampleButton = SettingsChrome.smallButton("Copy example", target: self,
                                                       action: #selector(copyAgentExample))
        copyExampleButton.toolTip = "A five-line wrapper that shows any command as a session while it runs."
        agentsHost = NSStackView()
        agentsHost.orientation = .vertical
        agentsHost.alignment = .leading
        agentsHost.translatesAutoresizingMaskIntoConstraints = false
        pluginsHost = NSStackView()
        pluginsHost.orientation = .vertical
        pluginsHost.alignment = .leading
        pluginsHost.spacing = SettingsChrome.Space.gap
        pluginsHost.translatesAutoresizingMaskIntoConstraints = false
    }

    private func buildPage(_ page: Page) -> NSView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = SettingsChrome.Space.gap
        column.translatesAutoresizingMaskIntoConstraints = false

        func add(_ views: [NSView]) {
            for v in views {
                column.addArrangedSubview(v)
                if v is NSTextField { continue }
                v.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        switch page {
        case .general:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("Play sounds for agent events",
                                       "A soft cue when a session needs approval, asks a "
                                       + "question, or finishes. Never while one is working.",
                                       control: soundsBox),
                    SettingsChrome.customRow(volumeRow),
                    // Quiet on purpose: one row and one line, in the card it
                    // belongs to, rather than a section of its own for something
                    // most people never touch.
                    SettingsChrome.row("Your own sounds", control: soundFolderButton),
                    SettingsChrome.noteRow(soundPackStatus),
                ]),
                SettingsChrome.card([
                    // One card for both ways the pill can step aside, and one line
                    // between them on how to call it back — the peek is what makes
                    // either switch safe in island-only mode.
                    SettingsChrome.row("Hide the island when nothing is running",
                                       "The pill slips away and returns with the next "
                                       + "session. Push the pointer up to the notch to "
                                       + "peek at it.",
                                       control: hideIslandBox),
                    SettingsChrome.row("Hide the island while you're away",
                                       "After three minutes without keyboard or mouse, "
                                       + "even with agents working. Anything waiting on "
                                       + "you keeps it up; the first touch brings it back.",
                                       control: hideAwayBox),
                    // In the island's card because it is the island's alone — the
                    // menu bar mark never moves for its own amusement.
                    SettingsChrome.row("Let the mascot react",
                                       "Island only: Clawd's eyes follow the pointer and "
                                       + "blink, a long task ends in a sparkle, and clicking "
                                       + "a row's mark pokes it instead of jumping to the "
                                       + "session. Never with Reduce Motion.",
                                       control: personalityBox),
                ]),
                SettingsChrome.card([
                    SettingsChrome.row("Install updates automatically",
                                       "AgentBar updates itself when nothing is waiting on you.",
                                       control: autoUpdateBox),
                ]),
            ])
        case .notifications:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("When an agent needs approval", control: notifyApprovalsBox),
                    SettingsChrome.row("When a session fails", control: notifyFailuresBox),
                    SettingsChrome.row("When everything goes quiet, and you're away",
                                       control: notifyQuietBox),
                ]),
                SettingsChrome.card([
                    SettingsChrome.noteRow(notifyCaption),
                    SettingsChrome.customRow(buttonRow([notifyTestButton, notifySettingsButton])),
                ]),
            ])
        case .shortcuts:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("Global Allow / Deny",
                                       "Answer the newest pending request from anywhere, "
                                       + "without opening the menu.", control: enableBox),
                    SettingsChrome.row("Allow", control: allowRecorder),
                    SettingsChrome.row("Deny", control: denyRecorder),
                ]),
                SettingsChrome.card([
                    SettingsChrome.row("Launcher",
                                       "A project you have worked in, an agent, and what you "
                                       + "want it to do. The menu opens it either way.",
                                       control: launchBox),
                    SettingsChrome.row("Open the launcher", control: launchRecorder),
                ]),
            ])
        case .usage:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("Ask Anthropic for Claude's usage",
                                       "Claude keeps its percentages on its own servers. Sign "
                                       + "in once and AgentBar asks every five minutes — the "
                                       + "only network call it makes besides checking for "
                                       + "updates.",
                                       control: claudeQuotaBox),
                    SettingsChrome.noteRow(quotaStatus),
                    SettingsChrome.customRow(buttonRow([quotaConnect, quotaCheck, quotaToken])),
                ]),
                SettingsChrome.header("Codex and Copilot need none of this — both are read "
                                      + "off this Mac."),
            ])
        case .approvals:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("Remember what I decided",
                                       "So a prompt you have answered before can say so: "
                                       + "“Allowed 23× here”, and so a rule can be offered "
                                       + "from it.",
                                       control: rememberBox),
                    SettingsChrome.row("Rules",
                                       "What AgentBar may answer on your behalf lives on its "
                                       + "own page.",
                                       control: rulesPageButton),
                    SettingsChrome.row("Export the record",
                                       "Every decision, with its time, the directory, what was "
                                       + "asked and who answered — as a spreadsheet you can "
                                       + "hand to somebody who was not there.",
                                       control: exportButton),
                ]),
                SettingsChrome.header("Kept in ~/.agentbar/decisions.jsonl, on this Mac and "
                                      + "sent nowhere; `agentbar forget` empties it. It is "
                                      + "also what a rule is offered from, so switching it "
                                      + "off means no prompt ever offers one. What a rule "
                                      + "answers is written down either way."),
            ])
        case .claudeCode:
            add([
                // Everything that answers for you inside Claude Code, where AgentBar
                // is never asked: what it decided itself, and the plugins that can.
                // One vendor's page, because these are one vendor's mechanisms — the
                // Agents page stays a list of every tool, not a tour of one.
                SettingsChrome.card([SettingsChrome.customRow(AnsweredWithoutYouView())]),
                SettingsChrome.card([
                    SettingsChrome.row("Show other agents waiting, above Claude Code's prompt",
                                       "One line inside Claude Code while another session "
                                       + "needs you, with a key to jump to it. Never answers "
                                       + "it. Needs the Claude Code mod.",
                                       control: modBandBox),
                ]),
                pluginsHost,
            ])
        case .rules:
            add([
                SettingsChrome.card([
                    SettingsChrome.row("Answer from my rules",
                                       "Off stops every rule at once and deletes none. A rule "
                                       + "set to Watching never answers either way.",
                                       control: rulesBox),
                ]),
                SettingsChrome.card([SettingsChrome.customRow(rulesView)]),
                SettingsChrome.header("A rule answers a prompt the way you would have — and "
                                      + "only what you wrote. An approving rule names one "
                                      + "directory, and the command is read again before it "
                                      + "is answered: anything chained, elevated, destructive, "
                                      + "reaching off this Mac, or touching how permission "
                                      + "itself is set up always comes back to you. Kept in "
                                      + "~/.agentbar/rules.json; `agentbar rules` lists them."),
            ])
        case .agents:
            add([
                // One switch per agent, the record of what those switches — and
                // every launch — wrote, and the agents nobody had to wire. All three
                // answer "which of my tools does AgentBar see, and what did it do to
                // them", so they are one page.
                agentsHost,
                SettingsChrome.header("Before AgentBar writes into an agent's settings it "
                                      + "keeps the file as it was, beside it. Switching an "
                                      + "agent off takes out only AgentBar's own entries; "
                                      + "sessions already running keep their hooks until "
                                      + "they end."),
            ])
        case .diagnostics:
            add([
                SettingsChrome.card([SettingsChrome.customRow(diagnostics)]),
                SettingsChrome.header("Why an agent isn't showing up: hooks wired, the node "
                                      + "they point at still there, folders writable. "
                                      + "Settings ▸ Agents switches each one on or off."),
            ])
        }
        return column
    }

    private func buttonRow(_ buttons: [NSButton]) -> NSStackView {
        let row = NSStackView(views: buttons)
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    @objc private func pick(_ sender: SidebarItem) {
        select(sender.page)
    }

    private func select(_ page: Page) {
        self.page = page
        window?.title = page.title
        for item in sidebarItems { item.isSelected = item.page == page }
        for sub in pageHost.subviews { sub.removeFromSuperview() }
        guard let view = pageViews[page] else { return }
        pageHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: pageHost.topAnchor),
            view.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor),
        ])
        window?.contentView?.needsDisplay = true
    }

    /// The window is a fixed shape now, so "refit" means: keep it on the screen,
    /// and let the page scroll if a page is taller than it. Diagnostics still
    /// changes height as checks come and go; that is the scroller's problem, not
    /// the window's.
    private func refit() {
        // Diagnostics changes height as checks come and go, and it is usually the
        // tallest page — so the window is re-measured, not just nudged back onto
        // the screen.
        sizeToTallestPage()
        clampToScreen()
        window?.contentView?.needsDisplay = true
    }

    /// One height for every page: the tallest one's. Sizing per page would make
    /// the window jump on every click of the sidebar, and sizing to a constant
    /// leaves whichever page is shortest sitting above a field of nothing — which
    /// is what "it's huge" was about.
    private func sizeToTallestPage() {
        guard let window else { return }
        let tallest = pageViews.values.map { view -> CGFloat in
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }.max() ?? 0
        // What the page itself does not measure: the band above it, the margin
        // under that, and its own bottom margin inside the scroller. Guessed at
        // twice the page margin before, which was 28 points short — enough to put
        // a scroller on the tallest page for no reason anybody could see.
        let chrome = SettingsChrome.titleBand + SettingsChrome.Space.page * 2
        let height = min(max(tallest + chrome, SettingsChrome.minWindowHeight),
                         SettingsChrome.maxWindowHeight)
        window.setContentSize(NSSize(width: window.frame.width, height: height))
    }

    private func clampToScreen() {
        guard let window else { return }
        if let visible = window.screen?.visibleFrame, window.frame.height > visible.height - 40 {
            window.setContentSize(NSSize(width: window.frame.width,
                                         height: max(SettingsChrome.minWindowHeight,
                                                     visible.height - 40)))
        }
        guard let visible = window.screen?.visibleFrame else { return }
        var frame = window.frame
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.origin != window.frame.origin { window.setFrameOrigin(frame.origin) }
    }

    private func reload() {
        enableBox.state = UserDefaults.standard.bool(forKey: "globalApprovalShortcut") ? .on : .off
        launchBox.state = LauncherPanel.shortcutEnabled ? .on : .off
        allowRecorder.reload()
        denyRecorder.reload()
        launchRecorder.reload()
        soundsBox.state = SoundCenter.enabled ? .on : .off
        volumeSlider.doubleValue = SoundCenter.volume
        hideIslandBox.state = IslandVisibility.Prefs.hideWhenEmpty ? .on : .off
        hideAwayBox.state = IslandVisibility.Prefs.hideWhenAway ? .on : .off
        personalityBox.state = MascotPersonality.Prefs.enabled ? .on : .off
        modBandBox.state = ModBandPrefs.isOn() ? .on : .off
        autoUpdateBox.state = UpdateChecker.shared.autoUpdate ? .on : .off
        claudeQuotaBox.state = ClaudeQuota.enabled ? .on : .off
        syncQuota()
        rememberBox.state = DecisionLedger.enabled ? .on : .off
        rulesBox.state = RulesStore.enabled ? .on : .off
        rulesView.reload()
        notifyApprovalsBox.state = Notifier.Prefs.approvals ? .on : .off
        notifyFailuresBox.state = Notifier.Prefs.failures ? .on : .off
        notifyQuietBox.state = Notifier.Prefs.quiet ? .on : .off
        notifyTestButton.isEnabled = Notifier.Prefs.anyEnabled
        syncNotificationCaption()
        // Re-run on every show: the answer changes with what the user did outside
        // this window — installed an agent, upgraded node, granted Accessibility.
        diagnostics.refresh()
        syncAgents()
        syncRecorderState()
        syncSoundControls()
        syncSoundPack()
    }

    @objc private func toggleLauncher() {
        LauncherPanel.shortcutEnabled = launchBox.state == .on
        if launchBox.state == .off { launchRecorder.cancelCapture() }
        syncRecorderState()
        onChange?()
    }

    /// Switching it on asks for the number now rather than in five minutes — a
    /// switch that appears to do nothing for the first tick reads as broken. macOS
    /// raises its own Keychain prompt on that first attempt; a refusal there simply
    /// means no reading, the local token line stays, and the line under the switch
    /// says which of those happened.
    @objc private func toggleClaudeQuota() {
        ClaudeQuota.enabled = claudeQuotaBox.state == .on
        if ClaudeQuota.enabled {
            // Not deliberate: switching this on asks with whatever needs no
            // permission — a signed-in session, a pasted token, a login already
            // allowed once. Claude Code's Keychain record waits for the button.
            ClaudeQuota.shared.checkNow(deliberate: false) { UsageCenter.shared.refresh() }
        }
        UsageCenter.shared.refresh()
        syncQuota()
        onChange?()
    }

    /// Signing in, and signing out again — the same button, because a person who
    /// has connected an account wants the way back more than they want the way
    /// in, and two buttons where one will do is how a settings pane fills up.
    @objc private func connectClaudeWeb() {
        guard !ClaudeWeb.connected else {
            ClaudeWeb.signOut { [weak self] in
                UsageCenter.shared.refresh()
                self?.syncQuota()
            }
            return
        }
        ClaudeWebLogin.shared.show { [weak self] in
            // A sign-in is worth switching the feature on: nobody signs in to a
            // thing they meant to leave off.
            ClaudeQuota.enabled = true
            self?.claudeQuotaBox.state = .on
            ClaudeWebQuota.shared.checkNow { UsageCenter.shared.refresh() }
            self?.syncQuota()
            self?.onChange?()
        }
    }

    @objc private func checkQuotaNow() {
        ClaudeQuota.shared.checkNow { UsageCenter.shared.refresh() }
        ClaudeWebQuota.shared.checkNow { UsageCenter.shared.refresh() }
        syncQuota()
    }

    /// The status line and the button that re-runs it. Called on every reload and
    /// from `ClaudeQuota`'s own callback, so the sentence is never older than the
    /// attempt it describes.
    @objc private func editQuotaToken() {
        let stored = ClaudeQuota.storedToken() != nil
        let alert = NSAlert()
        alert.messageText = stored ? "Replace the token AgentBar is using?"
                                   : "Use a token of your own"
        alert.informativeText =
            "Run `claude setup-token` in a terminal and paste what it prints. It is kept in "
            + "AgentBar's own Keychain item — the only secret this app stores — and used for "
            + "nothing but the five-minute request to api.anthropic.com for your quota.\n\n"
            + "You need this only when Claude Code signs in under its own CLAUDE_CONFIG_DIR, "
            + "because that login is kept where AgentBar cannot read it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.placeholderString = "sk-ant-…"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if stored { alert.addButton(withTitle: "Remove") }
        alert.window.initialFirstResponder = field

        let answer = alert.runModal()
        switch answer {
        case .alertFirstButtonReturn:
            let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !typed.isEmpty else { return }
            ClaudeQuota.setStoredToken(typed)
        case .alertThirdButtonReturn:
            ClaudeQuota.setStoredToken(nil)
        default:
            return
        }
        // Whatever changed, find out now rather than at the next five-minute turn:
        // the sentence under the switch is the only feedback this has.
        if ClaudeQuota.enabled {
            // A token was just pasted or just removed; neither is a reason to
            // knock on the CLI's Keychain record.
            ClaudeQuota.shared.checkNow(deliberate: false) { UsageCenter.shared.refresh() }
        }
        syncQuota()
    }

    private func syncQuota() {
        quotaCheck.isEnabled = ClaudeQuota.enabled
        quotaToken.title = ClaudeQuota.storedToken() != nil ? "Replace token…" : "Use a token…"
        quotaConnect.title = ClaudeWeb.connected ? "Sign out" : "Sign in to Claude…"
        // Whichever door is actually in use is the one whose news this is.
        let status = ClaudeWeb.connected ? ClaudeWebQuota.shared.status : ClaudeQuota.shared.status
        let sentence = ClaudeQuota.sentence(for: status)
        guard quotaStatus.stringValue != sentence else { return }
        quotaStatus.stringValue = sentence
        // A longer sentence is a taller label, and the row is sized to what was
        // measured — not to what the label thinks it needs.
        quotaStatus.fittedHeight?.constant = SettingsChrome.measure(
            quotaStatus, width: SettingsChrome.cardWidth - SettingsChrome.rowInset * 2)
    }

    /// Switching it off stops new rows; it does not delete the old ones, because
    /// silently destroying something somebody might want is not what a checkbox
    /// does. `agentbar forget` is the thing that empties it, and it says so.
    @objc private func toggleRemember() {
        DecisionLedger.enabled = rememberBox.state == .on
        onChange?()
    }

    /// The master switch. Off means no rule fires and none is deleted — the list
    /// stays exactly as it was, which is the difference between "pause" and the
    /// thing people are afraid a switch will do.
    /// Writes the ledger out as CSV. A save panel rather than a fixed path: this is
    /// the user's own record, and where it goes is their decision like everything
    /// else about it.
    @objc private func exportDecisions() {
        let rows = DecisionLedger.read()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "agentbar-approvals.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.message = rows.isEmpty
            ? "Nothing has been decided yet — this writes the column headings only."
            : "\(rows.count) decision\(rows.count == 1 ? "" : "s") from ~/.agentbar/decisions.jsonl."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try DecisionLedger.csv(rows).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                guard let window = self?.window else { return }
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    @objc private func showRulesPage() { select(.rules) }

    @objc private func showConfigChanges() {
        guard let window else { return }
        ConfigChangesSheet.present(on: window)
    }

    /// The Agents card from scratch: one row per `Diagnostics.integrations`, a switch
    /// on each (disabled where the agent is not installed), and the changes row last.
    private func syncAgents() {
        let off = WiringPrefs.effectiveDisabled()
        let history = HistoryStore.read()
        let last = AgentsPage.lastSessions(history)
        let now = Date().timeIntervalSince1970
        var rows: [NSView] = Diagnostics.integrations.map { i in
            let present = i.isPresent()
            let toggle = SettingsChrome.toggle(target: self, action: #selector(toggleAgent(_:)))
            toggle.identifier = NSUserInterfaceItemIdentifier(i.id)
            toggle.state = present && !off.contains(i.id) ? .on : .off
            toggle.isEnabled = present
            toggle.setAccessibilityLabel("Wire AgentBar into \(i.name)")
            // The mod's line is a sentence, not a status: it is the one switch that
            // starts off, so the line says what turning it on buys. It goes under
            // the name, where a sentence fits, rather than beside the switch.
            if i.id == ClaudeModWiring.id {
                // The cheap reading only: `claude --version` is not run on the main
                // queue, and an unknown version does not block (an older Claude
                // Code ignores the setting).
                let supported = ClaudeModWiring.supports(ClaudeQuota.installedCLIVersion())
                toggle.isEnabled = present && supported
                if !supported { toggle.state = .off }
                return SettingsChrome.row(i.name, AgentsPage.modState(
                    present: present, supported: supported, off: off.contains(i.id),
                    lastReport: ClaudeModWiring.newestReport(), now: now), control: toggle)
            }
            // The state beside the switch rather than under the name: one line a
            // row keeps eight agents a card, not a page.
            let state = NSTextField(labelWithString: AgentsPage.state(
                present: present, off: off.contains(i.id), lastSession: last[i.id], now: now))
            state.font = .systemFont(ofSize: 11.5)
            state.textColor = .secondaryLabelColor
            let control = NSStackView(views: [state, toggle])
            control.orientation = .horizontal
            control.alignment = .centerY
            control.spacing = SettingsChrome.Space.tight
            return SettingsChrome.row(i.name, control: control)
        }
        // No subtitle: `captionWidth` leaves room for a switch, not for a button
        // this wide, and the page's footnote says the rest.
        rows.append(SettingsChrome.row("Changes to your agents' settings", control: configChangesButton))
        for old in agentsHost.arrangedSubviews { old.removeFromSuperview() }
        let note = NSTextField(wrappingLabelWithString: AgentsPage.ownAgentsNote(AgentsPage.ownAgents(history)))
        let own = SettingsChrome.card([
            SettingsChrome.row("Your own agent",
                               "Any tool can report itself with `agentbar report` and appear "
                               + "with its own name. Nothing to wire, no switch.",
                               control: copyExampleButton),
            SettingsChrome.noteRow(note),
        ])
        for view in [SettingsChrome.card(rows), own] {
            agentsHost.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: agentsHost.widthAnchor).isActive = true
        }
        syncPlugins()
        refreshPluginsIfStale()
    }

    /// The Claude Code page's plugin card, from the last reading.
    private func syncPlugins() {
        for old in pluginsHost.arrangedSubviews { old.removeFromSuperview() }
        for view in [SettingsChrome.header(AgentsPage.pluginsTitle), SettingsChrome.card(pluginRows()),
                     SettingsChrome.caption(AgentsPage.pluginsFootnote)] {
            pluginsHost.addArrangedSubview(view)
            if view is NSTextField { continue }
            view.widthAnchor.constraint(equalTo: pluginsHost.widthAnchor).isActive = true
        }
    }

    /// One row per plugin that can answer Claude Code's prompts, then a dim line
    /// naming everything else that is loaded — or the loading line, or the empty one.
    private func pluginRows() -> [NSView] {
        guard let plugins else {
            return [SettingsChrome.noteRow(SettingsChrome.caption(AgentsPage.pluginsLoading))]
        }
        let answering = plugins.filter(\.canAnswer)
        let showDirs = AgentsPage.showsDirs(plugins)
        var rows: [NSView] = answering.map { p in
            SettingsChrome.row(p.name, AgentsPage.pluginDetail(p, showDirs: showDirs),
                               control: pluginBadge(AgentsPage.pluginBadge(p)))
        }
        if answering.isEmpty {
            rows.append(SettingsChrome.noteRow(NSTextField(wrappingLabelWithString: AgentsPage.pluginsEmpty)))
        }
        if let rest = AgentsPage.alsoLoaded(plugins) {
            rows.append(SettingsChrome.noteRow(SettingsChrome.caption(rest)))
        }
        return rows
    }

    /// A small rounded tag, quiet enough to sit where a switch would.
    private func pluginBadge(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        let box = NSStackView(views: [label])
        box.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        box.wantsLayer = true
        box.layer?.cornerRadius = 5
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        return box
    }

    /// Reads the plugins off the main queue — `claude plugin validate` may take a
    /// few seconds per mod the first time — and redraws the page when it lands.
    private func refreshPluginsIfStale() {
        guard !pluginsReading, (pluginsReadAt.map { Date().timeIntervalSince($0) > 60 } ?? true) else { return }
        pluginsReading = true
        PluginInventory.load { [weak self] found in
            guard let self else { return }
            self.plugins = found
            self.pluginsReadAt = Date()
            self.pluginsReading = false
            self.syncPlugins()
        }
    }

    /// The wrapper from `AgentsPage.example`, on the clipboard. The button says so
    /// for a moment rather than opening anything.
    @objc private func copyAgentExample() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AgentsPage.example, forType: .string)
        copyExampleButton.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.copyExampleButton.title = "Copy example"
        }
    }

    /// A switch is a request, not the change: it opens the changes sheet on what
    /// switching would write, and only **Apply** writes it. Cancel puts it back.
    @objc private func toggleAgent(_ sender: NSSwitch) {
        guard let window, let id = sender.identifier?.rawValue,
              let i = Diagnostics.integrations.first(where: { $0.id == id }) else { return }
        let wire = sender.state == .on
        ConfigChangesSheet.present(on: window, agent: id, name: i.name, wire: wire) { [weak self] applied in
            guard let self else { return }
            self.syncAgents()
            if applied { self.diagnostics.refresh() }
        }
    }

    @objc private func toggleRules() {
        RulesStore.enabled = rulesBox.state == .on
        onChange?()
    }

    /// One rule, written in a sheet. A rule that comes back carrying an id already
    /// in the file replaces it; anything else is appended. That is the whole of
    /// "edit": the sheet does not need to know which it is doing.
    private func addRule(_ prefill: RuleSheet.Prefill = RuleSheet.Prefill()) {
        guard let window else { return }
        RuleSheet.present(on: window, prefill: prefill) { [weak self] rule in
            guard let self, let rule else { return }
            if !RulesStore.put(rule), case .invalid(let reason) = RulesStore.load() {
                // Said where the person is looking, not only in Diagnostics: the
                // rule they just wrote did not land, and they need to know why.
                let alert = NSAlert()
                alert.messageText = "The rule was not saved"
                alert.informativeText = "~/.agentbar/rules.json has a mistake in it, so AgentBar "
                    + "left the file exactly as it is rather than write over your rules: "
                    + reason + " Fix it there, then add the rule again."
                alert.beginSheetModal(for: window)
            }
            rulesView.reload()
        }
    }

    /// From a pending approval card: the same sheet, already filled in with what is
    /// on screen. The person still presses the button — an offer is not consent,
    /// and this is the only difference between a rule and the count beside it.
    func addRule(from prefill: RuleSheet.Prefill) {
        show()
        select(.rules)
        addRule(prefill)
    }

    @objc private func toggleEnabled() {
        UserDefaults.standard.set(enableBox.state == .on, forKey: "globalApprovalShortcut")
        syncRecorderState()
        onChange?()
    }

    /// Turning either switch on asks macOS for permission the first time. A refusal
    /// un-ticks the box rather than leaving a setting that quietly does nothing, and
    /// the caption says where to change your mind.
    @objc private func toggleNotifications(_ sender: NSSwitch) {
        let turningOn = sender.state == .on
        // One selector, three boxes: the sender says which preference it owns, so
        // adding a channel is a line here rather than a fourth near-identical method.
        let write: (Bool) -> Void = { [weak self] on in
            guard let self else { return }
            switch sender {
            case self.notifyApprovalsBox: Notifier.Prefs.approvals = on
            case self.notifyFailuresBox: Notifier.Prefs.failures = on
            default: Notifier.Prefs.quiet = on
            }
        }
        write(turningOn)

        if turningOn {
            Notifier.shared.requestAuthorization { [weak self] granted, error in
                guard let self else { return }
                // The refusal has to SAY something. Springing the box back with an
                // unchanged caption is indistinguishable from a dead control, which
                // is how this shipped the first time and how it was reported.
                Notifier.shared.authorizationStatus { [weak self] status in
                    guard let self else { return }
                    self.notificationProblem = Notifier.problem(granted: granted, error: error,
                                                                status: status)
                    if !granted {
                        write(false)
                        sender.state = .off
                    }
                    self.syncNotificationCaption()
                }
            }
        } else if sender === notifyApprovalsBox {
            // A banner already on screen must not outlive the setting that allowed it.
            Notifier.shared.withdrawAll()
        }
        notifyTestButton.isEnabled = Notifier.Prefs.anyEnabled
        onChange?()
    }

    /// Set when macOS last refused, and shown until it stops being true. Kept
    /// separate from the preferences: the refusal turns them back off, so a caption
    /// that keyed off "is anything enabled" would erase its own explanation.
    private var notificationProblem: String?

    /// Straight to the pane, not to a search box. The URL is the Notifications
    /// settings extension; if a future macOS renames it, the caption still says
    /// where to go by hand, so the worst case is a button that does nothing rather
    /// than instructions that are wrong.
    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func sendTestNotification() {
        Notifier.shared.preview()
    }

    private func syncNotificationCaption() {
        let base = Self.notifyCaptionText
        if let notificationProblem {
            notifyCaption.stringValue = notificationProblem
            notifyCaption.textColor = .systemOrange
            notifySettingsButton.isHidden = false
            refit()
            return
        }
        notifyCaption.textColor = .secondaryLabelColor
        notifySettingsButton.isHidden = true
        // Nothing switched on, nothing refused: there is no authorization state worth
        // reporting yet, and asking for it would be a round trip for no reason.
        guard Notifier.Prefs.anyEnabled else { notifyCaption.stringValue = base; refit(); return }
        Notifier.shared.authorizationStatus { [weak self] status in
            guard let self else { return }
            let problem = Notifier.problem(granted: false, error: nil, status: status)
            self.notifyCaption.stringValue = problem ?? base
            self.notifyCaption.textColor = problem == nil ? .secondaryLabelColor : .systemOrange
            self.notifySettingsButton.isHidden = problem == nil
            self.refit()
        }
    }

    @objc private func toggleSounds() {
        SoundCenter.enabled = soundsBox.state == .on
        syncSoundControls()
        if SoundCenter.enabled { SoundCenter.shared.preview() }
        onChange?()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        SoundCenter.volume = sender.doubleValue
        // Audition on release, not per tick — matches the system alert-volume slider.
        if NSApp.currentEvent?.type == .leftMouseUp { SoundCenter.shared.preview() }
    }

    @objc private func testClicked() {
        SoundCenter.shared.preview()
    }

    /// Creates the folder if it is not there yet and opens it in Finder. That is
    /// all it does: what goes in it is the person's, and the line under the button
    /// says what AgentBar made of it the next time this window comes forward.
    @objc private func openSoundFolder() {
        let dir = SoundPack.directory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
            return
        }
        NSWorkspace.shared.open(dir)
    }

    /// Which cues are the user's, and which files were passed over and why. Re-read
    /// whenever the window comes forward, because the change it reports is made in
    /// Finder, behind this window's back.
    private func syncSoundPack() {
        let sentence = SoundPack.summary(SoundPack.listing())
        guard soundPackStatus.stringValue != sentence else { return }
        soundPackStatus.stringValue = sentence
        // Same as the quota line: a longer sentence is a taller label, and the row
        // follows what was measured.
        soundPackStatus.fittedHeight?.constant = SettingsChrome.measure(
            soundPackStatus, width: SettingsChrome.cardWidth - SettingsChrome.rowInset * 2)
    }

    @objc private func toggleHideIsland() {
        IslandVisibility.Prefs.hideWhenEmpty = hideIslandBox.state == .on
        onChange?()
    }

    @objc private func toggleHideAway() {
        IslandVisibility.Prefs.hideWhenAway = hideAwayBox.state == .on
        onChange?()
    }

    @objc private func toggleAutoUpdate() {
        UpdateChecker.shared.autoUpdate = autoUpdateBox.state == .on
        onChange?()
    }

    /// Written to the file the mod reads; a running Claude Code session picks it up
    /// within half a minute, a new one at once.
    @objc private func toggleModBand() {
        do { try ModBandPrefs.set(modBandBox.state == .on) }
        catch { modBandBox.state = ModBandPrefs.isOn() ? .on : .off }
    }

    @objc private func togglePersonality() {
        MascotPersonality.Prefs.enabled = personalityBox.state == .on
        onChange?()
    }

    private func syncRecorderState() {
        let on = enableBox.state == .on
        allowRecorder.isEnabled = on
        denyRecorder.isEnabled = on
        launchRecorder.isEnabled = launchBox.state == .on
    }

    private func syncSoundControls() {
        let on = soundsBox.state == .on
        volumeSlider.isEnabled = on
        testButton.isEnabled = on
        volumeRow.alphaValue = on ? 1 : 0.5 // dims the glyphs too; NSImageView has no isEnabled
    }

    func windowWillClose(_ notification: Notification) {
        cancelCaptures()
        ClaudeQuota.shared.onStatus = nil
        ClaudeWebQuota.shared.onStatus = nil
    }

    /// Clicking away mid-recording: a background window can't see key events, so a
    /// still-armed recorder would leave the hotkeys suspended forever. End it now.
    func windowDidResignKey(_ notification: Notification) {
        cancelCaptures()
    }

    /// Back from Finder with a file dropped in: say what it did.
    func windowDidBecomeKey(_ notification: Notification) {
        syncSoundPack()
    }

    private func speakerGlyph(_ symbol: String) -> NSImageView {
        let v = NSImageView()
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
        v.contentTintColor = .secondaryLabelColor
        return v
    }

}

/// A button that shows the current combo and, when clicked, records the next
/// keystroke as the new one. Esc cancels; a combo needs ⌘, ⌥ or ⌃ so a plain
/// letter typed anywhere can never become a global hotkey.
// MARK: - Offline verification

extension SettingsWindow {
    /// Renders the whole settings sheet to a PNG, all sections at once, without
    /// opening it.
    ///
    /// The precedent is `UsageMeterView.renderForVerification`, and the reason is
    /// the same: this window is the one surface that cannot be looked at while it
    /// is being changed — it opens over the work, a screenshot of it needs a human
    /// with a mouse, and it is long enough that the broken part is usually
    /// scrolled out of sight. A single unwrapped label once stretched it to 1900 pt
    /// and pushed two sections off the right edge; nothing in the build said a
    /// word, and a picture would have.
    /// One page at its true size, for reading rather than for the overview.
    func renderPageForVerification(_ page: Page, to url: URL) -> Bool {
        if window == nil { build() }
        reload()
        select(page)
        // The frame view, not the content view: the title bar is where the bug
        // that needed looking at lived, and a render that crops it off cannot
        // show whether anything is drawn there. Falls back to the content view
        // on any AppKit that does not hand the frame over.
        guard let root = window?.contentView?.superview ?? window?.contentView
        else { return false }
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    /// Where a page's sidebar entry sits in the same root `renderPageForVerification`
    /// draws, bottom-left origin, points — so the demo generator can put a pointer
    /// on it. Nil before the window has been built.
    func sidebarFrame(of page: Page) -> NSRect? {
        guard let root = window?.contentView?.superview ?? window?.contentView,
              let item = sidebarItems.first(where: { $0.page == page }) else { return nil }
        var r = item.convert(item.bounds, to: root)
        if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
        return r
    }

    func renderForVerification(to url: URL) -> Bool {
        if window == nil { build() }
        reload()
        guard let window else { return false }
        // Every page side by side, so one picture is the whole window rather than
        // whichever page happened to be selected.
        var shots: [(Page, NSBitmapImageRep)] = []
        for p in Page.allCases {
            select(p)
            window.contentView?.layoutSubtreeIfNeeded()
            guard let root = window.contentView,
                  let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds)
            else { continue }
            root.cacheDisplay(in: root.bounds, to: rep)
            shots.append((p, rep))
        }
        select(.general)
        guard let first = shots.first?.1 else { return false }
        let each = NSSize(width: CGFloat(first.pixelsWide) / 2,
                          height: CGFloat(first.pixelsHigh) / 2)
        let cols = 3
        let rows = (shots.count + cols - 1) / cols
        let gap: CGFloat = 16
        let size = NSSize(width: CGFloat(cols) * each.width + CGFloat(cols + 1) * gap,
                          height: CGFloat(rows) * each.height + CGFloat(rows + 1) * gap)
        let sheet = NSImage(size: size)
        sheet.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: size).fill()
        for (i, shot) in shots.enumerated() {
            let col = CGFloat(i % cols), row = CGFloat(i / cols)
            let origin = NSPoint(x: gap + col * (each.width + gap),
                                 y: size.height - (row + 1) * (each.height + gap))
            shot.1.draw(in: NSRect(origin: origin, size: each))
        }
        sheet.unlockFocus()
        guard let tiff = sheet.tiffRepresentation,
              let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { return false }
        return (try? data.write(to: url)) != nil
    }
}

final class ShortcutRecorder: NSButton {
    private let defaultsKey: String
    private let fallback: KeyCombo
    private(set) var combo: KeyCombo
    var onRecord: (() -> Void)?
    var onCaptureChange: ((Bool) -> Void)?
    var rejectCombo: ((KeyCombo) -> Bool)?
    private var monitor: Any?

    init(defaultsKey: String, fallback: KeyCombo) {
        self.defaultsKey = defaultsKey
        self.fallback = fallback
        self.combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginCapture)
        // A chord is a value, not a text field: it takes the width the longest one
        // needs and stops there. Left to stretch inside a row it becomes a 250 pt
        // grey slab with three glyphs floating in the middle of it.
        let width = widthAnchor.constraint(equalToConstant: 104)
        width.priority = .defaultHigh   // yields while "Type shortcut…" is showing
        width.isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true
        reload()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func reload() {
        combo = KeyCombo.stored(defaultsKey, fallback: fallback)
        title = combo.display
    }

    @objc private func beginCapture() {
        guard monitor == nil else { return }
        title = "Type shortcut… (esc cancels)"
        onCaptureChange?(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event)
            return nil // swallow the keystroke while recording
        }
    }

    func cancelCapture() {
        // Only a live capture may end — a plain call must not re-fire
        // onCaptureChange(false) and needlessly re-register the hotkeys.
        if monitor != nil { endCapture() }
    }

    private func endCapture() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        title = combo.display
        onCaptureChange?(false)
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt32(kVK_Escape) { endCapture(); return }
        let carbon = Self.carbonFlags(event.modifierFlags)
        guard carbon & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            NSSound.beep()
            return // keep capturing until a real combo (or esc) arrives
        }
        let recorded = KeyCombo(keyCode: UInt32(event.keyCode), carbonModifiers: carbon,
                                display: Self.display(for: event))
        if rejectCombo?(recorded) == true {
            NSSound.beep()
            return
        }
        combo = recorded
        combo.store(as: defaultsKey)
        endCapture()
        onRecord?()
    }

    private static func carbonFlags(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var c: UInt32 = 0
        if flags.contains(.control) { c |= UInt32(controlKey) }
        if flags.contains(.option) { c |= UInt32(optionKey) }
        if flags.contains(.shift) { c |= UInt32(shiftKey) }
        if flags.contains(.command) { c |= UInt32(cmdKey) }
        return c
    }

    private static func display(for event: NSEvent) -> String {
        var s = ""
        let f = event.modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyName(event)
    }

    private static func keyName(_ event: NSEvent) -> String {
        if let n = fKeyNumber(event.keyCode) { return "F\(n)" }
        switch Int(event.keyCode) {
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            return event.charactersIgnoringModifiers?.uppercased() ?? "?"
        }
    }

    private static func fKeyNumber(_ code: UInt16) -> Int? {
        let map: [Int: Int] = [kVK_F1: 1, kVK_F2: 2, kVK_F3: 3, kVK_F4: 4, kVK_F5: 5, kVK_F6: 6,
                               kVK_F7: 7, kVK_F8: 8, kVK_F9: 9, kVK_F10: 10, kVK_F11: 11, kVK_F12: 12]
        return map[Int(code)]
    }
}

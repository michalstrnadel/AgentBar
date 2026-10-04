import Cocoa

/// **Settings ▸ Approvals ▸ Answered without you**: what Claude Code ran or refused
/// on its own, before any prompt existed, as the AgentBar mod saw it — and on
/// whose say-so: one of your Claude Code rules, its permission mode, or a hook.
///
/// The other half of the record this page keeps. Every count elsewhere on the page
/// is about you; this one is the part of the day nobody asked you about, and it is
/// kept apart for the same reason rule rows are (`DecisionLedger.isPersonal`).
/// Read from `decisions.jsonl` (`via: "claude"`, written by `ClaudeDecisionIngest`),
/// never from the sidecars, so it says what was kept and nothing more.
enum AnsweredWithoutYou {
    struct Tally: Equatable {
        var allowed = 0
        var denied = 0
        var total: Int { allowed + denied }
    }

    struct Source: Equatable {
        var title: String
        var tally: Tally
    }

    struct ShapeCount: Equatable {
        var shape: String
        var count: Int
    }

    struct Model: Equatable {
        var today = Tally()
        var week = Tally()
        /// Rules first (most used, at most `maxRules`), then the mode, then hooks.
        var sources: [Source] = []
        var shapes: [ShapeCount] = []
        /// The whole card when there is nothing to count, and why.
        var empty: String?
    }

    static let maxRules = 5
    static let maxShapes = 3
    static let span: TimeInterval = 7 * 86_400

    static let modOffText = "Turn on the Claude Code mod in Settings ▸ Agents to see what "
        + "Claude Code runs without asking you."
    static let ledgerOffText = "Remember what I decided is off, so what Claude Code decides "
        + "on its own is not kept either."
    static let nothingText = "Nothing in the last 7 days that Claude Code settled before "
        + "a prompt was due."
    /// Said under every non-empty card. The mod looks before Claude Code's permission
    /// mode has its say, so what auto mode's classifier or don't-ask mode settles on an
    /// `ask` never reaches it — and a card that read as "everything that ran unasked"
    /// would be the confident wrong number this page exists to replace.
    static let blindSpotText = "Not counted: what auto mode or don't-ask mode decides "
        + "after Claude Code would have asked."

    /// The card's contents. `modInstalled` and `ledgerOn` only choose between the
    /// empty states: rows in the ledger are counted whatever they say now.
    static func model(_ records: [DecisionLedger.Record], modInstalled: Bool, ledgerOn: Bool,
                      now: Date = Date(), calendar: Calendar = .current) -> Model {
        let t = now.timeIntervalSince1970
        let dayStart = calendar.startOfDay(for: now).timeIntervalSince1970
        let weekStart = t - span
        var m = Model()
        var rules: [String: Tally] = [:]
        var mode = Tally(), hook = Tally()
        var shapes: [String: Int] = [:]
        for r in records where r.via == "claude" && r.ts >= weekStart && r.ts <= t {
            let allow = r.decision == "allow"
            guard allow || r.decision == "deny" else { continue }
            func add(_ x: inout Tally) { if allow { x.allowed += 1 } else { x.denied += 1 } }
            add(&m.week)
            if r.ts >= dayStart { add(&m.today) }
            switch r.by {
            case "rule": add(&rules[r.claudeRule.isEmpty ? "?" : r.claudeRule, default: Tally()])
            case "hook": add(&hook)
            default:     add(&mode)
            }
            if allow, !r.shape.isEmpty { shapes[r.shape, default: 0] += 1 }
        }
        guard m.week.total > 0 else {
            m.empty = !ledgerOn ? ledgerOffText : modInstalled ? nothingText : modOffText
            return m
        }
        let ranked = rules.sorted { ($0.value.total, $1.key) > ($1.value.total, $0.key) }
        for (rule, tally) in ranked.prefix(maxRules) {
            m.sources.append(Source(title: rule == "?" ? "A Claude Code rule"
                                                       : "Your Claude Code rule `\(rule)`",
                                    tally: tally))
        }
        if ranked.count > maxRules {
            var rest = Tally()
            for (_, tally) in ranked.dropFirst(maxRules) {
                rest.allowed += tally.allowed
                rest.denied += tally.denied
            }
            m.sources.append(Source(title: "\(ranked.count - maxRules) more of your rules", tally: rest))
        }
        if mode.total > 0 { m.sources.append(Source(title: "Claude Code's permission mode", tally: mode)) }
        if hook.total > 0 { m.sources.append(Source(title: "A hook or another mod", tally: hook)) }
        m.shapes = shapes.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(maxShapes).map { ShapeCount(shape: $0.key, count: $0.value) }
        return m
    }

    /// "38 run, 2 refused" — the verbs a person would use about commands.
    static func phrase(_ t: Tally) -> String {
        var parts: [String] = []
        if t.allowed > 0 { parts.append("\(t.allowed) run") }
        if t.denied > 0 { parts.append("\(t.denied) refused") }
        return parts.isEmpty ? "none" : parts.joined(separator: ", ")
    }

    /// The card as lines of text, top to bottom. Pure, so the wording is testable.
    static func lines(_ m: Model) -> [String] {
        if let empty = m.empty { return [empty] }
        var out = ["Today \(phrase(m.today)) · last 7 days \(phrase(m.week))"]
        for s in m.sources { out.append("\(s.title) — \(phrase(s.tally))") }
        if !m.shapes.isEmpty {
            out.append("Most often: " + m.shapes.map {
                "\(RulesView.readable($0.shape)) \($0.count)×"
            }.joined(separator: ", "))
        }
        out.append(blindSpotText)
        return out
    }

    /// Whether the mod has been installed here: its folder, or anything it wrote.
    static func modInstalled(root: URL = AgentBarHome.root()) -> Bool {
        let fm = FileManager.default
        for dir in ["mods", "mods.d"] {
            let names = (try? fm.contentsOfDirectory(
                atPath: root.appendingPathComponent(dir, isDirectory: true).path)) ?? []
            if names.contains(where: { !$0.hasPrefix(".") }) { return true }
        }
        return false
    }

    // MARK: - What Claude Code already allows

    /// For a rule of yours that approves a shape: the Claude Code settings rule that
    /// already allowed the same shape here in the last 7 days, most used first — so
    /// the rules list can say your rule is answering prompts Claude Code would not
    /// even show you. Nil when there is none, or the rule refuses.
    static func claudeAlreadyAllows(_ rule: RulesStore.Rule, in records: [DecisionLedger.Record],
                                    now: Date = Date()) -> String? {
        guard rule.isAllow else { return nil }
        let since = now.timeIntervalSince1970 - span
        var counts: [String: Int] = [:]
        for r in records where r.via == "claude" && r.decision == "allow" && r.by == "rule"
            && !r.claudeRule.isEmpty && r.ts >= since && r.shape == rule.shape
            && (rule.cwd.isEmpty || r.cwd == rule.cwd || r.cwd.hasPrefix(rule.cwd + "/")) {
            counts[r.claudeRule, default: 0] += 1
        }
        return counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    static func alreadyAllowsNote(_ claudeRule: String) -> String {
        "Claude Code already allows this itself (`\(claudeRule)`)"
    }
}

/// The card itself: a column of lines rebuilt from the ledger whenever the page
/// comes into view, so it is never older than the last look at it.
final class AnsweredWithoutYouView: NSView {
    private let column = NSStackView()
    private static let width = SettingsChrome.cardWidth - SettingsChrome.rowInset * 2
    private var lastLines: [String] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        // No margins of its own: `SettingsChrome.customRow` gives it the row's.
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reload()
    }

    required init?(coder: NSCoder) { nil }

    /// The page was shown, or the window came back to the front.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        guard let window else { return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey),
                                               name: NSWindow.didBecomeKeyNotification,
                                               object: window)
        reload()
    }

    @objc private func windowBecameKey() { reload() }

    func reload() {
        let model = AnsweredWithoutYou.model(DecisionLedger.cached(),
                                             modInstalled: AnsweredWithoutYou.modInstalled(),
                                             ledgerOn: DecisionLedger.enabled)
        let lines = AnsweredWithoutYou.lines(model)
        guard lines != lastLines else { return }
        lastLines = lines
        for v in column.arrangedSubviews { v.removeFromSuperview() }
        let title = NSTextField(labelWithString: "Answered without you")
        title.font = .systemFont(ofSize: 13.5)
        column.addArrangedSubview(title)
        column.setCustomSpacing(SettingsChrome.Space.hair, after: title)
        for (i, line) in lines.enumerated() {
            let l = NSTextField(wrappingLabelWithString: line)
            l.font = .systemFont(ofSize: 11.5)
            // The totals line in the primary colour when there is something to
            // count; everything else is detail under it.
            l.textColor = i == 0 && model.empty == nil ? .labelColor : .secondaryLabelColor
            l.isSelectable = false
            SettingsChrome.fit(l, to: Self.width)
            column.addArrangedSubview(l)
        }
    }
}

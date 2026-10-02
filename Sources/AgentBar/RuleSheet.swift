import Cocoa

/// The sheet that writes one rule.
///
/// Its real job is not collecting four fields — it is **making the rule's edges
/// visible** before somebody commits to it. A rule is matched by the ledger's
/// `shape`, which carries no arguments, so "allow `git push`" is a sentence whose
/// edges are not obvious from reading it. Two things answer that: a paragraph that
/// says what will never be answered, and a field where you type a real command and
/// are told, right there, whether this rule would have taken it and why not.
///
/// Summoned by a click and gone when it is answered — the same test the launcher
/// and the banners pass.
final class RuleSheet: NSObject {
    struct Prefill {
        /// Empty for a new rule. Set means this sheet is editing that rule, and the
        /// id travels back out unchanged so the caller replaces rather than appends.
        var id = ""
        var decision = "allow"
        var shape = ""
        var cwd = ""
        var note = ""
        var tell = ""
        var mode = RulesStore.Rule.Mode.watch
        /// What the request said, so the sheet can show the exact line the person
        /// was looking at rather than only its shape.
        var display = ""

        init() {}

        init(_ rule: RulesStore.Rule) {
            id = rule.id
            decision = rule.decision
            shape = rule.shape
            cwd = rule.cwd
            note = rule.note
            tell = rule.tell
            mode = rule.mode
        }

        init(decision: String, shape: String, cwd: String, display: String) {
            self.decision = decision
            self.shape = shape
            self.cwd = cwd
            self.display = display
        }
    }

    /// Common enough to be worth offering on a machine whose approval history is
    /// empty — which is every machine on the day AgentBar is installed. They are
    /// examples, not a recommendation: each one still has to be chosen, given a
    /// directory, and (for an approval) checked.
    static let commonShapes = [
        "bash:git status", "bash:git diff", "bash:git log", "bash:ls", "bash:cat",
        "bash:grep", "bash:rg", "bash:npm test", "bash:swift build", "bash:make",
        "bash:curl", "bash:rm",
    ]

    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 430),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let kind = NSSegmentedControl(labels: ["Allow", "Deny"], trackingMode: .selectOne,
                                          target: nil, action: nil)
    private let shape = NSComboBox()
    private let place = NSPopUpButton()
    private let mode = NSPopUpButton()
    private let note = NSTextField()
    private let tell = NSTextField()
    /// The "Tell it" row, shown only for a denial: an approval has nothing to explain.
    private var tellRow: NSView!
    private let tryField = NSTextField()
    private let tryResult = NSTextField(wrappingLabelWithString: "")
    private let consequence = NSTextField(wrappingLabelWithString: "")
    private var directories: [String] = []
    private var editingID = ""
    private var done: ((RulesStore.Rule?) -> Void)?
    /// Each sheet retained for its own life and released when *it* closes. One
    /// slot was not enough: the status menu stays usable while a sheet is up, so
    /// "Always allow this here…" can present a second sheet on Settings while the
    /// first is still open. AppKit queues it, and a single slot that the second
    /// overwrote freed the first — every control on it holds a weak target, so
    /// Cancel and Add reached nothing, the queued sheet never came, and Settings
    /// was stuck until the app quit.
    private static var open: [ObjectIdentifier: RuleSheet] = [:]

    static func present(on parent: NSWindow, prefill: Prefill = Prefill(),
                        done: @escaping (RulesStore.Rule?) -> Void) {
        let s = RuleSheet(prefill: prefill, done: done)
        let key = ObjectIdentifier(s.sheet)
        open[key] = s
        parent.beginSheet(s.sheet) { _ in open[key] = nil }
    }

    private init(prefill: Prefill, done: @escaping (RulesStore.Rule?) -> Void) {
        self.done = done
        editingID = prefill.id
        super.init()

        let editing = !prefill.id.isEmpty
        let title = NSTextField(labelWithString: editing ? "Change this rule"
                                                         : "A rule answers for you")
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString:
            prefill.display.isEmpty
            ? "AgentBar answers nothing by itself. It answers what you write down here, "
              + "and every time it does, the approval history says so."
            : "From “\(prefill.display)”. AgentBar will answer prompts of this shape the "
              + "way you say here, and the approval history will name this rule each time.")
        blurb.font = .systemFont(ofSize: 11.5)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = 420

        kind.target = self
        kind.action = #selector(changed)
        kind.selectedSegment = prefill.decision == "deny" ? 1 : 0

        shape.isEditable = true
        shape.completes = true
        shape.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        shape.delegate = self
        shape.addItems(withObjectValues: Self.offeredShapes())
        shape.stringValue = prefill.shape
        shape.placeholderString = "git status"
        shape.toolTip = "What repeats — the command's verb, never its arguments. Type "
            + "`git status`, or pick one you have decided about before."

        directories = Self.knownDirectories(including: prefill.cwd)
        place.target = self
        place.action = #selector(changed)
        rebuildPlaces(selecting: prefill.cwd)

        mode.target = self
        mode.action = #selector(changed)
        for m in RulesStore.Rule.Mode.allCases {
            mode.addItem(withTitle: m.title)
            mode.lastItem?.representedObject = m.rawValue
            mode.lastItem?.toolTip = m.explanation
        }
        mode.selectItem(at: RulesStore.Rule.Mode.allCases.firstIndex(of: prefill.mode) ?? 0)

        note.placeholderString = "Why (optional)"
        note.font = .systemFont(ofSize: 12)
        note.stringValue = prefill.note

        tell.placeholderString = "What to do instead — sent to the agent (optional)"
        tell.font = .systemFont(ofSize: 12)
        tell.stringValue = prefill.tell
        tell.delegate = self
        tell.toolTip = "Goes to the agent with every refusal, so it changes course instead "
            + "of guessing — \"use pnpm in this repo\". Unlike the note, this leaves the file."

        tryField.placeholderString = "git push --force origin main"
        tryField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tryField.delegate = self
        tryField.toolTip = "Type a real command, or a file path, and see whether this rule "
            + "would have taken it."

        tryResult.font = .systemFont(ofSize: 11)
        tryResult.preferredMaxLayoutWidth = 420

        consequence.font = .systemFont(ofSize: 11)
        consequence.textColor = .secondaryLabelColor
        consequence.preferredMaxLayoutWidth = 420

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let add = NSButton(title: editing ? "Save" : "Add rule", target: self,
                           action: #selector(commit))
        add.bezelStyle = .rounded
        add.keyEquivalent = "\r"

        let buttons = NSStackView(views: [NSView(), cancel, add])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        tellRow = labelled("Tell it", tell)

        let form = NSStackView(views: [
            title, blurb,
            labelled("Answer", kind), labelled("When", shape), labelled("In", place),
            labelled("Mode", mode), tellRow, labelled("Note", note),
            separator(), consequence,
            labelled("Try it", tryField), tryResult,
            buttons,
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let content = NSView()
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blurb.widthAnchor.constraint(equalToConstant: 420),
            consequence.widthAnchor.constraint(equalToConstant: 420),
            tryResult.widthAnchor.constraint(equalToConstant: 420),
            buttons.widthAnchor.constraint(equalToConstant: 420),
        ])
        sheet.contentView = content
        sheet.contentMinSize = NSSize(width: 470, height: 380)
        refresh()
    }

    /// One sheet, drawn to a file, for the same reason `SettingsWindow` has one:
    /// the parts of this window that can be wrong are its layout and its wording,
    /// and neither of those is something a test can look at. Filled in, and with
    /// the try field already answered, because an empty form shows none of the
    /// three things this sheet exists to say.
    static func renderForVerification(to url: URL, prefill: Prefill, trying: String) -> Bool {
        let sheet = RuleSheet(prefill: prefill) { _ in }
        sheet.tryField.stringValue = trying
        sheet.refresh()
        guard let root = sheet.sheet.contentView else { return false }
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }

    private func labelled(_ text: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 56).isActive = true
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        control.widthAnchor.constraint(equalToConstant: 354).isActive = true
        return row
    }

    private func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.widthAnchor.constraint(equalToConstant: 420).isActive = true
        return line
    }

    // MARK: - The two lists it offers

    /// Shapes this person has actually decided about, then the common ones. Without
    /// the second half the field is empty on the day AgentBar is installed, which is
    /// exactly when somebody is trying to work out what to type into it.
    static func offeredShapes(in records: [DecisionLedger.Record] = DecisionLedger.cached(),
                              common: [String] = RuleSheet.commonShapes) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for r in records.reversed() where !r.shape.isEmpty && seen.insert(r.shape).inserted {
            out.append(r.shape)
        }
        for c in common where seen.insert(c).inserted { out.append(c) }
        return out
    }

    /// Directories AgentBar has seen work happen in. The ledger first, then the
    /// session history, because a directory you decided something in is a better
    /// guess than one you merely worked in.
    static func knownDirectories(including first: String = "",
                                 decisions: [DecisionLedger.Record] = DecisionLedger.cached(),
                                 history: [HistoryStore.Record] = HistoryStore.cached()) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for cwd in [first] + decisions.reversed().map(\.cwd) + history.reversed().map(\.cwd)
        where !cwd.isEmpty && seen.insert(cwd).inserted {
            out.append(cwd)
        }
        return out
    }

    private func rebuildPlaces(selecting cwd: String) {
        place.removeAllItems()
        for dir in directories {
            place.addItem(withTitle: (dir as NSString).lastPathComponent)
            place.lastItem?.toolTip = dir
            place.lastItem?.representedObject = dir
        }
        if isDeny {
            place.addItem(withTitle: "Any directory")
            place.lastItem?.representedObject = ""
        }
        place.menu?.addItem(.separator())
        place.addItem(withTitle: "Choose…")
        place.lastItem?.representedObject = "choose"
        if let i = directories.firstIndex(of: cwd) {
            place.selectItem(at: i)
        } else if cwd.isEmpty, isDeny, let any = place.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == ""
        }) {
            place.selectItem(at: any)
        }
    }

    private var isDeny: Bool { kind.selectedSegment == 1 }

    private var selectedDirectory: String {
        (place.selectedItem?.representedObject as? String) ?? ""
    }

    private var selectedMode: RulesStore.Rule.Mode {
        RulesStore.Rule.Mode(rawValue: (mode.selectedItem?.representedObject as? String) ?? "")
            ?? .watch
    }

    private var typedShape: String {
        let text = shape.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return "" }
        return text.contains(":") ? text : "bash:" + DecisionLedger.verb(of: text)
    }

    // MARK: - Keeping the consequence honest

    @objc private func changed() {
        if selectedDirectory == "choose" {
            chooseDirectory()
            return
        }
        // "Any directory" exists only for a denial; switching to Allow must not
        // leave it selected and quietly mean something it is not allowed to mean.
        rebuildPlaces(selecting: selectedDirectory)
        refresh()
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use this directory"
        panel.beginSheetModal(for: sheet) { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                if !directories.contains(url.path) { directories.insert(url.path, at: 0) }
                rebuildPlaces(selecting: url.path)
            } else {
                rebuildPlaces(selecting: directories.first ?? "")
            }
            refresh()
        }
    }

    private func refresh() {
        let what = RulesView.readable(typedShape)
        let subject = what.isEmpty ? "this" : "`\(what)`"
        let dir = selectedDirectory
        let here = dir.isEmpty ? "anywhere" : "in " + (dir as NSString).lastPathComponent
        let prefix: String
        switch selectedMode {
        case .on:    prefix = ""
        case .watch: prefix = "**Watching, so it answers nothing yet.** Once you turn it on: "
        case .off:   prefix = "**Off, so it does nothing.** Turned on, it would: "
        }
        tellRow?.isHidden = !isDeny
        if isDeny {
            let said = DenyNote.clean(tell.stringValue).map { " It tells the agent “\($0)”." } ?? ""
            consequence.stringValue = prefix.replacingOccurrences(of: "**", with: "")
                + "Refuses \(subject) \(here), every time, without asking.\(said) A refusal is "
                + "never narrowed and never needs to be — the worst it can cost you is a prompt "
                + "you have to answer somewhere else."
        } else {
            consequence.stringValue = prefix.replacingOccurrences(of: "**", with: "")
                + "Answers \(subject) \(here) the moment it is asked.\n\n"
                + "It will never answer more than one command on a line, anything piped, "
                + "redirected or substituted, anything run through sudo, a shell or an "
                + "interpreter handed a snippet, a destructive git or rm, anything that "
                + "reaches off this Mac, anything run from outside "
                + "\(dir.isEmpty ? "that directory" : (dir as NSString).lastPathComponent)"
                + " or naming a path outside it, or anything that configures permission "
                + "itself. Those always come back to you, and no setting turns that off."
        }
        refreshTry()
    }

    /// The field that answers "would this rule have taken *that*?" — the one thing
    /// a paragraph cannot do, because the paragraph describes a category and the
    /// person is holding a specific command.
    private func refreshTry() {
        let text = tryField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            tryResult.stringValue = ""
            return
        }
        let (verdict, colour) = Self.tryOut(text, shape: typedShape, cwd: selectedDirectory,
                                            deny: isDeny)
        tryResult.stringValue = verdict
        tryResult.textColor = colour
    }

    /// Pure, so the wording is testable: what this rule would do with that command.
    /// A path is judged as a path and anything else as a command, which is the same
    /// split `DecisionLedger.shape(of:)` makes.
    static func tryOut(_ text: String, shape: String, cwd: String,
                       deny: Bool) -> (String, NSColor) {
        guard !shape.isEmpty else {
            return ("Fill in what the rule matches first.", .secondaryLabelColor)
        }
        let isPath = !text.contains(" ") && text.contains("/")
        let itsShape = isPath
            ? "edit:" + DecisionLedger.folder(of: text)
            : "bash:" + DecisionLedger.verb(of: text)
        // A rule keyed on an edit and a typed command are simply about different
        // things; say that rather than pretending to judge it.
        guard itsShape == shape || (isPath && shape.hasSuffix(DecisionLedger.folder(of: text)))
        else {
            return ("This rule does not cover that — it is \(RulesView.readable(itsShape)), "
                    + "and the rule is \(RulesView.readable(shape)).", .secondaryLabelColor)
        }
        if deny {
            return ("Refused, without asking.", .systemRed)
        }
        guard !cwd.isEmpty else {
            return ("Comes back to you: the rule has no directory yet.", .systemOrange)
        }
        let reason = isPath ? RuleEngine.refusalInPath(text, cwd: cwd)
                            : RuleEngine.refusalInCommand(text, cwd: cwd)
        if let reason {
            return ("Comes back to you — \(reason).", .systemOrange)
        }
        return ("Answered yes, without asking.", .systemGreen)
    }

    // MARK: - Leaving

    @objc private func cancel() {
        done?(nil)
        finish()
    }

    @objc private func commit() {
        guard !typedShape.isEmpty else {
            complain("A rule needs something to match.",
                     "Pick a prompt you have answered before, or type one — `git status`, "
                     + "`npm test`.")
            return
        }
        // Written plainly, so a directory a session reported as `/x/repo/` saves as
        // the rule the file check accepts instead of being refused by it.
        let dir = selectedDirectory == "choose" || selectedDirectory.isEmpty
            ? "" : RulesStore.normalisedCwd(selectedDirectory)
        let rule = RulesStore.Rule(id: editingID.isEmpty ? RulesStore.newID() : editingID,
                                   decision: isDeny ? "deny" : "allow",
                                   shape: typedShape, cwd: dir,
                                   note: note.stringValue.trimmingCharacters(in: .whitespaces),
                                   tell: isDeny ? (DenyNote.clean(tell.stringValue) ?? "") : "",
                                   mode: selectedMode)
        switch Self.finalised(rule) {
        case .failure(let why):
            complain("That rule cannot be saved.", why.text)
        case .success(let rule):
            done?(rule)
            finish()
        }
    }

    struct Refused: Error { let text: String }

    /// What every save of a rule goes through, whether it came from this sheet or
    /// from the rules list's "Let it answer": the same validation the file gets,
    /// before the file gets it — a rule that would refuse the whole file on the next
    /// launch must not be written now — and the save time stamped as `created`,
    /// which is what a watching rule's evidence is counted from.
    static func finalised(_ rule: RulesStore.Rule,
                          now: TimeInterval = Date().timeIntervalSince1970)
    -> Result<RulesStore.Rule, Refused> {
        if let why = RulesStore.validate(rule, index: 0, seen: []) {
            return .failure(Refused(text: why.replacingOccurrences(
                of: "Rule 1 (\(rule.id)) in ~/.agentbar/rules.json", with: "This rule")))
        }
        var out = rule
        out.created = now
        return .success(out)
    }

    private func complain(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: sheet)
    }

    private func finish() {
        done = nil
        sheet.sheetParent?.endSheet(sheet)
    }
}

extension RuleSheet: NSComboBoxDelegate, NSTextFieldDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    /// Both fields here hold a command, and macOS's text substitutions are for
    /// prose: with "smart dashes" on system-wide, typing `--force` into the try
    /// field gives you an em dash, and the answer under it would then be about a
    /// command nobody could run. Smart quotes are the same trap one step further —
    /// a curly quote is not a shell quote. Turned off on the field editor, which
    /// is the only place the substitution happens.
    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
        if let editor = fieldEditor as? NSTextView {
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.isAutomaticSpellingCorrectionEnabled = false
        }
        return true
    }
}

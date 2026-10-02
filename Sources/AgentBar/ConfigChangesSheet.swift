import Cocoa

/// The sheet that shows what AgentBar wrote into an agent's settings, line by line.
///
/// The installer runs on every launch and almost always writes nothing. When it does
/// write — a first install, a node that moved, a release that wires a new event —
/// it used to be invisible: one Console line nobody reads. This is where the answer
/// lives instead, in two halves:
///
/// - **Not written yet.** What a re-install would change right now, worked out by
///   the installer's own code (`HookInstaller.preview`) rather than by a description
///   of it, with a button that writes it. This is the "what will change" half; it is
///   empty on a machine where everything is wired, which is nearly always.
/// - **Written.** The last writes from `ConfigBackup`'s record, each with its diff
///   and the backup it kept beside the file.
///
/// The same sheet answers the **Agents** switches in Settings ▸ Diagnostics, in a
/// second mode (`Mode.toggle`): the pending half only, for that one agent, worked
/// out by the same preview — and instead of **Write it now**, **Cancel** and
/// **Apply**. Switching an agent on or off is a write into its settings like any
/// other, so it is shown like any other before it happens.
///
/// A sheet, not a window, for the reason `RuleSheet` is one: it is opened by a click
/// in a window the user already has open (Settings ▸ Diagnostics, or the welcome
/// window), it is modal to that window, and it is gone when it is dismissed. There
/// is deliberately no version of this that appears on its own — a launch that
/// rewrote a file backs it up and records it, and waits to be asked.
final class ConfigChangesSheet: NSObject {
    /// One line of the picker: a write still to come, or one already made.
    enum Entry: Equatable {
        case pending(ConfigBackup.Record)
        case written(ConfigBackup.Record)

        var record: ConfigBackup.Record {
            switch self { case .pending(let r), .written(let r): return r }
        }
    }

    /// What the sheet is for: everything AgentBar did and would do, or one agent
    /// being switched on (`wire`) or off.
    enum Mode: Equatable {
        case all
        case toggle(agent: String, name: String, wire: Bool)
    }

    /// A pending record that takes a file away rather than rewriting it — Copilot's
    /// and OpenCode's, which are AgentBar's own files.
    static func isRemoval(_ r: ConfigBackup.Record) -> Bool {
        r.diff.contains("\n+++ /dev/null") || r.diff.hasPrefix("+++ /dev/null")
    }

    /// Pending first — it is the half that still wants a decision — then the record,
    /// newest first, as `ConfigBackup.recent` already orders it.
    static func entries(pending: [ConfigBackup.Record], written: [ConfigBackup.Record]) -> [Entry] {
        pending.map(Entry.pending) + written.map(Entry.written)
    }

    /// `~/…` rather than `/Users/name/…`: the part of the path that says something.
    static func short(_ path: String,
                      home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func title(_ entry: Entry, now: Date = Date()) -> String {
        switch entry {
        case .pending(let r):
            return "Not written yet · " + short(r.path)
        case .written(let r):
            let when = Date(timeIntervalSince1970: r.ts)
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = Calendar.current.isDate(when, inSameDayAs: now) ? "HH:mm" : "d MMM HH:mm"
            return f.string(from: when) + " · " + short(r.path)
        }
    }

    /// The sentence under the picker: where the original went, which is the half of
    /// the answer a diff cannot give.
    static func caption(_ entry: Entry, mode: Mode = .all) -> String {
        switch entry {
        case .pending(let r):
            let who = mode == .all ? "The next launch" : "Apply"
            if isRemoval(r) { return "\(who) removes this file. A copy is kept beside it first." }
            return FileManager.default.fileExists(atPath: r.path)
                ? "\(who) writes this. The file as it is now will be kept beside it first."
                : "\(who) creates this file."
        case .written(let r):
            guard let backup = r.backup else {
                return "AgentBar created this file, so there was nothing to keep."
            }
            return FileManager.default.fileExists(atPath: backup)
                ? "The file as it was is kept as \(short(backup))."
                : "Kept as \(short(backup)), since rotated away — the last "
                  + "\(ConfigBackup.keep) copies stay."
        }
    }

    /// Wider than the welcome window it can sit on (520), narrower than Settings —
    /// a sheet may overhang its parent, and a diff needs the columns.
    private static let width: CGFloat = 580
    private static let inner = width - 40

    private let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 480),
                                 styleMask: [.titled], backing: .buffered, defer: false)
    private let picker = NSPopUpButton()
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let reveal = NSButton()
    private let writeNow = NSButton()
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let text = NSTextView()
    private let scroll = NSScrollView()
    private let apply = NSButton()
    private let done = NSButton()
    private var entries: [Entry] = []
    private let mode: Mode
    /// `Mode.toggle` only: called once, true when the change was applied, false when
    /// it was cancelled — so the switch that opened the sheet can go back.
    private var answer: ((Bool) -> Void)?
    /// Each sheet retained for its own life and released when *it* closes. Two
    /// can be up at once — one on the welcome window, one on Settings — and a
    /// single slot the second overwrote freed the first: its buttons hold weak
    /// targets, so Done reached nothing and that window could not close.
    private static var open: [ObjectIdentifier: ConfigChangesSheet] = [:]

    static func present(on parent: NSWindow) {
        let s = ConfigChangesSheet(mode: .all)
        let key = ObjectIdentifier(s.sheet)
        open[key] = s
        parent.beginSheet(s.sheet) { _ in open[key] = nil }
        s.load()
    }

    /// One agent switched on or off: what that would write, then Cancel or Apply.
    /// `answer` runs on the main queue once, after the change has been made (true)
    /// or abandoned (false).
    static func present(on parent: NSWindow, agent: String, name: String, wire: Bool,
                        answer: @escaping (Bool) -> Void) {
        let s = ConfigChangesSheet(mode: .toggle(agent: agent, name: name, wire: wire))
        s.answer = answer
        let key = ObjectIdentifier(s.sheet)
        open[key] = s
        parent.beginSheet(s.sheet) { _ in open[key] = nil }
        s.load()
    }

    static func heading(_ mode: Mode) -> (title: String, blurb: String) {
        switch mode {
        case .all:
            return ("What AgentBar changed in your agents' settings",
                    "Before AgentBar writes into a settings file it keeps the file as it was, beside "
                    + "it, as settings.json\(ConfigBackup.marker)<date and time>. The last \(ConfigBackup.keep) "
                    + "copies of each stay; a launch that changes nothing writes nothing and keeps nothing.")
        case .toggle(_, let name, true):
            return ("Wire AgentBar into \(name)",
                    "This is what AgentBar will add to \(name)'s settings, keeping each file as it "
                    + "was beside it first. New \(name) sessions show up from then on.")
        case .toggle(_, let name, false):
            return ("Leave \(name) alone",
                    "This is what AgentBar will take out of \(name)'s settings — only its own "
                    + "entries — keeping each file as it was beside it first. It stays off on every "
                    + "launch until you switch it back. Sessions already running keep their hooks "
                    + "until they end, and anything they ask is still answered.")
        }
    }

    private init(mode: Mode) {
        self.mode = mode
        super.init()

        let heading = Self.heading(mode)
        let title = NSTextField(labelWithString: heading.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)

        let blurb = NSTextField(wrappingLabelWithString: heading.blurb)
        blurb.font = .systemFont(ofSize: 11.5)
        blurb.textColor = .secondaryLabelColor
        blurb.preferredMaxLayoutWidth = Self.inner

        picker.target = self
        picker.action = #selector(pick)
        picker.isEnabled = false
        picker.addItem(withTitle: "Looking…")

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = Self.inner

        reveal.title = "Show in Finder"
        reveal.target = self
        reveal.action = #selector(revealBackup)
        reveal.bezelStyle = .rounded
        reveal.controlSize = .small
        reveal.font = .systemFont(ofSize: 11)
        reveal.isHidden = true

        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.preferredMaxLayoutWidth = Self.inner
        empty.isHidden = true

        // A diff is read column by column, so lines never wrap: a long hook command
        // scrolls sideways instead of folding into something that no longer lines up
        // with the line above it.
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = true
        text.backgroundColor = .textBackgroundColor
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                   height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        writeNow.title = "Write it now"
        writeNow.target = self
        writeNow.action = #selector(write)
        writeNow.bezelStyle = .rounded
        writeNow.isHidden = true
        writeNow.toolTip = "Runs the installer now, as a launch would. Each file is backed up first."

        done.title = "Done"
        done.target = self
        done.action = #selector(finish)
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        apply.target = self
        apply.action = #selector(applyToggle)
        apply.bezelStyle = .rounded
        apply.isHidden = true
        if case .toggle(_, _, let wire) = mode {
            // The change is the default button; walking away is Escape.
            done.title = "Cancel"
            done.keyEquivalent = "\u{1b}"
            apply.title = wire ? "Wire it" : "Turn off"
            apply.keyEquivalent = "\r"
            apply.isHidden = false
            apply.isEnabled = false   // until the preview is in
        }

        let captionRow = NSStackView(views: [caption, NSView(), reveal])
        captionRow.orientation = .horizontal
        captionRow.alignment = .firstBaseline
        captionRow.spacing = 8
        caption.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let buttons = NSStackView(views: [writeNow, NSView(), done, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let form = NSStackView(views: [title, blurb, picker, captionRow, empty, scroll, buttons])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        form.setCustomSpacing(14, after: blurb)
        form.translatesAutoresizingMaskIntoConstraints = false
        form.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let content = NSView()
        content.addSubview(form)
        NSLayoutConstraint.activate([
            form.topAnchor.constraint(equalTo: content.topAnchor),
            form.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            form.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            blurb.widthAnchor.constraint(equalToConstant: Self.inner),
            picker.widthAnchor.constraint(equalToConstant: Self.inner),
            captionRow.widthAnchor.constraint(equalToConstant: Self.inner),
            empty.widthAnchor.constraint(equalToConstant: Self.inner),
            scroll.widthAnchor.constraint(equalToConstant: Self.inner),
            scroll.heightAnchor.constraint(equalToConstant: 280),
            buttons.widthAnchor.constraint(equalToConstant: Self.inner),
        ])
        sheet.contentView = content
    }

    /// The preview runs the installer's own pass, which can probe the login shell for
    /// node — off the main thread, with the picker saying so meanwhile.
    private func load(selecting path: String? = nil) {
        if case .toggle(let agent, _, let wire) = mode {
            HookInstaller.preview(agent: agent, wired: wire) { [weak self] pending in
                guard let self else { return }
                self.show(Self.entries(pending: pending.filter { $0.agent == agent }, written: []),
                          selecting: path)
                self.apply.isEnabled = true
            }
            return
        }
        HookInstaller.preview { [weak self] pending in
            self?.show(Self.entries(pending: pending, written: ConfigBackup.recent()),
                       selecting: path)
        }
    }

    /// What the sheet says when there is no diff to show.
    static func emptyText(_ mode: Mode) -> String {
        switch mode {
        case .all:
            return "AgentBar has not changed any of your agents' settings since it "
                + "started keeping this record, and a re-install would change nothing."
        case .toggle(_, let name, true):
            return "Nothing in \(name)'s settings changes — AgentBar's hooks are already there."
        case .toggle(_, let name, false):
            return "Nothing to take out — none of AgentBar's hooks are in \(name)'s settings. "
                + "Turning it off keeps it that way."
        }
    }

    private func show(_ found: [Entry], selecting path: String?) {
        entries = found
        picker.removeAllItems()
        writeNow.isHidden = mode != .all
            || !found.contains { if case .pending = $0 { return true }; return false }
        guard !found.isEmpty else {
            picker.addItem(withTitle: "Nothing to show")
            picker.isEnabled = false
            caption.stringValue = ""
            reveal.isHidden = true
            empty.stringValue = Self.emptyText(mode)
            empty.isHidden = false
            scroll.isHidden = true
            return
        }
        empty.isHidden = true
        scroll.isHidden = false
        picker.isEnabled = true
        for entry in found { picker.addItem(withTitle: Self.title(entry)) }
        if let path, let i = found.firstIndex(where: { $0.record.path == path }) {
            picker.selectItem(at: i)
        }
        pick()
    }

    @objc private func pick() {
        let i = picker.indexOfSelectedItem
        guard entries.indices.contains(i) else { return }
        let entry = entries[i]
        caption.stringValue = Self.caption(entry, mode: mode)
        if case .written(let r) = entry, let backup = r.backup {
            reveal.isHidden = !FileManager.default.fileExists(atPath: backup)
        } else {
            reveal.isHidden = true
        }
        text.textStorage?.setAttributedString(Self.colored(entry.record.diff))
        text.scroll(.zero)
    }

    /// `diff -u`, coloured the way every terminal colours it. The text stays plain
    /// underneath, so a copy out of this view pastes as a patch.
    static func colored(_ diff: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let out = NSMutableAttributedString()
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            let color: NSColor
            var face = font
            if line.hasPrefix("+++") || line.hasPrefix("---") {
                color = .labelColor
                face = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            } else if line.hasPrefix("@@") {
                color = .systemBlue
            } else if line.hasPrefix("+") {
                color = .systemGreen
            } else if line.hasPrefix("-") {
                color = .systemRed
            } else if line.hasPrefix("\\") || line.hasPrefix("⋯") {
                color = .tertiaryLabelColor
            } else {
                color = .secondaryLabelColor
            }
            out.append(NSAttributedString(string: line + "\n",
                                          attributes: [.font: face, .foregroundColor: color]))
        }
        return out
    }

    @objc private func revealBackup() {
        let i = picker.indexOfSelectedItem
        guard entries.indices.contains(i), let backup = entries[i].record.backup else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: backup)])
    }

    /// The same pass a launch runs, on demand. The installer finishes on its own
    /// queue, so the sheet reloads once `onFinish` has had a moment — the same
    /// wait **Re-install hooks** uses before it re-checks.
    @objc private func write() {
        let i = picker.indexOfSelectedItem
        let path = entries.indices.contains(i) ? entries[i].record.path : nil
        writeNow.isEnabled = false
        writeNow.title = "Writing…"
        HookInstaller.installIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.writeNow.isEnabled = true
            self.writeNow.title = "Write it now"
            self.load(selecting: path)
        }
    }

    @objc private func finish() {
        answer?(false)
        answer = nil
        sheet.sheetParent?.endSheet(sheet)
    }

    /// Saves the choice and makes the change, then closes. A failure to save the
    /// choice is said in the sheet rather than swallowed, and the switch goes back.
    @objc private func applyToggle() {
        guard case .toggle(let agent, _, let wire) = mode else { return }
        apply.isEnabled = false
        done.isEnabled = false
        apply.title = wire ? "Wiring…" : "Turning off…"
        HookInstaller.setWired(agent, wire) { [weak self] error in
            guard let self else { return }
            if let error {
                self.done.isEnabled = true
                self.apply.title = wire ? "Wire it" : "Turn off"
                self.apply.isEnabled = true
                self.empty.stringValue = "Could not save the choice: \(error.localizedDescription)"
                self.empty.isHidden = false
                return
            }
            self.answer?(true)
            self.answer = nil
            self.sheet.sheetParent?.endSheet(self.sheet)
        }
    }

    /// Drawn to a file, for the same reason `RuleSheet` is: its layout and wording
    /// are the parts that can be wrong, and no test can look at either.
    static func renderForVerification(to url: URL, pending: [ConfigBackup.Record],
                                      written: [ConfigBackup.Record], mode: Mode = .all) -> Bool {
        let s = ConfigChangesSheet(mode: mode)
        s.show(entries(pending: pending, written: written), selecting: nil)
        guard let root = s.sheet.contentView else { return false }
        root.layoutSubtreeIfNeeded()
        root.setFrameSize(root.fittingSize)
        root.layoutSubtreeIfNeeded()
        guard let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return false }
        root.cacheDisplay(in: root.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: url)) != nil
    }
}

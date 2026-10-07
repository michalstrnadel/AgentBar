import AppKit

/// Hand a file to an agent: drop it on a session's row in the island and its path
/// goes into that session's prompt.
///
/// What this is allowed to do is narrow on purpose, because it is the one place
/// AgentBar puts text into somebody's terminal:
///
/// - It types **only the paths of what was dropped**, escaped the way Terminal
///   escapes a dragged file. Nothing from the session, the agent or a file's
///   contents is ever part of it.
/// - It **never presses Return.** The path lands in the prompt and the person
///   decides what to say about it — a drop is not an instruction.
/// - It pastes only into a tab `TerminalFocus` has **verified** is that session's
///   own (the hosts `KeystrokeApprover` trusts with a key). Anywhere else the path
///   goes on the clipboard and the terminal comes forward, and the row says ⌘V.
/// - The clipboard it borrowed is put back a moment later.
enum DropToAgent {
    /// What happened to a drop.
    enum Outcome: Equatable {
        /// The paths are in the session's prompt.
        case pasted
        /// The paths are on the clipboard and the terminal is in front.
        case copied(app: String)
        case refused(String)
    }

    /// Why a session cannot take a file, or nil when it can. A run on somebody
    /// else's machine, or in an app with no prompt AgentBar can reach, has nowhere
    /// for a path on this Mac to go.
    static func refusal(for s: Session) -> String? {
        switch s.entrypoint {
        case "cloud":           return "runs in the cloud — a path on this Mac means nothing there"
        case "claude-desktop":  return "lives in the Claude app — drop the file there"
        case "antigravity-app": return "lives in Antigravity — drop the file there"
        default:                return s.pid > 0 ? nil : "has no terminal AgentBar can find"
        }
    }

    // MARK: - The text

    /// Characters a shell reads as something other than part of a path. Terminal
    /// escapes exactly these with a backslash when a file is dragged into it, and
    /// every agent's prompt understands that spelling.
    static let special = Set(" '\"\\()&;|<>$`!*?[]{}#~=%^,\t")

    static func escape(_ path: String) -> String {
        var out = ""
        for c in path {
            if special.contains(c) { out.append("\\") }
            out.append(c)
        }
        return out
    }

    /// The paths as one line, with a trailing space so the person can keep typing.
    /// A path carrying a line break is left out: pasted, it would be a Return.
    static func text(for paths: [String]) -> String? {
        let clean = paths.filter { !$0.isEmpty && !$0.contains(where: \.isNewline) }
        guard !clean.isEmpty else { return nil }
        return clean.map(escape).joined(separator: " ") + " "
    }

    // MARK: - What was dropped

    /// Where an image that arrived as pixels rather than a file is kept, so it has
    /// a path to hand over. Pruned after a week.
    static var dropsDir: URL { AgentBarHome.root().appendingPathComponent("drops", isDirectory: true) }

    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    /// The paths in a drag: its files, or — for an image dragged out of a browser or
    /// a screenshot thumbnail that has not been saved yet — the image written to
    /// `dropsDir` first.
    static func paths(from pb: NSPasteboard, dir: URL = dropsDir, now: Date = Date()) -> [String] {
        let urls = (pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !urls.isEmpty { return urls.map(\.path) }
        guard let data = pb.data(forType: .png) ?? pb.data(forType: .tiff).flatMap(png) else { return [] }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = dir.appendingPathComponent("Dropped \(f.string(from: now)).png")
        guard (try? data.write(to: url)) != nil else { return [] }
        prune(dir: dir, now: now)
        return [url.path]
    }

    private static func png(_ tiff: Data) -> Data? {
        NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    static func prune(dir: URL = dropsDir, now: Date = Date(), maxAge: TimeInterval = 7 * 86_400) {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in files {
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(m) > maxAge { try? fm.removeItem(at: url) }
        }
    }

    // MARK: - Handing it over

    /// Whether this session's terminal can be pasted into: a tab that can be
    /// verified, and the permission to send ⌘V.
    static func canPaste(into s: Session, trusted: Bool = KeystrokeApprover.trusted) -> Bool {
        trusted && TerminalFocus.canTargetTab(termProgram: s.termProgram)
    }

    /// Brings the session forward and puts `paths` in its prompt — or on the
    /// clipboard, when its tab cannot be verified. `done` runs on the main queue.
    static func hand(_ paths: [String], to s: Session, done: @escaping (Outcome) -> Void) {
        if let why = refusal(for: s) { return done(.refused(why)) }
        guard let text = text(for: paths) else { return done(.refused("nothing to hand over")) }
        let app = TerminalApp.appName(forTermProgram: s.termProgram)
        guard canPaste(into: s) else {
            put(text)
            TerminalFocus.focus(session: s)
            return done(.copied(app: app))
        }
        TerminalFocus.focus(session: s) { landedIn in
            guard let landedIn else {
                // The tab was not found: the terminal is in front, the path is on
                // the clipboard, and nothing is typed into a tab nobody verified.
                put(text)
                return done(.copied(app: app))
            }
            let saved = snapshot()
            put(text)
            KeystrokeApprover.paste(into: landedIn) { sent in
                guard sent else { return done(.copied(app: landedIn)) }
                // Long enough for the terminal to read it, then the clipboard is
                // the person's again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { restore(saved) }
                done(.pasted)
            }
        }
    }

    private static func put(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// The clipboard's items, every type each carries, so a copied image or a
    /// rich-text selection comes back as it was.
    private static func snapshot() -> [[NSPasteboard.PasteboardType: Data]] {
        (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !items.isEmpty else { return }
        pb.writeObjects(items.map { types in
            let item = NSPasteboardItem()
            for (t, d) in types { item.setData(d, forType: t) }
            return item
        })
    }
}

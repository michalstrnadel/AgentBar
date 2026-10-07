import AppKit

/// Your latest screenshot, a drag away from an agent.
///
/// While the island is open — and only then — a screenshot taken in the last few
/// minutes shows as a thumbnail in its footer; drag it onto a session (or click it
/// and pick one) and `DropToAgent` hands it over. It never opens the island and
/// never appears in a closed one.
///
/// **Off by default.** Reading the screenshot folder (the Desktop, for most people)
/// is what macOS asks permission for, and a permission dialog that arrived because
/// the island happened to open would be a window unfolding on its own. Switched on
/// in Settings, the first read — and the dialog with it — follows that click.
enum ScreenshotShelf {
    static let window: TimeInterval = 3 * 60
    private static let key = "screenshotShelf"

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Where screenshots go: the folder chosen in the Screenshot app, else the Desktop.
    static func folder(defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.screencapture"),
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        if let raw = defaults?.string(forKey: "location"), !raw.isEmpty {
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Whether macOS marked this file as a screen capture. A name would be a guess —
    /// it is localised ("Snímek obrazovky…") and anyone can rename a file — while
    /// the screenshot tool sets this attribute on every file it writes.
    static func isScreenshot(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0
    }

    /// The newest screenshot in `dir` taken within `window` of `now`, or nil.
    static func latest(in dir: URL = folder(), now: Date = Date(),
                       isScreenshot: (URL) -> Bool = isScreenshot) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return files
            .compactMap { url -> (URL, Date)? in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true,
                      let m = v.contentModificationDate, now.timeIntervalSince(m) <= window,
                      now.timeIntervalSince(m) >= -5 else { return nil }
                return (url, m)
            }
            .sorted { $0.1 > $1.1 }
            .first { isScreenshot($0.0) }?.0
    }

    /// `latest()`, memoised on the folder's own modification time: the island
    /// rebuilds its footer often while it is open, and a directory listing each
    /// time is not free. Nil when switched off — the folder is not even looked at.
    static func current(now: Date = Date()) -> URL? {
        guard enabled else { return nil }
        let dir = folder()
        let stamp = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let c = cache, c.dir == dir, c.stamp == stamp, c.at.timeIntervalSince(now) > -20 {
            return c.url.flatMap { u in
                let m = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return m.map { now.timeIntervalSince($0) <= window } == true ? u : nil
            }
        }
        let url = latest(in: dir, now: now)
        cache = (dir, stamp, now, url)
        return url
    }

    private static var cache: (dir: URL, stamp: Date?, at: Date, url: URL?)?
}

/// The thumbnail in the footer: drag it out like the file it is, or click it to
/// pick a session.
final class ScreenshotChip: NSView, NSDraggingSource {
    let url: URL
    private let image: NSImage?
    var onChoose: ((NSView) -> Void)?

    init(url: URL) {
        self.url = url
        image = NSImage(contentsOf: url)
        super.init(frame: NSRect(x: 0, y: 0, width: 34, height: 22))
        toolTip = "Your latest screenshot — drag it onto a session, or click to choose one"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Latest screenshot. Hand it to a session.")
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        if let image {
            // Aspect fill: the middle of the shot, never stretched.
            let s = max(r.width / image.size.width, r.height / image.size.height)
            let w = image.size.width * s, h = image.size.height * s
            image.draw(in: NSRect(x: r.midX - w / 2, y: r.midY - h / 2, width: w, height: h))
        } else {
            NSColor.white.withAlphaComponent(0.2).setFill()
            r.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) { downAt = event.locationInWindow }

    override func mouseDragged(with event: NSEvent) {
        guard let start = downAt, hypot(event.locationInWindow.x - start.x,
                                        event.locationInWindow.y - start.y) > 3 else { return }
        downAt = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        guard downAt != nil else { return }
        downAt = nil
        onChoose?(self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}

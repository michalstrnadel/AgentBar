import Cocoa

/// Where on screen a session's app is, so Clawd can look at the session that is
/// waiting on the person rather than at nothing. It knows the app's frontmost
/// window, not the tab: honest enough for a glance, and all there is to know
/// without asking for anything — `kCGWindowBounds` and the owner pid come without
/// the Screen Recording permission (window *names* would not).
///
/// The choice of window is pure (`frontmost(of:in:)`), so it is tested on lists
/// written in the test. The live half asks the window server off the main thread,
/// at most once every `maxAge` per session, and answers from what it last heard.
enum SessionWindow {
    struct Window: Equatable {
        var pid: Int32
        var layer: Int
        var alpha: Double
        /// In the window server's space: points, origin at the top left of the
        /// main display, y down.
        var bounds: CGRect
    }

    /// Anything smaller is a status item, a tooltip or a sliver of a window being
    /// dragged — not the app's window.
    static let minSide: CGFloat = 80
    static let maxAge: TimeInterval = 2

    /// One entry of `CGWindowListCopyWindowInfo`; nil for one missing a field.
    static func window(_ info: [String: Any]) -> Window? {
        guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
        return Window(pid: pid, layer: layer, alpha: alpha, bounds: bounds)
    }

    /// The topmost normal window `pid` owns. The list is front to back, as the
    /// window server gives it, so the first that qualifies is the one on top:
    /// layer 0 (a document window, not a panel, a menu or the menu bar), visible,
    /// and big enough to be a window.
    static func frontmost(of pid: Int32, in windows: [Window]) -> CGRect? {
        windows.first {
            $0.pid == pid && $0.layer == 0 && $0.alpha > 0
                && $0.bounds.width >= minSide && $0.bounds.height >= minSide
        }?.bounds
    }

    /// The middle of `bounds` in AppKit's screen space (origin at the bottom left
    /// of the main display, y up), which is where the pointer and the pill are.
    static func centre(of bounds: CGRect, mainHeight: CGFloat) -> NSPoint {
        NSPoint(x: bounds.midX, y: mainHeight - bounds.midY)
    }

    // MARK: - Live

    final class Cache {
        static let shared = Cache()

        private struct Entry {
            var centre: NSPoint?
            var at: TimeInterval
        }
        private var entries: [String: Entry] = [:]
        private var inFlight: Set<String> = []
        private let queue = DispatchQueue(label: "agentbar.session-window", qos: .utility)

        /// What was last heard for `session`, asking again in the background
        /// when that is older than `maxAge`. Main thread only.
        func centre(of session: Session) -> NSPoint? {
            let now = Date().timeIntervalSince1970
            let entry = entries[session.id]
            if (entry.map { now - $0.at >= SessionWindow.maxAge } ?? true),
               !inFlight.contains(session.id) {
                refresh(id: session.id, pid: session.pid)
            }
            return entry?.centre
        }

        private func refresh(id: String, pid: Int32) {
            inFlight.insert(id)
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            queue.async { [weak self] in
                var centre: NSPoint?
                if let host = ProcessAncestry.hostApplication(of: pid)?.processIdentifier,
                   let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                         kCGNullWindowID) as? [[String: Any]],
                   let bounds = SessionWindow.frontmost(of: host, in: list.compactMap(SessionWindow.window)) {
                    centre = SessionWindow.centre(of: bounds, mainHeight: mainHeight)
                }
                DispatchQueue.main.async {
                    self?.inFlight.remove(id)
                    self?.entries[id] = Entry(centre: centre, at: Date().timeIntervalSince1970)
                    if let self, self.entries.count > 32 {
                        let cutoff = Date().timeIntervalSince1970 - 60
                        self.entries = self.entries.filter { $0.value.at > cutoff }
                    }
                }
            }
        }
    }
}

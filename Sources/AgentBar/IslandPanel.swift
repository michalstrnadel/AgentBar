import Cocoa

/// The window the island lives in: borderless, non-activating, over every ordinary
/// window, present on every Space. It never becomes key, so clicking a button in it
/// can't pull focus out of the editor or terminal the user is working in.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // the content draws its own rounded shape
        level = .statusBar           // above ordinary windows, like the menu bar itself
        // Deliberately *without* .fullScreenAuxiliary — the island is nobody's
        // fullscreen accessory. It is not enough on its own (a .canJoinAllSpaces
        // window at this level still gets shown over a fullscreen Space), so
        // `IslandGeometry.isFullscreen` does the actual work; this just stops us
        // asking for something we don't want.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = true
    }

    /// Never key: the point of the island is that it doesn't interrupt.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Where the island sits. On a notched Mac it hangs from the notch; anywhere else
/// (older Macs, external displays) it is a floating bar centred at the top.
enum IslandGeometry {
    /// The screen the island should follow: whichever one the pointer is on, so a
    /// two-display setup puts it where the user is looking.
    static var screen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens.first
    }

    /// The notch's own rect, or nil on a display without one. The notch is the gap
    /// between the two usable strips macOS reports either side of it.
    static func notch(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX
        else { return nil }
        return NSRect(x: left.maxX, y: left.minY,
                      width: right.minX - left.maxX, height: left.height)
    }

    /// Height of the menu bar strip the island shares the top of the screen with.
    static func barHeight(on screen: NSScreen) -> CGFloat {
        let inset = screen.safeAreaInsets.top
        return inset > 0 ? inset : NSStatusBar.system.thickness
    }

    /// Gap between the menu bar and the panel floating under it.
    static let topGap: CGFloat = 3

    /// A panel of this size, floating just below the menu bar and centred on the
    /// notch (or on the screen when there isn't one). Clear of the bar rather than
    /// over it: nothing has to dodge the notch, and the user's own menu bar — clock,
    /// status items, menu titles — stays usable.
    static func frame(width: CGFloat, height: CGFloat, on screen: NSScreen) -> NSRect {
        let centerX = notch(on: screen)?.midX ?? screen.frame.midX
        return NSRect(x: (centerX - width / 2).rounded(),
                      y: screen.frame.maxY - barHeight(on: screen) - topGap - height,
                      width: width, height: height)
    }

    /// True while something is running fullscreen on this screen — someone's video
    /// or editor is not a place to float a status panel over, so the island steps
    /// out until they come back.
    ///
    /// Measured from the windows themselves rather than from screen geometry.
    /// `visibleFrame` cannot answer this: on a notched Mac it reads identically in
    /// both states (the menu bar strip is excluded either way), which is why the
    /// obvious `visibleFrame.maxY >= frame.maxY` test silently never fired. A
    /// fullscreen window is instead recognisable by shape — full width, reaching the
    /// very bottom of the screen, and tall enough to have swallowed the menu bar
    /// strip. A merely zoomed window stops above the Dock and so never matches.
    ///
    /// Only layer and bounds are read, never window titles, so this needs no Screen
    /// Recording permission.
    static func isFullscreen(on screen: NSScreen) -> Bool {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                              kCGNullWindowID) as? [[String: Any]] ?? []
        // CGWindow bounds are top-left origin on the primary display; NSScreen is
        // bottom-left. Flip through the primary screen's height before comparing.
        let flip = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
        let target = screen.frame
        let bar = barHeight(on: screen)
        for win in info {
            guard (win[kCGWindowLayer as String] as? Int) == 0,
                  let b = win[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"]
            else { continue }
            let frame = NSRect(x: x, y: flip - (y + h), width: w, height: h)
            if frame.width >= target.width - 1, abs(frame.minX - target.minX) <= 1,
               frame.minY <= target.minY + 1, frame.height >= target.height - bar - 1 {
                return true
            }
        }
        return false
    }
}

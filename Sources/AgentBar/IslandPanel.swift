import Cocoa

/// The window the island lives in: borderless, non-activating, above the menu bar,
/// present on every Space. It never becomes key, so clicking a button in it can't
/// pull focus out of the editor or terminal the user is working in.
final class IslandPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false            // the content draws its own rounded shape
        level = .statusBar           // one above .mainMenu, so it can overlay the bar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
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

    /// True while a window is fullscreen on this screen — the notch region is not
    /// ours to draw in there, so the island stays out of the way.
    static func isFullscreen(on screen: NSScreen) -> Bool {
        // A fullscreen window covers the menu bar, so the visible frame reaches the
        // very top of the screen; normally it stops below the bar.
        screen.visibleFrame.maxY >= screen.frame.maxY - 1
    }
}

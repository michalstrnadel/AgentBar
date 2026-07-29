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
        // The window carries the drop shadow: the content layer clips to its
        // rounded shape (for the expand reveal), and a masked layer can't cast one.
        hasShadow = true
        level = .statusBar           // above ordinary windows, like the menu bar itself
        // .fullScreenAuxiliary matters as much as .canJoinAllSpaces: without it the
        // panel is missing exactly where people spend their day — a fullscreen editor
        // or terminal — and an island you can't see is not an island.
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

    /// Gap between the menu bar and the panel hanging under it. Zero on purpose: the
    /// collapsed pill is narrower than the notch, so flush against the notch's bottom
    /// edge the two black shapes read as one — the panel looks like part of the
    /// machine rather than something parked underneath it.
    static let topGap: CGFloat = 0

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

    // No fullscreen check lives here any more. The original one — "visibleFrame
    // reaches the top of the screen" — never fired at all on a notched Mac, and when
    // it was replaced with a working one the island promptly vanished from the
    // fullscreen terminal the agents were running in. Being visible everywhere beats
    // being polite about it; the pill is 30pt tall and only opens when pointed at.
}

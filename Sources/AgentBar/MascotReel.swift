import Cocoa

/// The working loop on screen, one frame per tick. A plain loop goes round and
/// round; a reel with a `next` asks what it should be playing only when the loop
/// on screen has played to its end. A Claude session hops between thinking and a
/// tool several times a second, and a scene cut on every hop would be a flicker
/// rather than a picture — so each scene plays whole, and the cut lands on its
/// last frame.
struct MascotReel {
    /// What is playing. A caller asking for the same key again keeps this reel
    /// and its place instead of starting over.
    let key: AnyHashable
    private var frames: [NSImage]
    private let next: (() -> [NSImage])?
    private(set) var index = 0

    init(key: AnyHashable, frames: [NSImage], next: (() -> [NSImage])? = nil) {
        self.key = key
        self.frames = frames
        self.next = next
    }

    var current: NSImage? { frames.isEmpty ? nil : frames[index] }

    mutating func advance() -> NSImage? {
        guard !frames.isEmpty else { return nil }
        index += 1
        if index >= frames.count {
            index = 0
            if let next {
                let upcoming = next()
                if !upcoming.isEmpty { frames = upcoming }
            }
        }
        return frames[index]
    }
}

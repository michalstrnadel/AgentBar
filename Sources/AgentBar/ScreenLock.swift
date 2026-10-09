import Cocoa

/// Locks the screen the way ⌃⌘Q does, and knows whether it is locked.
///
/// The lock is `SACLockScreenImmediate` from the private login framework — what
/// the Lock Screen menu item itself calls. It is looked up, not linked, so a
/// macOS without it makes `canLock` false and Keep Awake simply never locks.
/// The locked state comes from the session dictionary at launch and the
/// screen-lock notifications after it (the ones `Notifier` and `SoundCenter`
/// already listen to).
final class ScreenLock {
    static let shared = ScreenLock()

    /// Fires on the main queue when the screen locks or unlocks.
    var onChange: (() -> Void)?
    private(set) var isLocked: Bool
    private let lockFunction: (@convention(c) () -> Int32)?

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY)
        lockFunction = dlsym(handle, "SACLockScreenImmediate")
            .map { unsafeBitCast($0, to: (@convention(c) () -> Int32).self) }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        isLocked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = true
            self?.onChange?()
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.isLocked = false
            self?.onChange?()
        }
    }

    var canLock: Bool { lockFunction != nil }

    /// Locks now. False if this Mac offers no way to.
    @discardableResult
    func lock() -> Bool {
        guard let lockFunction else { return false }
        _ = lockFunction()
        return true
    }
}

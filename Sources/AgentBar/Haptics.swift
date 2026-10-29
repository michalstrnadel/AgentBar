import Cocoa

/// The trackpad's tick under an answer: one when a hold starts, a firmer one when
/// it lands. Only what a Force Touch trackpad under the finger can feel; a mouse
/// feels nothing and nothing else changes. On unless switched off in Settings.
enum Haptics {
    static let key = "approvalHaptics"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func started() { perform(.alignment) }
    static func landed() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard enabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

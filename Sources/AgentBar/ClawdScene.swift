import Foundation

/// What Clawd is seen doing while a Claude session works, chosen from what the
/// session reports and never made up: a book when it reads, a hammer when it runs
/// a command. Pure on purpose — the clock is passed in, so every choice can be
/// read and tested without a timer. The pictures are `ClawdSceneArt`'s; when to
/// cut from one to the next is `MascotReel`'s.
enum ClawdScene: CaseIterable {
    /// Nothing more specific is known — a tool AgentBar has no picture for.
    case walk
    case think, type, read, search, hammer, web, delegate, compact

    /// After this long without a word from the session it is chewing on
    /// something, not still busy with its last tool.
    static let lingering: TimeInterval = 6

    static func scene(for session: Session, now: TimeInterval) -> ClawdScene {
        if session.isCompacting { return .compact }
        switch session.state {
        case .tool:
            return scene(forTool: session.label) ?? .walk
        case .thinking:
            // Between two tool calls Claude is mostly going over what the last
            // one gave back, so that tool's scene holds for a while. A turn that
            // has not touched a tool yet, or a long silence, is thinking.
            if now - session.ts < lingering, let last = session.activity.last,
               let scene = scene(forTool: last) {
                return scene
            }
            return .think
        default:
            return .walk
        }
    }

    /// The tool labels `Scripts/hooks/claude/update.js` writes (Qwen's tools
    /// map onto the same words there).
    static func scene(forTool label: String) -> ClawdScene? {
        switch label {
        case "Editing", "Writing", "Noting":  return .type
        case "Reading":                       return .read
        case "Searching":                     return .search
        case "Running command":               return .hammer
        case "Browsing web", "Searching web": return .web
        case "Delegating":                    return .delegate
        case "Planning":                      return .think
        default:                              return nil
        }
    }
}

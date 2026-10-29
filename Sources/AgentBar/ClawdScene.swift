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
    /// A test run, and three failed calls in a row (`SessionSignals`).
    case test, sweat
    /// Waiting on the human, not working — `MascotDriver` picks these from the
    /// state itself: a permission request, a question, and a long quiet.
    case approve, ask, sleep
    /// A turn that ended in an error, held for a moment (`sadFor`) before rest.
    case sad

    /// How long the sad picture stays before the mark goes back to rest.
    static let sadFor: TimeInterval = 8

    /// How long nothing has to happen before Clawd falls asleep.
    static let sleepsAfter: TimeInterval = 10 * 60

    /// Asleep when no session has worked or waited on you for `sleepsAfter`.
    static func asleep(lastBusy: TimeInterval, now: TimeInterval) -> Bool {
        now - lastBusy >= sleepsAfter
    }

    /// After this long without a word from the session it is chewing on
    /// something, not still busy with its last tool.
    static let lingering: TimeInterval = 6

    /// `stalled`: nothing has changed in the session for a while (`Tempo`). A
    /// tool with a picture of its own keeps it — a long build is still a build —
    /// but the walk, which says only "some tool", gives way to thinking.
    static func scene(for session: Session, now: TimeInterval, stalled: Bool = false) -> ClawdScene {
        if session.isCompacting { return .compact }
        if session.state.isWorking, session.signals.sweating(now: now) { return .sweat }
        switch session.state {
        case .tool:
            let scene = scene(forTool: session.label) ?? .walk
            return stalled && scene == .walk ? .think : scene
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
        case "Running tests":                 return .test
        case "Browsing web", "Searching web": return .web
        case "Delegating":                    return .delegate
        case "Planning":                      return .think
        default:                              return nil
        }
    }
}

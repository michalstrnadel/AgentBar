import Cocoa

/// What the island needs from a game it opens into (`IslandController+Game`):
/// a view of the island's size that runs a clock only while it is played, can be
/// paused and stopped, and says when it wants to close or wants the keys back.
/// Both games — Space Bugs and Bug Hunt — are one of these; the island's rules
/// for them (opened on a click, stepping aside for work) are the same.
protocol IslandGame: NSView {
    var score: Int { get }
    var onClose: (() -> Void)? { get set }
    var onWantsKeys: (() -> Void)? { get set }
    func resume()
    func pause()
    func stop()
}

/// What the island can open into for a break, in the order the picker lists
/// them: the two games, and the office (`Office`) — no game, no score, but opened
/// and closed by the same rules.
enum GameChoice: String, CaseIterable {
    case spaceBugs = "space"
    case bugHunt = "hunt"
    case office = "office"

    var title: String {
        switch self {
        case .spaceBugs: return "Space Bugs"
        case .bugHunt: return "Bug Hunt"
        case .office: return "Office"
        }
    }

    var detail: String {
        switch self {
        case .spaceBugs: return "Clawd vs. a formation of bugs. Arrows and Space."
        case .bugHunt: return "Shoot the bugs out of the sky; the dog fetches. Aim and click."
        case .office: return "Everyone at their desk, doing what they are doing right now. Click a desk to go there."
        }
    }

    var symbol: String {
        switch self {
        case .spaceBugs: return "gamecontroller"
        case .bugHunt: return "scope"
        case .office: return "building.2"
        }
    }

    /// A game keeps a score and is "the last game played"; the office does neither.
    var isGame: Bool { self != .office }

    /// The way back to it once it was put aside: a game says its score, the
    /// office has none to say.
    func backTitle(score: Int) -> String {
        isGame ? "Back to the break — \(title) \(IslandController.grouped(score))" : "Back to the office"
    }

    func make(defaults: UserDefaults = .standard) -> NSView & IslandGame {
        switch self {
        case .spaceBugs: return BreakGameView(defaults: defaults)
        case .bugHunt: return HuntGameView(defaults: defaults)
        case .office: return OfficeView()
        }
    }

    static let size = NSSize(width: 432, height: 470)

    /// The game last started, listed first next time.
    static var last: GameChoice {
        get {
            UserDefaults.standard.string(forKey: "islandLastGame").flatMap(GameChoice.init)
                .flatMap { $0.isGame ? $0 : nil } ?? .spaceBugs
        }
        set {
            guard newValue.isGame else { return }
            UserDefaults.standard.set(newValue.rawValue, forKey: "islandLastGame")
        }
    }
}

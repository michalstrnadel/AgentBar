import Foundation

/// Whether the island's pill is on screen at all — the one question
/// `IslandController` asks before it lays anything out, kept apart from it so the
/// answer can be read (and tested) without a panel, a screen or a pointer.
///
/// The pill is the app's presence, so the default answer is yes, and every way to
/// say no is a switch the user turned on: nothing running, or nobody at the
/// keyboard. Two things outrank both switches. Something waiting on the user keeps
/// the pill up — a request is the one thing the pill exists to say, and a pill that
/// steps aside while an approval waits is a status display hiding its only news
/// (it still never *opens* by itself; that stays the pointer's job). And the user's
/// own hand: a pointer that arrived at the notch summons the pill back even when
/// both switches say it should be gone, which is what makes hiding safe at all.
enum IslandVisibility {
    struct Inputs: Equatable {
        var presentation: Presentation
        var hasSessions: Bool
        /// A pending approval, question or plan — anything the pill would say
        /// "approve?" or "answer?" for.
        var hasRequests: Bool
        /// The panel is open, held open, or has a note being typed into it. An open
        /// panel never vanishes from under the pointer that opened it.
        var open: Bool
        /// "✓ Allowed" is still being echoed. It finishes before any exit.
        var flashing: Bool
        /// A fresh arrival in the hover zone summoned the pill, and the grace after
        /// the pointer left has not run out yet.
        var peeking: Bool
        var hideWhenEmpty: Bool
        var hideWhenAway: Bool
        /// Seconds since the last keyboard or mouse event (`InputIdle`).
        var idleSeconds: TimeInterval
        var awayAfter: TimeInterval = IslandVisibility.awayAfter
    }

    /// Three minutes. Long enough that reading a long diff, or watching an agent
    /// type, does not count as having left — those are exactly the moments the
    /// pill is being looked at — and short enough that stepping out for a coffee
    /// does. Deliberately longer than the notifier's two-minute settle: a banner
    /// that comes a little early costs a glance, a pill that vanishes while the
    /// user is still reading it looks like a bug.
    static let awayAfter: TimeInterval = 180

    /// Whether the user counts as away, given the switch and the idle time. The
    /// controller watches this one value change to know when to re-evaluate.
    static func away(hideWhenAway: Bool, idleSeconds: TimeInterval,
                     awayAfter: TimeInterval = awayAfter) -> Bool {
        hideWhenAway && idleSeconds >= awayAfter
    }

    static func shows(_ i: Inputs) -> Bool {
        guard i.presentation.showsIsland else { return false }
        // What the user is doing with it right now, or what is waiting on them.
        if i.open || i.flashing || i.hasRequests || i.peeking { return true }
        if away(hideWhenAway: i.hideWhenAway, idleSeconds: i.idleSeconds,
                awayAfter: i.awayAfter) { return false }
        return !(i.hideWhenEmpty && !i.hasSessions)
    }

    /// Both switches, off by default (`bool(forKey:)` gives false) and owned here
    /// rather than as string literals, because Settings and the controller both
    /// read them.
    ///
    /// Hide-when-empty is honoured in every mode that shows the island, island-only
    /// included. It used to be `.both` only: with the pill gone there was no way
    /// left to Settings. The peek is that way now — push the pointer up to the
    /// notch, the pill comes back and opens like it always does, and the footer's
    /// ⋯ is where it always was. A tick left over from when it did nothing there is
    /// not taken at its word — see `migrate`.
    ///
    /// Hide-when-away is opt-in for the reason the threshold is long: a status
    /// display is most often read by someone who is *not* touching anything —
    /// leaning back while an agent works — and switching it off on them after an
    /// update would take the island away from the very moment it is for.
    enum Prefs {
        static var hideWhenEmpty: Bool {
            get { UserDefaults.standard.bool(forKey: "hideIslandWhenEmpty") }
            set { UserDefaults.standard.set(newValue, forKey: "hideIslandWhenEmpty") }
        }
        static var hideWhenAway: Bool {
            get { UserDefaults.standard.bool(forKey: "hideIslandWhenAway") }
            set { UserDefaults.standard.set(newValue, forKey: "hideIslandWhenAway") }
        }

        /// Hide-when-empty was on screen in every mode but only ever worked in
        /// `.both`, so someone in island-only mode could have ticked it, watched
        /// nothing happen, and forgotten it. Honouring that tick now would take
        /// their only surface away the next time nothing runs, on the strength of a
        /// switch they had every reason to think was broken. So in island-only mode
        /// it is cleared once, and from then on means what it says — set again, it
        /// sticks. In `.both` it already worked and is left alone; in menu-bar-only
        /// the island is not up, and the question waits until it is.
        static func migrate(presentation: Presentation,
                            _ defaults: UserDefaults = .standard) {
            guard presentation.showsIsland,
                  !defaults.bool(forKey: "hideIslandWhenEmptyMigrated") else { return }
            defaults.set(true, forKey: "hideIslandWhenEmptyMigrated")
            if presentation == .island { defaults.set(false, forKey: "hideIslandWhenEmpty") }
        }
    }
}

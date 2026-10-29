import Cocoa

/// `BlastRadius` chips drawn for each surface: a row of small boxes on the island,
/// one coloured line in the menu. Colour carries severity and nothing else — red
/// text for what is held longest, amber for what is held at all, no fills, no glow.
enum BlastChipsView {
    static func tint(_ s: BlastRadius.Severity, onDark: Bool) -> NSColor {
        switch s {
        case .high: return onDark ? NSColor(red: 1, green: 0.45, blue: 0.42, alpha: 1) : .systemRed
        case .medium: return onDark ? IconRenderer.amberDot : .systemOrange
        case .low: return onDark ? IslandInk.quiet : .secondaryLabelColor
        }
    }

    /// The island row, or nil when the request reaches nothing worth naming.
    static func islandRow(_ chips: [BlastRadius.Chip]) -> NSView? {
        guard !chips.isEmpty else { return nil }
        let boxes: [NSView] = chips.prefix(5).map { c in
            let label = NSTextField(labelWithString: c.label)
            label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
            label.textColor = tint(c.severity, onDark: true)
            let box = ChipBox(label: label)
            box.setAccessibilityLabel("\(c.label), \(c.severity == .high ? "high" : c.severity == .medium ? "medium" : "low") risk")
            return box
        }
        let row = NSStackView(views: boxes)
        row.orientation = .horizontal
        row.spacing = 5
        row.toolTip = "What this can reach. Allow is held longer the more it can reach."
        return row
    }

    /// "deletes · outside repo" for a menu item title, each word in its colour.
    static func menuTitle(_ chips: [BlastRadius.Chip]) -> NSAttributedString? {
        guard !chips.isEmpty else { return nil }
        let out = NSMutableAttributedString()
        for (i, c) in chips.prefix(5).enumerated() {
            if i > 0 {
                out.append(NSAttributedString(string: " · ", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.tertiaryLabelColor]))
            }
            out.append(NSAttributedString(string: c.label, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: tint(c.severity, onDark: false)]))
        }
        return out
    }

    /// "deletes, outside repo" for a phone push or a banner.
    static func plain(_ chips: [BlastRadius.Chip]) -> String {
        chips.prefix(5).map(\.label).joined(separator: ", ")
    }
}

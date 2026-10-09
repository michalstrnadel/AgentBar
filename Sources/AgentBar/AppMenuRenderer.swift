import Cocoa

/// Turns `AppMenuEntry` lists into NSMenuItems, and re-applies fresh entries to
/// items that are already on screen. The one place the section's AppKit details
/// live, so neither surface can render a row its own way.
enum AppMenuRenderer {
    /// Prefix on every rendered item's identifier, so a refresh can find them
    /// among a surface's own rows.
    static let idPrefix = "app:"

    /// The action an item stands for, boxed so it fits `representedObject`.
    final class Command: NSObject {
        let action: AppMenuAction
        init(_ action: AppMenuAction) { self.action = action }
    }

    static func action(of item: NSMenuItem) -> AppMenuAction? {
        (item.representedObject as? Command)?.action
    }

    /// `submenuDelegate` lets the menu bar hold its live refresh while a submenu
    /// is showing, the way its own submenus do.
    static func items(_ entries: [AppMenuEntry], target: AnyObject?, action: Selector,
                      submenuDelegate: NSMenuDelegate? = nil) -> [NSMenuItem] {
        entries.map { e in
            if e.isSeparator {
                let sep = NSMenuItem.separator()
                sep.identifier = NSUserInterfaceItemIdentifier(idPrefix + e.id)
                return sep
            }
            let item = NSMenuItem(title: e.title, action: nil, keyEquivalent: e.keyEquivalent)
            if !e.children.isEmpty {
                let sub = NSMenu()
                sub.delegate = submenuDelegate
                for child in items(e.children, target: target, action: action,
                                   submenuDelegate: submenuDelegate) {
                    sub.addItem(child)
                }
                item.submenu = sub
            }
            apply(e, to: item, target: target, action: action)
            return item
        }
    }

    /// (Re)applies the whole appearance of one row. Every field it can set is reset
    /// first: refresh reuses the live item, so a value left over from an earlier
    /// state (an accent title, an action, a tooltip) would otherwise stick.
    static func apply(_ e: AppMenuEntry, to item: NSMenuItem, target: AnyObject?, action: Selector) {
        item.identifier = NSUserInterfaceItemIdentifier(idPrefix + e.id)
        item.attributedTitle = nil
        item.title = e.title
        if e.accent {
            // Weight, not colour, on the words: accent-blue text on a translucent
            // grey menu was the one row nobody could read — an update waiting to be
            // installed went unseen. The colour goes on the glyph instead.
            item.attributedTitle = NSAttributedString(
                string: e.title,
                attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
        }
        if let a = e.action {
            item.action = action
            item.target = target
            item.representedObject = Command(a)
        } else {
            item.action = nil
            item.target = nil
            item.representedObject = nil
        }
        item.isEnabled = e.action != nil || !e.children.isEmpty
        item.state = e.on.map { $0 ? .on : .off } ?? .off
        item.image = e.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        if e.accent, let image = item.image?.withSymbolConfiguration(
            .init(paletteColors: [NSColor.controlAccentColor])) {
            image.isTemplate = false
            item.image = image
        }
        item.toolTip = e.toolTip
        if let status = e.status {
            if let view = item.view as? KeepAwakeStatusView {
                view.update(status)
            } else {
                item.view = KeepAwakeStatusView(status)
            }
        } else if item.view is KeepAwakeStatusView {
            item.view = nil
        }
        if #available(macOS 14.0, *) {
            item.badge = e.badge.map { NSMenuItemBadge(string: $0) }
        } else if let badge = e.badge {
            item.toolTip = "AgentBar \(badge)"
        }
    }

    /// Re-applies fresh entries to the shared rows of an OPEN menu, in place and
    /// without adding or removing anything (an open NSMenu never shrinks). Items
    /// that are not shared rows are left alone; a shared row whose entry has gone
    /// stays as it was until the next open rebuilds.
    static func refresh(_ menu: NSMenu, with entries: [AppMenuEntry], target: AnyObject?,
                        action: Selector) {
        let byID = Dictionary(flatten(entries).map { (idPrefix + $0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        refresh(menu.items, byID: byID, target: target, action: action)
    }

    private static func refresh(_ items: [NSMenuItem], byID: [String: AppMenuEntry],
                                target: AnyObject?, action: Selector) {
        for item in items {
            guard let id = item.identifier?.rawValue, let e = byID[id] else { continue }
            if e.isSeparator { continue }
            apply(e, to: item, target: target, action: action)
            if let sub = item.submenu {
                refresh(sub.items, byID: byID, target: target, action: action)
            }
        }
    }

    private static func flatten(_ entries: [AppMenuEntry]) -> [AppMenuEntry] {
        entries.flatMap { [$0] + flatten($0.children) }
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}

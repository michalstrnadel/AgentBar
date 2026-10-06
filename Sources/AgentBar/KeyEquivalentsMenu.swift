import AppKit

/// A main menu nobody sees, for the key equivalents it carries.
///
/// An accessory app shows no menu bar, and AppKit text fields only learn ⌘C, ⌘V,
/// ⌘X, ⌘A and ⌘Z from the main menu's items. Without one, pasting a token into
/// "Use a token…", a prompt into the Launcher or a note into "Deny with a note…"
/// did nothing at all. ⌘W closes Settings the way it closes every other window.
///
/// No ⌘Q: the island takes the keyboard for a game or a note, and a reflexive ⌘Q
/// there would quit the app that is watching every agent. Quit stays in the menus.
enum KeyEquivalentsMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(submenu(title: "AgentBar", items: []))
        main.addItem(submenu(title: "Edit", items: [
            NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"),
            shifted(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")),
            .separator(),
            NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"),
            NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"),
            NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"),
            NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
        ]))
        main.addItem(submenu(title: "Window", items: [
            NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"),
        ]))
        NSApp.mainMenu = main
    }

    private static func submenu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func shifted(_ item: NSMenuItem) -> NSMenuItem {
        item.keyEquivalentModifierMask = [.command, .shift]
        return item
    }
}

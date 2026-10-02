import Cocoa

/// The ⋯ menu in the open panel's footer. In Island-only mode it is the only menu
/// there is, so everything the menu bar's dropdown offers about the app itself has
/// to be here too — and it is, because both render `AppMenuModel.appSection`.
/// What this file adds on its own is only the day's digest at the top and the
/// wiring of the shared rows to this controller.
extension IslandController {
    /// The selector every shared row is wired to on this surface.
    static let appMenuAction = #selector(IslandController.appMenuClicked(_:))

    /// The shared app section as this surface renders it. Its own function so a
    /// test can hold it against the menu bar's (`AppMenuModelTests`).
    static func appSection(_ inputs: AppMenuModel.Inputs, target: AnyObject?) -> [NSMenuItem] {
        AppMenuRenderer.items(AppMenuModel.appSection(inputs), target: target,
                              action: appMenuAction)
    }

    @objc func showMenu(_ sender: NSButton) {
        let menu = NSMenu()
        // In island-only mode this is the only menu there is, so the day's digest
        // has to be reachable from it — otherwise the feature exists for menu bar
        // users and nobody else.
        menu.addItem(MenuBuilder.todayRow(target: self, action: #selector(openPastProject(_:))))
        menu.addItem(.separator())
        for item in Self.appSection(.current, target: self) { menu.addItem(item) }
        // A check started from this menu answers while it is still open: redraw the
        // shared rows in place, the way the menu bar's own dropdown does.
        let watch = NotificationCenter.default.addObserver(
            forName: UpdateChecker.didChange, object: nil, queue: .main) { [weak self, weak menu] _ in
            guard let self, let menu else { return }
            AppMenuRenderer.refresh(menu, with: AppMenuModel.appSection(.current),
                                    target: self, action: Self.appMenuAction)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        NotificationCenter.default.removeObserver(watch)
        // "Up to date" and "failed" are answers for the open that saw them, as in the
        // menu bar's dropdown; left standing, the row would have no action next time.
        UpdateChecker.shared.clearTransient()
    }

    /// Every row of the shared app section lands here; the model decided what the
    /// row says, this only runs it.
    @objc func appMenuClicked(_ sender: NSMenuItem) {
        AppMenuRenderer.action(of: sender)?.perform()
    }

    /// A finished session's project folder — the session itself is gone, so there is
    /// no tab to jump back to. Mirrors `StatusItemController.openPastProject`.
    @objc private func openPastProject(_ sender: NSMenuItem) {
        guard let cwd = sender.representedObject as? String, !cwd.isEmpty,
              FileManager.default.fileExists(atPath: cwd) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: cwd))
    }
}

import AppKit

/// The menu-bar icon and the menu hanging off it.
///
/// One of the app's two possible entry points — the other is the Dock tile — and the only
/// one that exists while the app runs as an agent. Which of them exist is a user setting,
/// so this type never asserts its own visibility: ``Presence`` owns that decision and
/// calls ``setVisible(_:)``.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    static let shared = StatusItemController()

    private let statusItem: NSStatusItem

    private override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "square.stack.3d.up.fill",
                                   accessibilityDescription: "HyperSwitch")
            // Template rendering is what makes the glyph follow the menu bar's own
            // light/dark treatment instead of staying black on a dark bar.
            button.image?.isTemplate = true
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Shows or hides the icon.
    ///
    /// Deliberately not decided here. AppKit also writes the answer into this app's own
    /// defaults (`NSStatusItem Visible …`), which means the icon can come back — or fail
    /// to — for reasons that have nothing to do with `showInMenuBar`; see ``Presence``.
    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    /// Whether the icon is actually in the menu bar right now.
    ///
    /// Read from the status item rather than from the preference: AppKit can override it,
    /// and the point of asking is to find out whether it did.
    var isVisible: Bool { statusItem.isVisible }

    /// Rebuilt on every open so the titles follow a live language change — AppKit menus do
    /// not participate in the SwiftUI environment and would otherwise keep the language
    /// they were first built with.
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    /// Rebuilds the menu in place.
    ///
    /// Exposed as well as being the menu delegate's work because the menu also has to be
    /// correct *before* it is opened: `menuNeedsUpdate` fires as the menu is pulled down,
    /// which is too late for anything that inspects it without a click.
    func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let enabled = Preferences.shared.windowSwitcherEnabled
        let toggle = item(enabled ? "Window Switcher On" : "Window Switcher Off",
                          symbol: enabled ? "square.stack.3d.up.fill"
                                          : "square.stack.3d.up.slash.fill",
                          action: #selector(toggleWindowSwitcher))
        // A checkmark and an icon cannot share the same slot, so the state is carried by
        // the label instead. Left as a plain checked item, AppKit reserves the mark column
        // and every icon in the menu shifts right to make room for it.
        menu.addItem(toggle)

        if !Permissions.shared.allGranted {
            menu.addItem(.separator())
            let warning = item("Permissions needed",
                               symbol: "exclamationmark.triangle.fill",
                               action: #selector(openPermissions))
            // The one item that keeps its colour: without Accessibility the hotkeys are
            // inert, and a grey triangle reads as decoration rather than as a problem.
            warning.image?.isTemplate = false
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        menu.addItem(item("Hide Menu Bar Icon",
                          symbol: "eye.slash",
                          action: #selector(hideMenuBarIcon)))

        menu.addItem(.separator())

        menu.addItem(item("Settings…",
                          symbol: "gearshape",
                          action: #selector(openSettings),
                          key: ","))
        menu.addItem(item("Quit HyperSwitch",
                          symbol: "power",
                          action: #selector(quit),
                          key: "q"))
    }

    /// Builds a menu item with a consistently sized template icon.
    ///
    /// Every item gets one. Give icons to only some of them and macOS still supplies its
    /// own for a standard `⌘,` settings item, so the menu reads as one icon and three
    /// stragglers with the labels failing to line up.
    ///
    /// The symbols are pinned to a `.small` scale configuration so glyphs of differing
    /// natural widths (a gear against a power symbol) occupy the same box and the titles
    /// start on a single vertical line.
    private func item(_ key: String.LocalizationValue,
                      symbol: String,
                      action: Selector,
                      key equivalent: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: Localization.string(key),
                                  action: action,
                                  keyEquivalent: equivalent)
        menuItem.target = self

        let configuration = NSImage.SymbolConfiguration(scale: .small)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        image?.isTemplate = true
        menuItem.image = image
        return menuItem
    }

    @objc private func toggleWindowSwitcher() {
        Preferences.shared.windowSwitcherEnabled.toggle()
        Log.app.debug("menu: windowSwitcherEnabled=\(Preferences.shared.windowSwitcherEnabled)")
    }

    /// Takes the icon out of the menu bar, from the menu itself.
    ///
    /// The setting already existed in Settings ▸ Appearance, which is a strange place to
    /// have to go: the icon is right there under the pointer, and wanting it gone is a
    /// thought people have *while looking at it*. This is the same preference, reached from
    /// where the wish occurs.
    ///
    /// It writes the preference and calls ``Presence/apply()`` rather than hiding the
    /// status item directly. Setting `statusItem.isVisible` here would work for exactly one
    /// run and then diverge: AppKit persists that flag in the app's own defaults, so the
    /// icon would stay hidden while the Appearance switch still read "on", and flipping
    /// that switch off and on again would be the only way to reconcile them. One source of
    /// truth, one place that acts on it.
    ///
    /// The confirmation is conditional, which is the part that differs from HyperDock —
    /// HyperDock's icon is its only way in, so hiding it always deserves a warning. Here
    /// the Dock tile is a second entrance, and interrupting someone to warn about a door
    /// they have not closed is noise. The alert appears only when the Dock tile is already
    /// off and this really is the last one.
    @objc private func hideMenuBarIcon() {
        let preferences = Preferences.shared

        if !preferences.showInDock {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = Localization.string("Hide the menu bar icon?")
            alert.informativeText = Localization.string(
                "The Dock icon is already off, so this removes the last way in. HyperSwitch keeps running and its keyboard shortcuts still work. To bring the icon back, open HyperSwitch again from your Applications folder.")
            alert.addButton(withTitle: Localization.string("Hide Icon"))
            alert.addButton(withTitle: Localization.string("Cancel"))

            // An agent app is never frontmost on its own, and one that is about to give up
            // its last visible surface has no claim on the foreground at all — without this
            // the alert can open behind whatever the user is looking at.
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }

            // The notice this would otherwise trigger later says the same thing, and it has
            // now been said with a choice attached.
            preferences.hasSeenPresenceNotice = true
        }

        preferences.showInMenuBar = false
        Presence.apply()
        Log.app.debug("menu: hid the menu bar icon")
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(selecting: .general)
    }

    @objc private func openPermissions() {
        SettingsWindowController.shared.show(selecting: .about)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

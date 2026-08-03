import AppKit
import SwiftUI

// The entry point is `main.swift`, not a SwiftUI `App`.
//
// `App` requires at least one `Scene`, and the only harmless-looking choice —
// `Settings { EmptyView() }` — is not harmless: it registers a real ⌘, menu item that
// opens a 900×450 completely blank window titled "HyperSwitch Settings", which can then
// sit alongside the actual settings window (780×580) so the user has two windows both
// claiming to be Settings. There is no way to suppress it and keep the scene.
//
// Driving `NSApplication` directly costs four lines and has no scene to suppress. SwiftUI
// is still used for everything it is good at: the settings panes and the switcher panel
// are `NSHostingView`s created on demand.
//
// The one thing the dropped `Scene` did supply, and which had to be written back by hand,
// is the main menu — see ``MainMenuController``.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeys: HotKeyMonitor?
    private var permissionObserver: (any NSObjectProtocol)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Bounds every Accessibility request for the lifetime of the process before any
        // AX call can be made. Only the system-wide element sets a real process default,
        // and it applies retroactively, so this one call covers everything.
        AXCore.installGlobalTimeout()

        // Before anything can decide to take the system's ⌘Tab again. A run that was killed
        // — `pkill` during a rebuild, a panic, a forced restart — never got to hand the
        // shortcut back, and the user is left with a ⌘Tab that does nothing and no running
        // app to connect it to. This is the only thing that notices.
        SystemHotKeys.restoreAfterUnexpectedExit()

        // The event tap reads its policy from a snapshot on its own thread, so the initial
        // values have to be pushed before the tap can see its first keystroke. Without this
        // the tap would spend the first moments of the process deciding from struct
        // defaults rather than from what the user actually configured.
        HotKeyState.shared.publish(preferences: Preferences.shared.hotKeySnapshot)

        // Before `Presence.apply()`, because that is what can make this app `.regular` and
        // therefore the owner of the menu bar. Nothing else installs a main menu, and an
        // app with `NSApp.mainMenu == nil` has no ⌘C/⌘V/⌘X/⌘A/⌘W/⌘Q at all.
        MainMenuController.shared.install()

        // Presence decides the activation policy and the status item, both of which are
        // user settings. It must run before anything can want a window.
        Presence.apply()

        AppList.shared.start()

        let monitor = HotKeyMonitor(controller: SwitcherController.shared)
        hotKeys = monitor

        Permissions.shared.refresh()
        Log.app.debug("""
            launch: accessibility=\(Permissions.shared.hasAccessibility) \
            screenRecording=\(Permissions.shared.hasScreenRecording) \
            bundle=\(Bundle.main.bundlePath, privacy: .public)
            """)

        // Accessibility is what lets the event tap exist at all and what raises windows.
        // Screen Recording only adds thumbnails and window titles, so its absence
        // degrades the switcher rather than disabling it.
        if Permissions.shared.hasAccessibility {
            monitor.start()
            Task { await WindowIndex.shared.refresh() }
        }
        Permissions.shared.beginWatching()
        observePermissionChanges()

        // Never trigger the system prompt at launch. Debug and XCTest builds frequently
        // have new code signatures, so an automatic request becomes a repeated prompt on
        // the same machine. A first launch may show one in-app explanation; only its
        // explicit permission button asks macOS and opens System Settings.
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
        let preferences = Preferences.shared
        if PermissionLaunchPolicy.action(
            hasAccessibility: Permissions.shared.hasAccessibility,
            hasShownIntroduction: preferences.hasShownPermissionIntroduction,
            isRunningTests: isRunningTests
        ) == .showIntroduction {
            preferences.hasShownPermissionIntroduction = true
            SettingsWindowController.shared.show(selecting: .about)
        }
    }

    /// Follows Accessibility in **both** directions for the life of the process.
    ///
    /// The old version was a one-shot: it waited for the first grant and then returned, so
    /// a permission revoked later — or revoked and granted again, which is what a user
    /// does when they are trying to fix something — left the tap dead with nothing
    /// watching. Reacting to every transition is what makes "toggle it off and on again"
    /// work the way the user expects it to.
    private func observePermissionChanges() {
        // The token is kept even though this delegate lives as long as the process. An
        // observer registered with the block form and no stored token can never be
        // removed by anyone, which turns "this object outlives the app anyway" from a
        // fact about today's code into a requirement on tomorrow's.
        permissionObserver = NotificationCenter.default.addObserver(
            forName: Permissions.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Permissions.shared.hasAccessibility {
                    self.hotKeys?.start()
                    Task { await WindowIndex.shared.refresh() }
                } else {
                    // Nothing to drive any more, and a dead tap reporting "running" is how
                    // a bug report ends up pointing at the wrong subsystem.
                    self.hotKeys?.stop()
                    SwitcherController.shared.cancel()
                }
                StatusItemController.shared.rebuildMenu()
            }
        }
    }


    /// Tears down what has an owner outside this object.
    ///
    /// Not `deinit`: under Swift 6 a deinitialiser is nonisolated and cannot touch
    /// main-actor state, which is where all of this lives. This delegate does outlive
    /// everything in practice, so none of it is load-bearing today — it is here so that
    /// "the process was about to exit anyway" stays an observation rather than becoming a
    /// requirement.
    func applicationWillTerminate(_ notification: Notification) {
        if let permissionObserver {
            NotificationCenter.default.removeObserver(permissionObserver)
            self.permissionObserver = nil
        }
        Permissions.shared.stopWatching()
        hotKeys?.stop()
        // `stop()` already does this. Repeated here because it is the one thing whose
        // omission is felt outside this process: leaving the shortcut suppressed hands the
        // user a Mac whose ⌘Tab does nothing, and `setSuppressed` writes only on a real
        // change so the duplicate call costs a comparison.
        SystemHotKeys.restore()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Opening HyperSwitch while it is already running brings the menu bar icon back.
    ///
    /// This is the documented way out of having hidden both the Dock tile and the menu
    /// bar icon, so it has to work from a plain double-click in the Applications folder.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows: Bool) -> Bool {
        // Only when the app has no visible presence at all.
        //
        // This used to run unconditionally, which quietly overwrote a preference the user
        // had deliberately turned off: click the Dock icon — or run `open -a HyperSwitch`
        // — and the menu bar icon reappeared, with the switch in the Appearance pane
        // ticking itself on in front of them if that pane happened to be open. Restoring
        // the icon is the documented escape from having hidden *both* entry points, and
        // that is the only case it should fire in.
        let preferences = Preferences.shared
        if !preferences.showInDock && !preferences.showInMenuBar {
            preferences.showInMenuBar = true
            Presence.apply()
        }
        if !hasVisibleWindows {
            SettingsWindowController.shared.show(selecting: .general)
        }
        return true
    }
}

/// The menu bar the app shows while it is frontmost.
///
/// It exists because nothing else supplies one: the entry point is `main.swift` rather
/// than a SwiftUI `App`, and `Info.plist` names neither `NSMainNibFile` nor
/// `NSPrincipalClass`, so `NSApp.mainMenu` stays nil unless it is built here.
///
/// That is not a cosmetic gap. Cut/Copy/Paste/Select All are delivered to a text field
/// *only* as Edit-menu key equivalents — AppKit's `StandardKeyBinding.dict` has no
/// `@c`/`@v`/`@x`/`@a` entry — so with no main menu ⌘V into a number field in the settings
/// window silently does nothing, and so do ⌘A, ⌘C, ⌘X, ⌘W and ⌘Q. Right-click ▸ Paste kept
/// working throughout, because `NSTextView` builds its context menu in code; the keyboard
/// was the only broken path, which is why it went unnoticed.
///
/// It is reachable on a first run with no interaction at all: the settings window opens by
/// itself when Accessibility has not been granted yet, and ``Presence/settingsOpened()``
/// promotes the app to `.regular` whenever that window is up — so the empty menu bar is
/// not conditional on the `showInDock` default either.
@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    static let shared = MainMenuController()

    /// Every title this class owns, paired with the key it was drawn from.
    ///
    /// Kept so a live language change can be applied in place. AppKit menus do not
    /// participate in the SwiftUI environment, so nothing else would ever retranslate
    /// them; the same problem is why ``StatusItemController`` rebuilds on open.
    private var itemTitles: [(item: NSMenuItem, key: String.LocalizationValue)] = []
    private var menuTitles: [(menu: NSMenu, key: String.LocalizationValue)] = []

    private override init() { super.init() }

    /// Builds the whole menu once and hands it to AppKit. Never called twice.
    ///
    /// Everything — key equivalents included — is created here, so key matching works from
    /// the very first keystroke rather than only after a menu has been pulled down once.
    func install() {
        let bar = NSMenu()
        bar.delegate = self

        // AppKit draws the process name over the first submenu's title whatever it says,
        // and the item order below is the one macOS users reach for without looking.
        let application = submenu(title: "HyperSwitch", in: bar)
        application.addItem(item("About HyperSwitch",
                                 action: #selector(openAbout), target: self))
        application.addItem(.separator())
        // ⌘, duplicates the status-bar menu's item on purpose: a status item's key
        // equivalents only fire while that menu is open, so this is the only ⌘, the
        // settings window itself ever sees.
        application.addItem(item("Settings…",
                                 action: #selector(openSettings), target: self, key: ","))
        application.addItem(.separator())
        application.addItem(item("Hide HyperSwitch",
                                 action: #selector(NSApplication.hide(_:)), key: "h"))
        application.addItem(item("Hide Others",
                                 action: #selector(NSApplication.hideOtherApplications(_:)),
                                 key: "h", modifiers: [.command, .option]))
        application.addItem(item("Show All",
                                 action: #selector(NSApplication.unhideAllApplications(_:))))
        application.addItem(.separator())
        application.addItem(item("Quit HyperSwitch",
                                 action: #selector(NSApplication.terminate(_:)), key: "q"))

        // The reason this file grew a menu at all: these four items are the entire delivery
        // mechanism for ⌘X/⌘C/⌘V/⌘A on macOS.
        //
        // Undo and Redo were here too and have been removed. AppKit owns those two titles —
        // it rewrites them from the responder chain's undo manager — so ours were
        // overwritten with AppKit's own, which follow the *bundle's* language rather than
        // the one the user picked in the About pane. Observed: every other item read 剪切 /
        // 拷贝 / 粘贴 / 全选 while these two stayed "Undo" / "Redo". Since nothing in this
        // app vends an undo manager, they were also permanently disabled — two dead items
        // that could not be translated, in a menu that exists to make four live ones work.
        let edit = submenu(title: "Edit", in: bar)
        edit.addItem(item("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        edit.addItem(item("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        edit.addItem(item("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        edit.addItem(item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))

        let window = submenu(title: "Window", in: bar)
        window.addItem(item("Minimize",
                            action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        window.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("Close", action: #selector(NSWindow.performClose(_:)), key: "w"))

        NSApp.mainMenu = bar
        // Safe to hand AppKit the window list: the switcher panel is borderless and
        // non-activating and is only ever ordered in with `orderFrontRegardless()`, so it
        // is not eligible to be listed here and cannot pick up a key equivalent from this
        // menu — during a switch HyperSwitch is not the frontmost app in the first place.
        NSApp.windowsMenu = window
    }

    /// Retitles in place. Deliberately not a rebuild.
    ///
    /// AppKit calls this on every menu in the bar while it matches a ⌘ key equivalent, not
    /// only when a menu is pulled down. A delegate that answered by emptying and refilling
    /// its menu would be swapping items out from under the keystroke being matched, for no
    /// gain; assigning titles is correct in both situations.
    ///
    /// All menus are retitled rather than just the one being updated, because the titles
    /// standing in the bar belong to menus other than the one that opened, and this is the
    /// only moment the app hears about the menus at all — `Preferences.language` posts no
    /// notification, it is a plain `UserDefaults` pass-through that SwiftUI views observe
    /// through `Preferences.revision`.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for entry in itemTitles { entry.item.title = Localization.string(entry.key) }
        for entry in menuTitles { entry.menu.title = Localization.string(entry.key) }
    }

    /// Adds a top-level menu to the bar and registers **both** of its titles.
    ///
    /// The bar draws the submenu's own title while menu-item lookups see the holder's, and
    /// setting both from one key is what keeps them from disagreeing after a language
    /// change.
    private func submenu(title key: String.LocalizationValue, in bar: NSMenu) -> NSMenu {
        let title = Localization.string(key)
        let menu = NSMenu(title: title)
        menu.delegate = self

        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        bar.addItem(holder)

        itemTitles.append((holder, key))
        menuTitles.append((menu, key))
        return menu
    }

    private func item(_ key: String.LocalizationValue,
                      action: Selector,
                      target: AnyObject? = nil,
                      key equivalent: String = "",
                      modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let menuItem = NSMenuItem(title: Localization.string(key),
                                  action: action,
                                  keyEquivalent: equivalent)
        // `nil` for every standard item, which is the whole point of them: the action has
        // to reach whoever is editing — the field editor for ⌘C/⌘V, the key window for ⌘W —
        // by walking the responder chain. Aiming it at this controller instead would send
        // each of them nowhere, which is the state being fixed.
        menuItem.target = target
        menuItem.keyEquivalentModifierMask = modifiers
        itemTitles.append((menuItem, key))
        return menuItem
    }

    @objc private func openAbout() {
        // The app has its own About pane, so this opens that rather than
        // `orderFrontStandardAboutPanel:` — two different About windows for one app is
        // exactly the duplication that killed the SwiftUI `Settings` scene.
        SettingsWindowController.shared.show(selecting: .about)
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.show(selecting: .general)
    }
}

import AppKit

/// Where the app is visible from: the Dock, the menu bar, both, or neither.
///
/// Both surfaces are user settings, and both are also touched by AppKit behind our back —
/// the activation policy has to move for the settings window to be usable, and AppKit
/// persists the status item's visibility on its own. Concentrating every change here is
/// what keeps the preferences authoritative rather than advisory.
@MainActor
enum Presence {

    /// Makes the app's visible surfaces match the preferences.
    ///
    /// Safe — and expected — to call repeatedly: any pane that writes `showInDock` or
    /// `showInMenuBar` calls straight back in here.
    static func apply() {
        let preferences = Preferences.shared

        // Dropping to `.accessory` while the settings window is up takes its keyboard
        // focus away mid-edit, for exactly the reason `settingsOpened()` exists. That is
        // the common case rather than a corner one, because unchecking "Show in the Dock"
        // is itself a write that lands here while the window is open. The demotion is
        // deferred to `settingsClosed()`, which calls this again.
        let wanted: NSApplication.ActivationPolicy = preferences.showInDock ? .regular : .accessory
        let target = SettingsWindowController.shared.isOpen ? .regular : wanted

        // Only when it actually differs. `apply()` runs on every write of *any* preference
        // that touches presence, and each `.accessory → .regular` transition leaves a
        // menu-bar window behind: observed four of them, full width and 39 pt tall at the
        // top of the screen, after a run that toggled the Dock setting a handful of times.
        // Re-asserting a policy the app already has is what accumulates them.
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }

        // Assigned on every apply, never merely at launch. AppKit stores a status item's
        // visibility in this app's own defaults ("NSStatusItem Visible …") and restores it
        // when the item is created, so a run in which the icon was hidden keeps hiding it
        // afterwards regardless of what `showInMenuBar` says. Writing it unconditionally
        // is what makes the preference win.
        StatusItemController.shared.setVisible(preferences.showInMenuBar)
    }

    /// Brings the app forward for the settings window.
    ///
    /// The policy change is not cosmetic. An agent app is never frontmost, and macOS's
    /// cooperative activation ignores `activate` coming from one — without promoting to
    /// `.regular` first the window arrives visible and clickable but *without keyboard
    /// focus*: measured, `AXFocused` stays false and typing goes to whichever app is
    /// actually in front, which makes every number field in the settings unusable.
    static func settingsOpened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Restores the preferred presence once the settings window is gone.
    static func settingsClosed() {
        // Deferred by one runloop turn: the window is still closing, and dropping the
        // policy out from under it leaves the app frontmost with nothing to show — a
        // blank space where the window was, until something else is clicked.
        Task { @MainActor in
            apply()
        }
    }

    /// Explains, once, how to get back in after hiding both surfaces.
    ///
    /// Turning both off is allowed — the switcher is a keyboard feature and works fine
    /// with no visible entry point at all — but it is also the one setting that can hide
    /// the way to undo itself, so it gets said out loud the first time.
    static func warnIfHiddenEverywhere() {
        let preferences = Preferences.shared
        guard !preferences.showInDock,
              !preferences.showInMenuBar,
              !preferences.hasSeenPresenceNotice
        else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = Localization.string("HyperSwitch is now hidden")
        alert.informativeText = Localization.string(
            "It keeps running and its keyboard shortcuts still work. To bring the menu bar icon back, open HyperSwitch again from your Applications folder.")
        alert.addButton(withTitle: Localization.string("OK"))

        // Without this the alert can open behind whatever is frontmost: an app that has
        // just given up both its Dock tile and its menu bar icon has no claim on the
        // foreground left.
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()

        preferences.hasSeenPresenceNotice = true
    }
}

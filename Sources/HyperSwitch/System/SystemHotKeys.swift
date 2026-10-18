import CoreGraphics
import Foundation

/// The system's own ⌘Tab, switched off at the source rather than swallowed.
///
/// Swallowing is what the event tap does, and it is not the same thing. A tap only has to
/// miss one keystroke — the WindowServer disables any tap that overruns its budget, and it
/// does so *silently* — for the native switcher to appear over ours. Observed in practice:
/// with the pointer resting on the panel, four or five ⌘Tab presses in a row were enough,
/// and the unified log showed the tap being re-enabled by the health check nineteen times
/// in six minutes. Every one of those was a window in which ⌘Tab reached the Dock.
///
/// So the tap is the mechanism and this is the backstop. With the shortcut genuinely off,
/// the worst a dead tap can do is nothing at all, which is a far better failure than the
/// system switcher appearing on top of a switcher the user installed to replace it.
///
/// **The identifiers were measured, not looked up.** Walking `CGSGetSymbolicHotKeyValue`
/// over every identifier and keeping those whose virtual key code is 48 (Tab) returns
/// exactly two on macOS 26: **1** for ⌘Tab and **2** for ⇧⌘Tab. The 71/72 pair that several
/// open-source switchers use is something else here — both already read back *disabled* on
/// a machine whose ⌘Tab works perfectly, so writing to them would have changed nothing and
/// looked like the fix.
///
/// `nonisolated` so the tap's health check can call it from wherever it runs.
nonisolated enum SystemHotKeys {

    // MARK: - Symbols

    /// `RTLD_DEFAULT`. Same reasoning as ``CGS``: resolve at runtime so a macOS that
    /// renames the symbol loses the backstop instead of preventing launch.
    private nonisolated(unsafe) static let handle = UnsafeMutableRawPointer(bitPattern: -2)

    private static func resolve<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let _setEnabled =
        resolve("CGSSetSymbolicHotKeyEnabled",
                as: (@convention(c) (Int32, DarwinBoolean) -> Int32).self)

    private static let _isEnabled =
        resolve("CGSIsSymbolicHotKeyEnabled",
                as: (@convention(c) (Int32) -> DarwinBoolean).self)

    private static let _hotKeyValue = resolve(
        "CGSGetSymbolicHotKeyValue",
        as: (@convention(c) (Int32, UnsafeMutablePointer<unichar>,
                             UnsafeMutablePointer<unichar>,
                             UnsafeMutablePointer<Int32>) -> Int32).self)

    private static let commandTab: Int32 = 1
    private static let commandShiftTab: Int32 = 2

    // MARK: - "Switch to Desktop N"

    /// The identifier of the system's own "Switch to Desktop *n*" shortcut.
    ///
    /// These exist for every desktop whether or not the user has bound one in System
    /// Settings — 117 + n, for n in 1…16, which is as many as macOS defines. Posting one is
    /// the only route to another Space that leaves the Dock's own model consistent; see
    /// ``SpaceSwitcher``.
    static func desktopHotKey(number: Int) -> Int32? {
        guard (1...16).contains(number) else { return nil }
        return Int32(117 + number)
    }

    /// The key combination a symbolic hotkey is bound to, so it can be posted.
    static func binding(for id: Int32) -> (key: CGKeyCode, flags: CGEventFlags)? {
        guard let (key, modifiers) = rawBinding(for: id) else { return nil }

        // Carbon modifier masks, the same ones `SystemShortcutReader` decodes.
        var flags = CGEventFlags()
        if modifiers & 0x0002_0000 != 0 { flags.insert(.maskShift) }
        if modifiers & 0x0004_0000 != 0 { flags.insert(.maskControl) }
        if modifiers & 0x0008_0000 != 0 { flags.insert(.maskAlternate) }
        if modifiers & 0x0010_0000 != 0 { flags.insert(.maskCommand) }
        return (key, flags)
    }

    /// The binding as the table stores it, Carbon modifier mask and all.
    ///
    /// For readers that need the bits ``binding(for:)`` drops — the fn bit above all,
    /// which macOS 26 uses for a whole family of shortcuts of its own.
    static func rawBinding(for id: Int32) -> (key: CGKeyCode, carbonModifiers: Int32)? {
        guard let value = _hotKeyValue else { return nil }
        var equivalent: unichar = 0
        var virtualKey: unichar = 0
        var modifiers: Int32 = 0
        guard value(id, &equivalent, &virtualKey, &modifiers) == 0 else { return nil }
        return (CGKeyCode(virtualKey), modifiers)
    }

    static func isEnabled(_ id: Int32) -> Bool {
        _isEnabled?(id).boolValue ?? false
    }

    static func setEnabled(_ id: Int32, _ enabled: Bool) {
        _ = _setEnabled?(id, DarwinBoolean(enabled))
    }

    // MARK: - Crash-safe bookkeeping

    /// Set while the shortcut is ours, cleared once it has been given back.
    ///
    /// The whole point is the case where neither happens: the process is killed, or panics,
    /// while the shortcut is off. Nothing would restore it, and the user is left with a Mac
    /// whose ⌘Tab does nothing and no way to connect that to an app that is no longer
    /// running. ``restoreAfterUnexpectedExit()`` reads this at launch and hands the shortcut
    /// back before anything else can decide to take it again.
    private static let suppressedKey = "systemCommandTabSuppressed"

    /// What the shortcut was set to before we first touched it.
    private static let wasEnabledKey = "systemCommandTabWasEnabled"

    /// True when the SPI is present at all. False makes every other call here a no-op.
    static var isAvailable: Bool { _setEnabled != nil && _isEnabled != nil }

    /// Whether the system switcher is currently off.
    ///
    /// Read from the WindowServer rather than from our own bookkeeping, because the two can
    /// disagree: another application can take the same shortcut, and a user can change it in
    /// System Settings while we are running.
    static var isSuppressed: Bool {
        guard let isEnabled = _isEnabled else { return false }
        return !isEnabled(commandTab).boolValue
    }

    // MARK: - Control

    /// Brings the system switcher to the requested state, writing only when it differs.
    ///
    /// The write is skipped when the state already matches so this can be called from a
    /// quarter-second health check without touching the WindowServer four times a second.
    static func setSuppressed(_ suppressed: Bool) {
        guard let setEnabled = _setEnabled, let isEnabled = _isEnabled else { return }

        let defaults = UserDefaults.standard
        if suppressed {
            // Recorded before the first suppression only. Re-reading it on every call would
            // capture our own suppression as "what it was before", and the shortcut would
            // never be given back.
            if !defaults.bool(forKey: suppressedKey) {
                defaults.set(isEnabled(commandTab).boolValue, forKey: wasEnabledKey)
            }
        }

        let target = !suppressed
        guard isEnabled(commandTab).boolValue != target
            || isEnabled(commandShiftTab).boolValue != target
        else {
            // This branch is the one the quarter-second health check takes almost every
            // time, so the bookkeeping is held to the same "only when it differs" rule as
            // the WindowServer write — an unconditional `set` here was four preference
            // writes a second for the life of the process.
            if defaults.bool(forKey: suppressedKey) != suppressed {
                defaults.set(suppressed, forKey: suppressedKey)
            }
            return
        }

        // ⇧⌘Tab is a separate identifier and has to be taken with its partner. Left enabled,
        // "previous application" would open the native switcher while "next application"
        // opened ours.
        _ = setEnabled(commandTab, DarwinBoolean(target))
        _ = setEnabled(commandShiftTab, DarwinBoolean(target))
        defaults.set(suppressed, forKey: suppressedKey)

        Log.hotkeys.debug("system ⌘Tab \(suppressed ? "suppressed" : "restored", privacy: .public)")
    }

    /// Hands the shortcut back if a previous run of this app died holding it.
    ///
    /// Called once at launch, before anything decides to suppress again. Restoring to the
    /// *recorded* value rather than unconditionally to "enabled" matters for the user who
    /// had already turned ⌘Tab off themselves; handing them back a shortcut they had
    /// deliberately disabled would be its own small bug.
    static func restoreAfterUnexpectedExit() {
        guard UserDefaults.standard.bool(forKey: suppressedKey) else { return }
        Log.hotkeys.error("previous run exited while holding the system ⌘Tab; restoring it")
        giveBack()
    }

    /// Gives the shortcut back. For termination and for revoked permissions.
    ///
    /// Gated on our own bookkeeping and nothing else. Falling back to "…or it looks
    /// suppressed" was wrong in a way that is easy to miss: a user who had switched ⌘Tab
    /// off themselves in System Settings, and never let this app take it, would have had it
    /// switched back **on** the first time the tap failed to install — this app reaching in
    /// and undoing a deliberate system setting it was never asked to touch. If we did not
    /// suppress it, it is not ours to restore.
    static func restore() {
        guard UserDefaults.standard.bool(forKey: suppressedKey) else { return }
        giveBack()
    }

    /// Returns the shortcut to its recorded state and gives up the claim on it.
    ///
    /// Both halves, separately. This used to be `setSuppressed(!wasEnabled)`, which is
    /// right for the shortcut but wrong for the bookkeeping whenever the user had ⌘Tab
    /// off before we arrived: "restore to off" *is* `setSuppressed(true)`, which records
    /// the claim as still held. Every clean quit then looked like a crash to the next
    /// launch, and `restoreAfterUnexpectedExit` logged an exit that never happened.
    private static func giveBack() {
        let defaults = UserDefaults.standard
        let wasEnabled = defaults.object(forKey: wasEnabledKey) as? Bool ?? true
        if wasEnabled {
            setSuppressed(false)
        }
        // A user who had it off gets it back off, which is how we found it: there is
        // nothing to write to the WindowServer, only the claim to drop.
        defaults.set(false, forKey: suppressedKey)
    }
}

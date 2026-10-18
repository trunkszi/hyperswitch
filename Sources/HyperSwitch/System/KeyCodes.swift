import CoreGraphics

/// Virtual key codes, and the keycap legend to print for each one.
///
/// The numbers are written out rather than imported from Carbon's `kVK_*` constants:
/// pulling `Carbon.HIToolbox` into a Swift 6 target costs a large legacy module for
/// eleven integers, and these particular integers cannot drift — a virtual key code
/// names a *physical position* on the Apple Extended Keyboard layout and has been fixed
/// since ADB. That positional nature is also why code 50 is labelled `§ / \``: it is the
/// key left of `1`, which is engraved `` ` `` on ANSI boards and `§` on ISO ones.
///
/// `nonisolated` throughout because the event tap callback reads these from a CFRunLoop
/// thread, which under `-default-isolation=MainActor` cannot see main-actor statics.
enum KeyCodes {

    // MARK: - The keys the switcher itself reacts to

    nonisolated static let tab: CGKeyCode = 48
    nonisolated static let graveAccent: CGKeyCode = 50
    nonisolated static let escape: CGKeyCode = 53
    nonisolated static let returnKey: CGKeyCode = 36
    nonisolated static let leftArrow: CGKeyCode = 123
    nonisolated static let rightArrow: CGKeyCode = 124
    nonisolated static let downArrow: CGKeyCode = 125
    nonisolated static let upArrow: CGKeyCode = 126
    nonisolated static let space: CGKeyCode = 49
    nonisolated static let w: CGKeyCode = 13
    nonisolated static let q: CGKeyCode = 12
    nonisolated static let delete: CGKeyCode = 51
    nonisolated static let slash: CGKeyCode = 44

    // MARK: - Legends

    /// The legend for a key code, or `Key 87` for one we have no engraving for.
    ///
    /// These are deliberately **not** localised. A legend names what is printed on the
    /// physical keycap, which does not change with the interface language — a Chinese
    /// user's Tab key still says `tab` — and translating them would leave the settings
    /// picker describing a key the keyboard does not have.
    nonisolated static func label(for code: CGKeyCode) -> String {
        legends[code] ?? "Key \(code)"
    }

    /// The keys offered in the "current app's windows" hotkey picker, in the order they
    /// are listed.
    ///
    /// Built by mapping ``label(for:)`` over an ordered list of codes so a key can never
    /// be offered without a legend — the two used to be one hand-written table, which is
    /// the kind of thing that ships a picker row reading `Key 42`.
    ///
    /// The first three are the plausible defaults: the original HyperSwitch shipped with
    /// 50, and 10 is the same physical position reported by an ISO keyboard.
    nonisolated static let selectable: [(code: CGKeyCode, label: String)] =
        selectableOrder.map { (code: $0, label: label(for: $0)) }

    /// Whether a key can serve as the current-app switcher's cycle key.
    ///
    /// Escape and Space were both offered and neither can do the job. The cycle key is the
    /// one tapped *inside* a session to move along, and inside a session both already mean
    /// something that is decided before the cycle key is ever consulted: Escape cancels,
    /// Space latches. Bound to either, ⌥⎋ opened the switcher and the next ⎋ closed it,
    /// so the binding could open a session but never step through one. Return is refused
    /// for the same reason — it commits — though it was never in the list.
    nonisolated static func isUsableAsCycleKey(_ code: Int) -> Bool {
        code != Int(escape) && code != Int(space) && code != Int(returnKey)
    }

    private nonisolated static let selectableOrder: [CGKeyCode] = [
        50, 48, 10,
        // F1–F12. Not consecutive, and not in numeric order: F5–F12 were added to the
        // keyboard after F1–F4, so their codes were assigned wherever there was room.
        122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
        // A–Z, alphabetical. The codes are the QWERTY *positions*, which is why they
        // look scrambled here (A=0, S=1, D=2, F=3 walk the home row).
        0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46,
        45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6,
    ]

    private nonisolated static let legends: [CGKeyCode: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",

        // 10 is the extra key an ISO keyboard has and an ANSI one does not; on Apple's
        // ISO boards it sits left of `1` and is engraved `§ / ±`.
        10: "§ (ISO)",
        36: "↩ (Return)",
        48: "⇥ (Tab)",
        49: "␣ (Space)",
        50: "§ / `",
        53: "⎋ (Escape)",

        96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1",

        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

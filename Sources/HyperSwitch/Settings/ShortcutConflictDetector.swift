import CoreGraphics
import Foundation

nonisolated enum ShortcutSource: Sendable, Equatable {
    case hyperSwitch
    case system
}

nonisolated struct ShortcutBinding: Identifiable, Sendable, Equatable {
    let id: String
    let label: String
    let modifiers: ModifierCombo
    let keyCode: CGKeyCode
    let source: ShortcutSource
    var enabled = true

    var displayValue: String { "\(modifiers.symbols)\(KeyCodes.label(for: keyCode))" }
}

nonisolated enum ShortcutConflictKind: Sendable, Equatable {
    case internalDuplicate
    case systemOccupied
}

nonisolated struct ShortcutConflict: Sendable, Equatable {
    let kind: ShortcutConflictKind
    let binding: ShortcutBinding
    let conflictingWith: ShortcutBinding
}

nonisolated enum ShortcutConflictDetector {
    static func conflicts(hyperSwitch: [ShortcutBinding],
                          system: [ShortcutBinding]) -> [ShortcutConflict] {
        let own = hyperSwitch.filter(\.enabled)
        let macOS = system.filter(\.enabled)
        var result: [ShortcutConflict] = []

        for leftIndex in own.indices {
            for rightIndex in own.indices where rightIndex > leftIndex {
                let left = own[leftIndex]
                let right = own[rightIndex]
                if sameCombination(left, right) {
                    result.append(ShortcutConflict(
                        kind: .internalDuplicate,
                        binding: left,
                        conflictingWith: right
                    ))
                }
            }
        }

        for binding in own {
            for occupied in macOS where sameCombination(binding, occupied) {
                result.append(ShortcutConflict(
                    kind: .systemOccupied,
                    binding: binding,
                    conflictingWith: occupied
                ))
            }
        }
        return result
    }

    private static func sameCombination(_ lhs: ShortcutBinding, _ rhs: ShortcutBinding) -> Bool {
        lhs.modifiers == rhs.modifiers && lhs.keyCode == rhs.keyCode
    }
}

/// Reads the macOS symbolic shortcuts that are currently live.
@MainActor
enum SystemShortcutReader {
    /// Asked of the WindowServer first, and of the preference file only if it cannot say.
    ///
    /// `com.apple.symbolichotkeys` holds only the shortcuts a user has *changed*. One that
    /// is still on its factory binding has no entry there at all, which is most of them —
    /// including ⌘`, "move focus to the next window", the single most likely thing for a
    /// current-app switcher to be bound over. The detector therefore reported no conflict
    /// for exactly the combinations that conflict on a fresh Mac. The WindowServer's own
    /// table, the one `SystemHotKeys` already reads to find ⌘Tab, answers for defaults and
    /// changes alike.
    ///
    /// Held for a second. The General pane asks from its `body`, which SwiftUI re-runs on
    /// every preference change — a slider drag included — and a full pass over the table
    /// is about a thousand WindowServer calls, measured at 5–20 ms. A second is still
    /// short enough to pick up a shortcut changed in System Settings by the time the user
    /// has switched back to this window.
    static func current() -> [ShortcutBinding] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cached, now - cached.at < 1 { return cached.bindings }
        let bindings = SystemHotKeys.isAvailable ? live() : stored()
        cached = (now, bindings)
        return bindings
    }

    private static var cached: (at: TimeInterval, bindings: [ShortcutBinding])?

    /// Every enabled, bound identifier in the WindowServer's table.
    ///
    /// 0..<512 is wider than macOS uses — measured on macOS 26 the highest identifier with
    /// a value is 264 — so a new one is picked up without this changing. ⌘Tab and ⇧⌘Tab
    /// are left out: they are the pair this app takes over on purpose, so reporting the App
    /// Switcher row as "occupied" by them would flag the one combination that is meant to
    /// collide.
    private static func live() -> [ShortcutBinding] {
        (0..<512).compactMap { raw -> ShortcutBinding? in
            let identifier = Int32(raw)
            guard identifier != 1, identifier != 2,
                  SystemHotKeys.isEnabled(identifier),
                  let binding = SystemHotKeys.rawBinding(for: identifier),
                  // 0xFFFF is the table's "no key"; an identifier can be enabled and unbound.
                  binding.key != 0xFFFF
            else { return nil }
            var modifiers = modifierCombo(carbonFlags: UInt(UInt32(bitPattern: binding.carbonModifiers)))
            // The arrows and the F keys carry the fn bit as part of what they *are* — ⌃←
            // is stored as fn⌃← — so it says nothing about what the user holds. Kept, it
            // would stop every such shortcut matching the same combination here.
            if fnIsImplicit(binding.key) { modifiers.remove(.function) }
            guard !modifiers.isEmpty else { return nil }
            return ShortcutBinding(
                id: "system-\(identifier)",
                label: String(
                    format: Localization.string("macOS shortcut %@"),
                    String(identifier)
                ),
                modifiers: modifiers,
                keyCode: binding.key,
                source: .system
            )
        }
    }

    /// The preference file's view, for a macOS where the WindowServer SPI is gone.
    private static func stored() -> [ShortcutBinding] {
        guard let domain = UserDefaults.standard.persistentDomain(
            forName: "com.apple.symbolichotkeys"
        ), let shortcuts = domain["AppleSymbolicHotKeys"] as? [String: Any]
        else { return [] }

        return shortcuts.compactMap { identifier, raw in
            guard let entry = raw as? [String: Any],
                  (entry["enabled"] as? NSNumber)?.boolValue == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber],
                  parameters.count >= 3
            else { return nil }

            let keyCode = CGKeyCode(truncating: parameters[1])
            guard keyCode != CGKeyCode.max else { return nil }
            let modifiers = modifierCombo(carbonFlags: parameters[2].uintValue)
            guard !modifiers.isEmpty else { return nil }
            return ShortcutBinding(
                id: "system-\(identifier)",
                label: String(
                    format: Localization.string("macOS shortcut %@"),
                    identifier
                ),
                modifiers: modifiers,
                keyCode: keyCode,
                source: .system
            )
        }
    }

    /// Keys whose events always carry the fn bit: the arrows, the navigation cluster and
    /// F1–F20.
    private static func fnIsImplicit(_ key: CGKeyCode) -> Bool {
        switch key {
        case 123...126,                                       // arrows
             114...121,                                       // help…pgdn, with F2 and F4
             122, 99, 96, 97, 98, 100, 101, 109, 103, 111,    // the rest of F1–F12
             105, 107, 113, 106, 64, 79, 80, 90:              // F13–F20
            return true
        default:
            return false
        }
    }

    private static func modifierCombo(carbonFlags: UInt) -> ModifierCombo {
        var combo: ModifierCombo = []
        if carbonFlags & 0x0002_0000 != 0 { combo.insert(.shift) }
        if carbonFlags & 0x0004_0000 != 0 { combo.insert(.control) }
        if carbonFlags & 0x0008_0000 != 0 { combo.insert(.option) }
        if carbonFlags & 0x0010_0000 != 0 { combo.insert(.command) }
        if carbonFlags & 0x0080_0000 != 0 { combo.insert(.function) }
        return combo
    }
}

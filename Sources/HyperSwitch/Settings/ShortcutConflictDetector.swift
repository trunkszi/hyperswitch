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

/// Reads the enabled entries System Settings stores for macOS symbolic shortcuts.
@MainActor
enum SystemShortcutReader {
    static func current() -> [ShortcutBinding] {
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

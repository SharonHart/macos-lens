import Foundation

public struct Shortcut: Equatable, Sendable {
    // Same bit values as NSEvent.ModifierFlags and the com.apple.symbolichotkeys parameters.
    public static let shift: UInt = 1 << 17
    public static let control: UInt = 1 << 18
    public static let option: UInt = 1 << 19
    public static let command: UInt = 1 << 20
    private static let relevantModifiers = shift | control | option | command

    public let id: String
    public let title: String
    public let keyCode: UInt32
    public let modifiers: UInt

    public static let all = [
        Shortcut(id: "command-shift-2", title: "Command + Shift + 2", keyCode: 19, modifiers: command | shift),
        Shortcut(id: "control-shift-space", title: "Control + Shift + Space", keyCode: 49, modifiers: control | shift),
        Shortcut(id: "control-option-space", title: "Control + Option + Space", keyCode: 49, modifiers: control | option)
    ]
    public static let standard = all[0]

    /// Shortcuts that open the overlay straight in Text mode.
    public static let textOptions = [
        Shortcut(id: "command-shift-1", title: "Command + Shift + 1", keyCode: 18, modifiers: command | shift),
        Shortcut(id: "control-shift-1", title: "Control + Shift + 1", keyCode: 18, modifiers: control | shift),
        Shortcut(id: "control-option-t", title: "Control + Option + T", keyCode: 17, modifiers: control | option)
    ]

    /// The saved Text shortcut, or the first option that macOS isn't using and that differs from `other`.
    public static func text(named id: String?, avoiding other: Shortcut,
                            symbolicHotKeys: [String: Any]?) -> Shortcut {
        if let saved = textOptions.first(where: { $0.id == id }) { return saved }
        return textOptions.first { !$0.conflictsWithSystem(symbolicHotKeys) && !$0.overlaps(other) } ?? textOptions[0]
    }

    public func overlaps(_ other: Shortcut) -> Bool {
        keyCode == other.keyCode && modifiers == other.modifiers
    }

    public static func named(_ id: String?) -> Shortcut {
        all.first { $0.id == id } ?? standard
    }

    // Enabled by macOS even when the user's symbolic hot key preferences omit them.
    private static let systemDefaults: [String: (keyCode: UInt32, modifiers: UInt)] = [
        "60": (49, control),
        "61": (49, control | option),
        "64": (49, command),
        "65": (49, command | option)
    ]

    public func conflictsWithSystem(_ symbolicHotKeys: [String: Any]?) -> Bool {
        func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
        var active = Shortcut.systemDefaults
        for (id, entry) in symbolicHotKeys ?? [:] {
            guard let entry = entry as? [String: Any] else { continue }
            if number(entry["enabled"]) == 0 {
                active.removeValue(forKey: id)
                continue
            }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any], parameters.count >= 3,
                  let key = number(parameters[1]), let flags = number(parameters[2]),
                  key >= 0, flags >= 0 else { continue }
            active[id] = (UInt32(key), UInt(flags) & Shortcut.relevantModifiers)
        }
        return active.values.contains { $0.keyCode == keyCode && $0.modifiers == modifiers }
    }
}

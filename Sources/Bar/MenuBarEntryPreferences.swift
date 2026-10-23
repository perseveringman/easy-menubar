import Foundation

/// Stable identity prevents anonymous Item-0 preferences from losing our entry.
/// Position zero is a best-effort macOS preference, not an API guarantee that
/// third-party items can outrank Apple's system controls or other managers.
enum MenuBarEntryPreferences {
    static let name = "BarControl"

    static func prepare(in defaults: UserDefaults = .standard) {
        defaults.set(0, forKey: StatusItemPreferences.preferredPositionPrefix + name)
        defaults.set(true, forKey: StatusItemPreferences.visiblePrefix + name)
        defaults.set(true, forKey: StatusItemPreferences.visibleCCPrefix + name)
        defaults.synchronize()
    }
}

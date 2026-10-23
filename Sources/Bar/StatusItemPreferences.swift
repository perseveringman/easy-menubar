//
//  StatusItemPreferences.swift
//  Bar
//
//  macOS keeps the visibility of every status item in the *owning app's*
//  preferences, under these keys:
//
//      NSStatusItem Preferred Position <autosave name>   – where the item sits
//      NSStatusItem Visible <autosave name>               – macOS 13 and older
//      NSStatusItem VisibleCC <autosave name>             – macOS 26 and newer
//
//  `VisibleCC` is the one the system writes on macOS 26, where every status
//  item is hosted by Control Center. Flipping it is how an item is hidden;
//  the owner picks the change up the next time it builds its status item.
//
//  Preference discovery is handled by the cached scanner. Container reads
//  are opt-in so an App Data decision never blocks the initial list.
//
//  Two wrinkles this type deals with:
//
//  * Sandboxed apps keep their preferences inside their container, so the
//    plist has to be read from `~/Library/Containers/…` and written through
//    `defaults`, which resolves the container for us.
//  * Writes and read-back use the same bounded `defaults` domain resolver,
//    instead of waiting on a protected container file after an action.
//

import Foundation

enum StatusItemPreferences {
    /// One status item an app declares, with its current state.
    struct Record: Sendable {
        let autosaveName: String
        /// `true` when the item currently shows in the menu bar.
        let isVisible: Bool
        /// The position macOS remembers for the item, used to order items
        /// that belong to the same app.
        let position: Int
        var hasKnownPosition = true
    }

    // MARK: - Keys

    static let preferredPositionPrefix = "NSStatusItem Preferred Position "
    static let visiblePrefix = "NSStatusItem Visible "
    static let visibleCCPrefix = "NSStatusItem VisibleCC "

    /// The key that controls visibility on this system.
    static var visibilityPrefix: String {
        if #available(macOS 26.0, *) { return visibleCCPrefix }
        return visiblePrefix
    }

    // MARK: - Reading

    /// Every status item the given app declares, with its current state.
    static func records(in preferences: [String: Any]) -> [Record] {
        var names: Set<String> = []
        for key in preferences.keys where autosaveName(in: key) != nil {
            names.insert(autosaveName(in: key)!)
        }
        guard !names.isEmpty else { return [] }

        return names.compactMap { name in
            // macOS 26 writes `VisibleCC`; older systems only have `Visible`.
            // No flag means the system never touched the item: it shows.
            let isVisible = boolValue(visibilityPrefix + name, in: preferences)
                ?? boolValue(visibleCCPrefix + name, in: preferences)
                ?? boolValue(visiblePrefix + name, in: preferences)
                ?? true
            let position = intValue(preferredPositionPrefix + name, in: preferences)
            return Record(
                autosaveName: name,
                isVisible: isVisible,
                position: position ?? 0,
                hasKnownPosition: position != nil
            )
        }
        .sorted { lhs, rhs in
            lhs.position == rhs.position
                ? lhs.autosaveName < rhs.autosaveName
                : lhs.position < rhs.position
        }
    }

    /// Read back using the same container-aware domain resolver as the write.
    /// The helper is bounded, unlike opening a protected file while macOS
    /// waits for an App Data decision.
    static func isVisible(autosaveName: String, bundleID: String) -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", bundleID, visibilityPrefix + autosaveName]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
            guard finished.wait(timeout: .now() + 3) == .success else {
                if process.isRunning { process.terminate() }
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            let value = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            switch value {
            case "1", "true", "YES": return true
            case "0", "false", "NO": return false
            default: return nil
            }
        } catch { return nil }
    }

    /// The autosave name encoded in a `NSStatusItem …` key, if any.
    static func autosaveName(in key: String) -> String? {
        for prefix in [visibleCCPrefix, visiblePrefix, preferredPositionPrefix] {
            if key.hasPrefix(prefix) {
                let name = String(key.dropFirst(prefix.count))
                return name.isEmpty ? nil : name
            }
        }
        return nil
    }

    // MARK: - Writing

    /// Sets whether a status item shows in the menu bar.
    ///
    /// The current system's key is authoritative. The legacy key is updated
    /// best-effort for apps that still read it, but its failure must not
    /// make a successful write to the current key look like a failure.
    @discardableResult
    static func setVisible(_ visible: Bool, autosaveName: String, bundleID: String) -> Bool {
        guard !autosaveName.isEmpty, !bundleID.isEmpty,
              !bundleID.hasPrefix("com.apple."), !bundleID.contains("/") else { return false }
        let value = visible ? "true" : "false"
        guard runDefaults(key: visibilityPrefix + autosaveName, value: value, bundleID: bundleID) else {
            return false
        }
        if visibilityPrefix != visiblePrefix {
            _ = runDefaults(key: visiblePrefix + autosaveName, value: value, bundleID: bundleID)
        }
        return true
    }

    /// Writes through the `defaults` tool, which knows about app containers.
    private static func runDefaults(key: String, value: String, bundleID: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", bundleID, key, "-bool", value]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            try process.run()
            guard finished.wait(timeout: .now() + 3) == .success else {
                if process.isRunning { process.terminate() }
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func boolValue(_ key: String, in preferences: [String: Any]) -> Bool? {
        guard let value = preferences[key] else { return nil }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    private static func intValue(_ key: String, in preferences: [String: Any]) -> Int? {
        guard let value = preferences[key] else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}

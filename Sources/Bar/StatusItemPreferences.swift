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
//  Two wrinkles this type deals with:
//
//  * Sandboxed apps keep their preferences inside their container, so the
//    plist has to be read from `~/Library/Containers/…` and written through
//    `defaults`, which resolves the container for us.
//  * `CFPreferences` cannot see a sandboxed app's domain at all, so the
//    plist on disk is the source of truth.
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
    static func records(for bundleID: String) -> [Record] {
        records(in: preferences(for: bundleID))
    }

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
                position: position ?? 0
            )
        }
        .sorted { lhs, rhs in
            lhs.position == rhs.position
                ? lhs.autosaveName < rhs.autosaveName
                : lhs.position < rhs.position
        }
    }

    /// Finds preference domains outside the app's running-process list.
    /// This includes apps that have quit but whose status-item settings are
    /// still saved in the user's shared Preferences directory. Sandboxed
    /// containers are intentionally read only for known/running owners so a
    /// refresh does not walk into every other app's private container.
    static func bundleIDsWithStatusItemsInSharedPreferences() -> Set<String> {
        let directory = URL(fileURLWithPath: NSHomeDirectory())
            .appending(path: "Library/Preferences")
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Set(urls.compactMap { url in
            guard url.pathExtension == "plist",
                  let data = try? Data(contentsOf: url),
                  let dictionary = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any],
                  dictionary.keys.contains(where: { autosaveName(in: $0) != nil })
            else { return nil }

            return url.deletingPathExtension().lastPathComponent
        })
    }

    /// Returns the visibility flag currently stored for an item.
    static func isVisible(autosaveName: String, bundleID: String) -> Bool? {
        let preferences = preferences(for: bundleID)
        return boolValue(visibilityPrefix + autosaveName, in: preferences)
            ?? boolValue(visibleCCPrefix + autosaveName, in: preferences)
            ?? boolValue(visiblePrefix + autosaveName, in: preferences)
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
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Plumbing

    /// The app's preferences, read from wherever it keeps them.
    ///
    /// Both places are read and merged, because either one can hold the
    /// status item keys on its own:
    ///
    ///  * A sandboxed app keeps its preferences inside its container, so
    ///    the keys land in `~/Library/Containers/…`.
    ///  * Such an app often has a home plist as well, holding unrelated
    ///    settings and no status item keys at all. Stopping at the first
    ///    file that exists would miss the keys that live in the container.
    ///
    /// The container wins, because it is the app's real domain.
    static func preferences(for bundleID: String) -> [String: Any] {
        var merged: [String: Any] = [:]
        for url in preferenceURLs(for: bundleID) {
            guard let data = try? Data(contentsOf: url),
                  let dictionary = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
            else { continue }
            for (key, value) in dictionary { merged[key] = value }
        }
        return merged
    }

    private static func preferenceURLs(for bundleID: String) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            home.appending(path: "Library/Preferences/\(bundleID).plist"),
            home.appending(path: "Library/Containers/\(bundleID)/Data/Library/Preferences/\(bundleID).plist"),
        ]
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

import Foundation
import Darwin

struct AppScanTarget: Sendable {
    let bundleID: String
    let processIdentifier: pid_t?
    let localizedName: String?
    var readsAccessibility = true
}

enum StatusPreferenceValue: Sendable {
    case flag(Bool)
    case position(Int)
    case invalid

    var propertyListValue: Any {
        switch self {
        case .flag(let value): value
        case .position(let value): value
        case .invalid: NSNull()
        }
    }
}

struct PreferenceScan: Sendable {
    var dictionaries: [String: [String: StatusPreferenceValue]]
    var containers: [String: [String: StatusPreferenceValue]] = [:]
    var filesRead: Int
    var cacheHits: Int
    var unreadableContainers: Int = 0
    var records: [String: [StatusItemPreferences.Record]] {
        dictionaries.mapValues { StatusItemPreferences.records(in: $0.mapValues(\.propertyListValue)) }
    }
}

/// Retains only status-item keys, never whole preference files. All file I/O
/// stays on the scanner actor, and a warm scan only checks file metadata.
struct StatusPreferenceCache {
    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int?
    }
    private struct FileSnapshot {
        let stamp: Stamp
        let keys: [String: StatusPreferenceValue]
    }

    let preferencesDirectory: URL
    let containersDirectory: URL
    private var files: [URL: FileSnapshot] = [:]
    private(set) var filesRead = 0
    private(set) var cacheHits = 0
    private var unreadableContainers = 0
    private static let markers = [
        Data("NSStatusItem ".utf8),
        "NSStatusItem ".data(using: .utf16BigEndian)!,
        "NSStatusItem ".data(using: .utf16LittleEndian)!,
    ]

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        preferencesDirectory = home.appending(path: "Library/Preferences")
        containersDirectory = home.appending(path: "Library/Containers")
    }

    mutating func scan(bundleIDs: Set<String>, excluding excluded: String?, includeContainers: Bool = false) -> PreferenceScan {
        filesRead = 0
        cacheHits = 0
        unreadableContainers = 0
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: preferencesDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var dictionaries: [String: [String: StatusPreferenceValue]] = [:]
        var containers: [String: [String: StatusPreferenceValue]] = [:]
        var visited = Set<URL>()
        for url in urls where url.pathExtension == "plist" {
            let id = url.deletingPathExtension().lastPathComponent
            guard id != excluded, !id.hasPrefix("com.apple.") else { continue }
            visited.insert(url)
            let keys = read(url)
            if !keys.isEmpty { dictionaries[id] = keys }
        }
        // Container access is limited to known owners, never every container.
        for id in bundleIDs where id != excluded && !id.hasPrefix("com.apple.") {
            let shared = preferencesDirectory.appending(path: "\(id).plist")
            visited.insert(shared)
            var keys = dictionaries[id] ?? read(shared)
            if includeContainers {
                let container = containersDirectory.appending(path: "\(id)/Data/Library/Preferences/\(id).plist")
                visited.insert(container)
                let containerKeys = read(container, protected: true)
                if !containerKeys.isEmpty { containers[id] = containerKeys }
                keys.merge(containerKeys) { _, containerValue in containerValue }
            }
            if !keys.isEmpty { dictionaries[id] = keys }
        }
        files = files.filter { visited.contains($0.key) }
        return PreferenceScan(dictionaries: dictionaries, containers: containers,
                              filesRead: filesRead, cacheHits: cacheHits, unreadableContainers: unreadableContainers)
    }

    mutating func invalidate(bundleID: String? = nil) {
        guard let bundleID else { files.removeAll(keepingCapacity: true); return }
        files.removeValue(forKey: preferencesDirectory.appending(path: "\(bundleID).plist"))
        files.removeValue(forKey: containersDirectory.appending(path: "\(bundleID)/Data/Library/Preferences/\(bundleID).plist"))
    }

    private mutating func read(_ url: URL, protected: Bool = false) -> [String: StatusPreferenceValue] {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            files.removeValue(forKey: url)
            return [:]
        }
        let stamp = Stamp(modified: values.contentModificationDate, size: values.fileSize)
        if let saved = files[url], saved.stamp == stamp {
            cacheHits += 1
            return saved.keys
        }
        filesRead += 1
        guard let data = protected ? Self.readProtectedFile(url) : try? Data(contentsOf: url, options: .mappedIfSafe) else {
            if protected { unreadableContainers += 1 }
            return [:]
        }
        let keys: [String: StatusPreferenceValue] = autoreleasepool {
            guard
                  Self.markers.contains(where: { data.range(of: $0) != nil }),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let dictionary = plist as? [String: Any] else { return [:] }
            return dictionary.reduce(into: [:]) { result, pair in
                guard StatusItemPreferences.autosaveName(in: pair.key) != nil else { return }
                // Keep a malformed key's presence, without retaining arbitrary
                // data values in another application's preferences.
                if pair.key.hasPrefix(StatusItemPreferences.preferredPositionPrefix) {
                    if let number = pair.value as? NSNumber { result[pair.key] = .position(number.intValue) }
                    else if let text = pair.value as? String, let number = Int(text) { result[pair.key] = .position(number) }
                    else { result[pair.key] = .invalid }
                } else if let number = pair.value as? NSNumber { result[pair.key] = .flag(number.boolValue) }
                else { result[pair.key] = .invalid }
            }
        }
        files[url] = FileSnapshot(stamp: stamp, keys: keys)
        return keys
    }

    /// The OS can wait indefinitely for an App Data decision while opening a
    /// container. Isolate that open in our own short-lived reader so a denied
    /// or unanswered prompt never pins a scanner thread or the rest of the list.
    static func readProtectedFile(_ url: URL, executable: URL = URL(fileURLWithPath: "/bin/cat"), timeout: TimeInterval = 3) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = [url.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        let collected = ProtectedReadResult()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            var valid = true
            do {
                while let chunk = try output.fileHandleForReading.read(upToCount: 65_536), !chunk.isEmpty {
                    guard data.count + chunk.count <= 8 * 1_024 * 1_024 else { valid = false; break }
                    data.append(chunk)
                }
            } catch { valid = false }
            try? output.fileHandleForReading.close()
            collected.set(valid ? data : nil)
            drained.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            // Only terminate the helper we just created, never an owner app.
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard process.terminationStatus == 0,
              drained.wait(timeout: .now() + 0.2) == .success else { return nil }
        return collected.get()
    }
}

private final class ProtectedReadResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    func set(_ data: Data?) { lock.lock(); defer { lock.unlock() }; value = data }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return value }
}

actor StatusItemScanner {
    private var cache = StatusPreferenceCache()

    func preferences(for targets: [AppScanTarget], excluding bundleID: String?, includeContainers: Bool = false) -> PreferenceScan {
        cache.scan(bundleIDs: Set(targets.map(\.bundleID)), excluding: bundleID, includeContainers: includeContainers)
    }

    func invalidate(bundleID: String? = nil) { cache.invalidate(bundleID: bundleID) }

    /// Accessibility IPC may block; never fan out without a bound or run it
    /// on the main actor. Four independent owners can answer at a time.
    nonisolated static func accessibility(
        for targets: [AppScanTarget],
        probe: @escaping @Sendable (pid_t) -> AXStatus = { AccessibilityScanner.status(forProcessIdentifier: $0) }
    ) async -> [String: AXStatus] {
        let candidates = targets.filter { $0.processIdentifier != nil && $0.readsAccessibility }
        return await withTaskGroup(of: (String, AXStatus).self) { group in
            var next = candidates.makeIterator()
            func enqueue(_ target: AppScanTarget) {
                group.addTask {
                    let status = await Task.detached(priority: .utility) {
                        probe(target.processIdentifier!)
                    }.value
                    return (target.bundleID, status)
                }
            }
            for _ in 0 ..< min(4, candidates.count) {
                if let target = next.next() { enqueue(target) }
            }
            var results: [String: AXStatus] = [:]
            for await (id, status) in group {
                if Task.isCancelled { group.cancelAll(); break }
                results[id] = status
                if let target = next.next() { enqueue(target) }
            }
            return results
        }
    }
}

import CoreGraphics
import Darwin
import Foundation

/// A live WindowServer item. A preference key is deliberately not an input:
/// a saved Item-N does not establish the existence or identity of a window.
struct MenuBarWindow: Hashable, Sendable {
    let id: CGWindowID
    let hostPID: pid_t
    let title: String
    let frame: CGRect
    let isOnScreen: Bool
}

struct MenuBarProcess: Sendable {
    let pid: pid_t
    let bundleID: String
    let name: String

    var isSystemHost: Bool {
        ["com.apple.controlcenter", "com.apple.systemuiserver"].contains(bundleID.lowercased())
    }
}

struct ResolvedMenuBarWindow: Sendable {
    let window: MenuBarWindow
    let source: MenuBarProcess?
    let accessibleName: String
}

enum MenuBarWindowError: Error {
    case unavailable
    case enumerationFailed
    case incompleteSnapshot
    case layoutChanging
}

struct MenuBarInventory: Sendable {
    let windows: [MenuBarWindow]
    let accessibility: [String: AXStatus]
}

enum MenuBarInventoryReader {
    /// AX and CGS are separate IPC calls. Only publish AX labels bracketed
    /// by identical window snapshots. One retry handles startup reflow without
    /// an unbounded scan loop for animated menu bar utilities.
    static func read(
        targets: [AppScanTarget],
        windows: @Sendable () async -> Result<[MenuBarWindow], MenuBarWindowError> = { await MenuBarWindowScanner.snapshot() },
        accessibility: @Sendable ([AppScanTarget]) async -> [String: AXStatus] = { await StatusItemScanner.accessibility(for: $0) }
    ) async -> Result<MenuBarInventory, MenuBarWindowError> {
        var before = await windows()
        for _ in 0..<2 {
            guard case let .success(initial) = before else {
                if case let .failure(error) = before { return .failure(error) }
                return .failure(.enumerationFailed)
            }
            if Task.isCancelled { return .failure(.enumerationFailed) }
            let labels = await accessibility(targets)
            let after = await windows()
            guard case let .success(final) = after else {
                if case let .failure(error) = after { return .failure(error) }
                return .failure(.enumerationFailed)
            }
            if initial == final { return .success(MenuBarInventory(windows: final, accessibility: labels)) }
            before = after
        }
        return .failure(.layoutChanging)
    }
}

/// The private API is isolated here and resolved at runtime. Missing symbols
/// produce an explicit failure, never a successful empty menu bar.
enum MenuBarWindowScanner {
    static func snapshot() async -> Result<[MenuBarWindow], MenuBarWindowError> {
        await Task.detached(priority: .utility) {
            do { return .success(try scan()) }
            catch MenuBarWindowError.incompleteSnapshot {
                do { return .success(try scan()) }
                catch { return .failure(.incompleteSnapshot) }
            }
            catch let error as MenuBarWindowError { return .failure(error) }
            catch { return .failure(.enumerationFailed) }
        }.value
    }

    static func scan() throws -> [MenuBarWindow] {
        guard let bridge = WindowServerBridge.shared else { throw MenuBarWindowError.unavailable }
        let ids = try bridge.itemIDs()
        guard !ids.isEmpty else { return [] }
        let onScreenIDs = try bridge.onScreenIDs()
        // CGWindowList's window-ID arrays contain raw ID bit patterns, not
        // CFNumbers. Request descriptions only for menu bar windows.
        var handles = ids.map { UnsafeRawPointer(bitPattern: UInt($0)) }
        guard let array = CFArrayCreate(nil, &handles, handles.count, nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(array) as? [[String: Any]] else {
            throw MenuBarWindowError.enumerationFailed
        }
        let wanted = Set(ids)
        var found = Set<CGWindowID>()
        var result: [MenuBarWindow] = []
        let displays = displayBounds()
        for info in descriptions {
            guard let number = info[kCGWindowNumber as String] as? NSNumber,
                  wanted.contains(number.uint32Value),
                  let owner = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            let id = number.uint32Value
            found.insert(id)
            // Main menus share the enumeration API but are not status items.
            guard let layer = info[kCGWindowLayer as String] as? NSNumber,
                  layer.intValue != Int(CGWindowLevelForKey(.mainMenuWindow)),
                  let frame = bridge.frame(of: id),
                  frame.width > 0, frame.height > 0,
                  frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite else { continue }
            // Keep the entire horizontal row, including items parked offscreen.
            guard displays.contains(where: {
                frame.minY >= $0.minY - 1 && frame.minY <= $0.minY + frame.height
            }) else { continue }
            result.append(MenuBarWindow(id: id, hostPID: owner.int32Value,
                title: info[kCGWindowName as String] as? String ?? "", frame: frame,
                isOnScreen: onScreenIDs.contains(id) && displays.contains(where: { $0.intersects(frame) })))
        }
        // A window may vanish between the two calls. Retry once at the caller;
        // do not replace a good list with a knowingly partial snapshot.
        guard found.count == wanted.count else { throw MenuBarWindowError.incompleteSnapshot }
        return result.sorted { $0.id < $1.id }
    }

    static func frame(of windowID: CGWindowID) -> CGRect? {
        WindowServerBridge.shared?.frame(of: windowID)
    }

    /// Match the actual AX rectangle, not an ordinal or a saved position.
    /// Control Center can expose the same hosted item as its real creator;
    /// a unique non-host owner wins, otherwise ownership remains unknown.
    static func resolve(_ windows: [MenuBarWindow], processes: [MenuBarProcess],
                        accessibility: [String: AXStatus]) -> [ResolvedMenuBarWindow] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        return windows.map { window in
            let observations: [(MenuBarProcess, AXStatusItem)] = processes.flatMap { process in
                (accessibility[process.bundleID]?.items ?? []).map { (process, $0) }
            }
            // A hosted window can include asymmetric padding. Use exact
            // centers first; a unique fully contained AX button is a fallback.
            // Proximity alone is never enough to borrow a neighbor's owner.
            let candidates = observations.filter {
                hypot($0.1.frame.midX - window.frame.midX, $0.1.frame.midY - window.frame.midY) <= 1
            }
            let centeredCreators = candidates.filter { !$0.0.isSystemHost }
            let containedCreators = observations.filter {
                !$0.0.isSystemHost && window.frame.contains($0.1.frame)
            }
            let creators = centeredCreators.isEmpty && containedCreators.count == 1 ? containedCreators : centeredCreators
            let uniqueCreators = Set(creators.map { $0.0.pid })
            if uniqueCreators.count == 1, let match = creators.first {
                return ResolvedMenuBarWindow(window: window, source: match.0, accessibleName: match.1.name)
            }
            if uniqueCreators.count > 1 {
                return ResolvedMenuBarWindow(window: window, source: nil, accessibleName: "")
            }
            // On systems with native owner windows, that PID is authoritative.
            if let owner = byPID[window.hostPID], !owner.isSystemHost {
                return ResolvedMenuBarWindow(window: window, source: owner,
                    accessibleName: candidates.first(where: { $0.0.pid == owner.pid })?.1.name ?? "")
            }
            // A precise bundle prefix is a fallback for hosted items whose AX
            // owner did not answer. Never assign generic Item-N to the host.
            let namespaces = [window.title] + candidates.map { $0.1.identifier }
            let titleOwners = processes.filter { process in
                !process.isSystemHost && namespaces.contains { value in
                    !value.isEmpty && (value == process.bundleID || value.hasPrefix(process.bundleID + "."))
                }
            }
            let longest = titleOwners.map { $0.bundleID.count }.max()
            let exact = titleOwners.filter { $0.bundleID.count == longest }
            if exact.count == 1, let owner = exact.first {
                return ResolvedMenuBarWindow(window: window, source: owner, accessibleName: "")
            }
            // Apple controls with a descriptive AX name can still be listed,
            // but this is explicitly a host attribution, never a writable app.
            if candidates.count == 1, let host = candidates.first,
               !host.1.name.isEmpty, !isGenericSlot(host.1.name) {
                // A descriptive hosted button can belong to a third-party
                // app. Keep its label without claiming Apple created it.
                let system = host.1.identifier.hasPrefix("com.apple.") ? host.0 : nil
                return ResolvedMenuBarWindow(window: window, source: system, accessibleName: host.1.name)
            }
            return ResolvedMenuBarWindow(window: window, source: nil, accessibleName: "")
        }
    }

    /// Legacy preference writes are allowed only with a unique association.
    /// Multiple items are never paired by their position in two unrelated lists.
    static func matchingRecord(for item: ResolvedMenuBarWindow, siblings: [ResolvedMenuBarWindow],
                               records: [StatusItemPreferences.Record]) -> StatusItemPreferences.Record? {
        guard let source = item.source else { return nil }
        let exact = records.filter { record in
            item.window.title == record.autosaveName
                || item.window.title == source.bundleID + "." + record.autosaveName
                || (!item.accessibleName.isEmpty && item.accessibleName == record.autosaveName)
        }
        if exact.count == 1 { return exact[0] }
        if records.count == 1,
           siblings.filter({ $0.source?.pid == source.pid }).count == 1 { return records[0] }
        return nil
    }

    private static func isGenericSlot(_ name: String) -> Bool {
        name.range(of: #"^(?:Item|StatusItem)[-_.0-9]*$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func displayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }
}

private final class WindowServerBridge: @unchecked Sendable {
    private typealias Connection = @convention(c) () -> Int32
    private typealias Count = @convention(c) (Int32, Int32, UnsafeMutablePointer<Int32>) -> Int32
    private typealias List = @convention(c) (Int32, Int32, Int32, UnsafeMutablePointer<CGWindowID>, UnsafeMutablePointer<Int32>) -> Int32
    private typealias Bounds = @convention(c) (Int32, CGWindowID, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias ActiveSpace = @convention(c) (Int32) -> Int
    private typealias Spaces = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private let connection: Connection
    private let count: Count
    private let list: List
    private let onScreenCount: Count
    private let onScreenList: List
    private let bounds: Bounds
    private let activeSpace: ActiveSpace
    private let spaces: Spaces

    static let shared = WindowServerBridge()

    private init?() {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let a = dlsym(handle, "CGSMainConnectionID"),
              let b = dlsym(handle, "CGSGetWindowCount"),
              let c = dlsym(handle, "CGSGetProcessMenuBarWindowList"),
              let d = dlsym(handle, "CGSGetScreenRectForWindow"),
              let e = dlsym(handle, "CGSGetActiveSpace"),
              let f = dlsym(handle, "CGSCopySpacesForWindows"),
              let g = dlsym(handle, "CGSGetOnScreenWindowCount"),
              let h = dlsym(handle, "CGSGetOnScreenWindowList") else { return nil }
        connection = unsafeBitCast(a, to: Connection.self)
        count = unsafeBitCast(b, to: Count.self)
        list = unsafeBitCast(c, to: List.self)
        bounds = unsafeBitCast(d, to: Bounds.self)
        activeSpace = unsafeBitCast(e, to: ActiveSpace.self)
        spaces = unsafeBitCast(f, to: Spaces.self)
        onScreenCount = unsafeBitCast(g, to: Count.self)
        onScreenList = unsafeBitCast(h, to: List.self)
        dlclose(handle)
    }

    func itemIDs() throws -> [CGWindowID] {
        let ids = try windowIDs(count: count, list: list)
        let cid = connection()
        let current = activeSpace(cid)
        guard current > 0 else { throw MenuBarWindowError.enumerationFailed }
        // Inactive Spaces can retain a second set of hosted windows. They
        // must not turn one application's icon into two current list rows.
        return try Set(ids).filter { id in
            guard let memberships = spaces(cid, 7, [id] as CFArray)?.takeRetainedValue() as? [NSNumber] else {
                throw MenuBarWindowError.incompleteSnapshot
            }
            return memberships.contains { $0.intValue == current }
        }
    }

    func onScreenIDs() throws -> Set<CGWindowID> {
        Set(try windowIDs(count: onScreenCount, list: onScreenList))
    }

    private func windowIDs(count: Count, list: List) throws -> [CGWindowID] {
        var capacity: Int32 = 0
        let cid = connection()
        guard count(cid, 0, &capacity) == 0, capacity >= 0, capacity < 100_000 else {
            throw MenuBarWindowError.enumerationFailed
        }
        // Allow windows created between calls without an unbounded allocation.
        capacity = min(capacity + 64, 100_000)
        var ids = [CGWindowID](repeating: 0, count: Int(capacity))
        var actual: Int32 = 0
        guard list(cid, 0, capacity, &ids, &actual) == 0, actual >= 0, actual <= capacity else {
            throw MenuBarWindowError.enumerationFailed
        }
        return Array(ids.prefix(Int(actual)))
    }

    func frame(of id: CGWindowID) -> CGRect? {
        var rect = CGRect.zero
        return bounds(connection(), id, &rect) == 0 ? rect : nil
    }
}

//
//  StatusItemModel.swift
//  Bar
//
//  Owns the list of menu bar items and the hide/show operations.
//
//  The primary list is generated from live WindowServer items, with AX used
//  to identify their creators. Old hidden preference records live separately
//  so they remain recoverable without becoming fictitious current icons.
//
//  The legacy visibility writer is retained during the engine migration.
//  Two different things are tracked for a uniquely associated legacy item:
//
//  * whether the icon is in the menu bar right now, and
//  * whether macOS has been told to keep it out.
//
//  They agree in the steady state. They disagree while the owning app has
//  not rebuilt its status item yet, and the UI says so rather than
//  pretending the change already happened.
//
//  macOS applies a status-item preference when its owner creates the item.
//  Bar restarts menu-bar-only utilities, but leaves regular apps running to
//  protect unsaved work and explains which owner needs a restart.
//

import AppKit
import Observation
import OSLog

@MainActor
@Observable
final class StatusItemModel {
    /// One menu bar item the user can hide.
    struct Entry: Identifiable, Hashable {
        /// What the item is doing right now.
        enum State: Hashable {
            /// On screen, and macOS has been told to leave it alone.
            case shown
            /// On screen, but macOS has been told to hide it. The owner has
            /// not rebuilt its status item yet.
            case hiding
            /// Off screen.
            case hidden
            /// Off screen, but macOS has been told to show it. The owner has
            /// not rebuilt its status item yet.
            case showing
            /// The owner is not running; the saved preference says visible.
            case inactiveVisible
            /// The owner is not running; the saved preference says hidden.
            case inactiveHidden
        }

        let id: String
        /// The bundle identifier of the app that owns the item.
        let bundleID: String
        /// The owning app's display name.
        let appName: String
        /// The item's autosave name, the key macOS stores its state under.
        let autosaveName: String
        /// A friendly label for the item itself.
        var displayName: String
        /// The item's state.
        var state: State
        /// Apple's own items live in System Settings; this app leaves them be.
        var isSystemOwned: Bool
        /// The owning app's icon.
        var icon: NSImage?
        /// Whether the owning process is running.
        var isRunning: Bool
        /// The item's left-to-right position in the menu bar, when known.
        var order: Int?
        /// The name the Accessibility API gives the item, when it can be read.
        var axName: String
        /// `false` when macOS keeps no key for the item, so there is nothing
        /// to write and the item can only be listed.
        var isManageable: Bool
        /// Nil means the owner could not be observed, not that it has no icons.
        var observedVisible: Bool? = nil
        /// Runtime identity is separate from a legacy preference identity.
        var windowID: CGWindowID? = nil
        var preferenceID: String { bundleID + "/" + autosaveName }

        /// `true` when the icon is on screen right now.
        var isOnScreen: Bool {
            state == .shown || state == .hiding
        }

        /// Whether the saved macOS preference says the item should be shown.
        var isConfiguredVisible: Bool {
            state == .shown || state == .showing || state == .inactiveVisible
        }

        /// `true` when macOS still has to be told about a change.
        var isPending: Bool {
            state == .hiding || state == .showing
        }
    }

    private(set) var entries: [Entry] = []
    /// Old hidden preferences remain recoverable without masquerading as icons.
    private(set) var storedEntries: [Entry] = []
    private(set) var inventoryError: String?
    init(entries: [Entry] = [], storedEntries: [Entry] = [], defaults: UserDefaults = .standard) {
        self.entries = entries
        self.storedEntries = storedEntries
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pendingKey),
           let saved = try? JSONDecoder().decode([String: PendingChange].self, from: data) {
            pendingChanges = saved
        }
    }

    private(set) var isRefreshing = false
    @ObservationIgnored private let scanner = StatusItemScanner()
    @ObservationIgnored private let sandboxScanner = StatusItemScanner()
    @ObservationIgnored private var sandboxTask: Task<Void, Never>?
    @ObservationIgnored private var sandboxPreferences: [String: [String: StatusPreferenceValue]] = [:]
    @ObservationIgnored private var lastTargets: [AppScanTarget] = []
    @ObservationIgnored private var sandboxEnabled = false
    private(set) var isReadingSandboxPreferences = false
    private(set) var hasReadSandboxPreferences = false
    private(set) var sandboxReadNote: String?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastWindowInventory: [MenuBarWindow]?
    private struct PendingChange: Codable {
        let visible: Bool
        let pid: pid_t
        let launchedAt: Date?
    }
    private static let pendingKey = "pendingVisibilityChanges"
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var pendingChanges: [String: PendingChange] = [:] {
        didSet {
            if let data = try? JSONEncoder().encode(pendingChanges) { defaults.set(data, forKey: Self.pendingKey) }
        }
    }
    @ObservationIgnored private var appURLs: [String: URL] = [:]
    @ObservationIgnored private var missingApps: Set<String> = []
    @ObservationIgnored private var appNames: [String: String] = [:]
    @ObservationIgnored private static let logger = Logger(subsystem: "com.ryanbzhou.bar", category: "scan")
    private(set) var lastScanSeconds: TimeInterval = 0
    private(set) var lastPreferenceReads = 0
    private(set) var lastCacheHits = 0
    /// Entries whose change is still being applied by the system.
    private(set) var pendingIDs: Set<String> = []
    /// A short note about what just happened, shown under the list.
    private(set) var statusMessage: String?

    var searchText = ""

    /// Required for reliable creator resolution before entering the live list.
    private(set) var hasAccessibilityAccess = false

    // MARK: - Presentation

    var shownEntries: [Entry] {
        entries.filter { !$0.isSystemOwned && $0.isRunning && $0.isOnScreen }
    }

    var hiddenEntries: [Entry] {
        entries.filter { !$0.isSystemOwned && $0.isRunning && !$0.isOnScreen }
    }

    var inactiveEntries: [Entry] {
        storedEntries
    }

    var unmanagedEntries: [Entry] {
        entries.filter { $0.isSystemOwned && $0.isRunning }
    }

    var filteredShownEntries: [Entry] { filter(shownEntries) }
    var filteredHiddenEntries: [Entry] { filter(hiddenEntries) }
    var filteredInactiveEntries: [Entry] { filter(inactiveEntries) }
    var filteredUnmanagedEntries: [Entry] { filter(unmanagedEntries) }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var hasSearchResults: Bool {
        !(filteredShownEntries.isEmpty && filteredHiddenEntries.isEmpty
          && filteredInactiveEntries.isEmpty && filteredUnmanagedEntries.isEmpty)
    }
    var hasHiddenItems: Bool {
        (entries + storedEntries).contains { $0.isManageable && !$0.isConfiguredVisible }
    }
    var isBusy: Bool { !pendingIDs.isEmpty }
    var manageableCount: Int { entries.filter(\.isManageable).count }
    private(set) var statusIsError = false

    func dismissStatus() { statusMessage = nil; statusIsError = false }

    func reportMenuBarRecovery() {
        statusMessage = "已恢复 Bar 图标，请查看菜单栏右侧。"
        statusIsError = false
    }

    private func filter(_ source: [Entry]) -> [Entry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return source }
        return source.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.appName.localizedCaseInsensitiveContains(query)
        }
    }

    // MARK: - Loading

    /// Focus changes share a fresh snapshot. An explicit refresh bypasses
    /// this short cooldown, while concurrent refreshes never duplicate I/O.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else {
            refreshAgain = refreshAgain || force
            return
        }
        let authorized = AccessibilityScanner.isAuthorized
        let permissionChanged = authorized != hasAccessibilityAccess
        guard force || permissionChanged || lastRefresh.map({ Date().timeIntervalSince($0) >= 5 }) != false else { return }
        isRefreshing = true
        hasAccessibilityAccess = authorized
        let started = Date()
        defer {
            isRefreshing = false
            let repeatRequested = refreshAgain
            refreshAgain = false
            if repeatRequested && !Task.isCancelled { Task { await refresh(force: true) } }
        }

        let ownBundleID = Bundle.main.bundleIdentifier ?? "com.ryanbzhou.bar"
        var runningByBundleID: [String: NSRunningApplication] = [:]
        var targets: [String: AppScanTarget] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, id != ownBundleID,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
            // Prefer the actual user-facing owner over a same-ID helper.
            if let existing = runningByBundleID[id], existing.activationPolicy != .prohibited { continue }
            runningByBundleID[id] = app
            let systemHost = ["com.apple.controlcenter", "com.apple.systemuiserver", "com.apple.spotlight", "com.apple.textinputmenuagent"].contains(id.lowercased())
            targets[id] = AppScanTarget(bundleID: id, processIdentifier: app.processIdentifier,
                                       localizedName: app.localizedName,
                                       readsAccessibility: app.activationPolicy != .prohibited || systemHost)
        }
        let remembered = Self.rememberedHiddenItems.filter { !$0.isSystemOwned && !$0.bundleID.hasPrefix("com.apple.") && $0.bundleID != ownBundleID }
        for item in remembered where targets[item.bundleID] == nil {
            targets[item.bundleID] = AppScanTarget(bundleID: item.bundleID, processIdentifier: nil, localizedName: item.appName)
        }
        let currentTargets = Array(targets.values)
        lastTargets = currentTargets
        var preferences = await scanner.preferences(for: currentTargets, excluding: ownBundleID)
        for (id, values) in sandboxPreferences {
            preferences.dictionaries[id, default: [:]].merge(values) { _, containerValue in containerValue }
        }
        let preferenceRecords = preferences.records
        guard !Task.isCancelled else { return }
        let ownTarget = AppScanTarget(bundleID: ownBundleID, processIdentifier: ProcessInfo.processInfo.processIdentifier,
                                      localizedName: "Bar")
        let live = authorized ? await MenuBarInventoryReader.read(targets: currentTargets + [ownTarget]) : nil
        let accessibility: [String: AXStatus]
        if case let .success(inventory) = live { accessibility = inventory.accessibility }
        else { accessibility = [:] }
        guard !Task.isCancelled else { return }
        for id in preferenceRecords.keys where targets[id] == nil {
            targets[id] = AppScanTarget(bundleID: id, processIdentifier: nil, localizedName: nil)
        }

        var collected: [Entry] = []
        let rememberedIDs = Set(remembered.map(\.id))
        for target in targets.values {
            let records = preferenceRecords[target.bundleID] ?? []
            let status = accessibility[target.bundleID] ?? AXStatus(items: [], isReadable: false)
            // Do not load names/icons for background processes with no items.
            guard !records.isEmpty || !status.items.isEmpty else { continue }
            let app = runningByBundleID[target.bundleID]
            if app == nil, applicationURL(bundleID: target.bundleID) == nil,
               !records.contains(where: { rememberedIDs.contains(target.bundleID + "/" + $0.autosaveName) }) {
                continue // Old preferences for uninstalled apps are not a UI list.
            }
            let name = app?.localizedName ?? target.localizedName ?? installedAppName(bundleID: target.bundleID)
            let image = app.map { icon(for: $0) } ?? icon(bundleID: target.bundleID)
            collected.append(contentsOf: entries(bundleID: target.bundleID, appName: name, icon: image,
                isSystemOwned: target.bundleID.hasPrefix("com.apple."), isRunning: app != nil,
                records: records, axItems: status.items, isReadable: status.isReadable))
        }
        for item in remembered where !collected.contains(where: { $0.id == item.id }) {
            var entry = item
            if let app = runningByBundleID[item.bundleID] {
                entry.isRunning = true
                entry.icon = icon(for: app)
                entry.state = .hidden
            }
            collected.append(entry)
        }
        // With no AX permission a saved preference cannot prove that a running
        // owner rebuilt its item. Keep explicit changes pending until restart.
        for index in collected.indices {
            let entry = collected[index]
            guard let change = pendingChanges[entry.id] else { continue }
            let owner = runningByBundleID[entry.bundleID]
            if owner?.processIdentifier != change.pid || owner?.launchDate != change.launchedAt {
                pendingChanges.removeValue(forKey: entry.id)
            } else if entry.observedVisible == change.visible {
                pendingChanges.removeValue(forKey: entry.id)
            } else {
                collected[index].state = change.visible ? .showing : .hiding
            }
        }
        let collectedIDs = Set(collected.map(\.id))
        pendingChanges = pendingChanges.filter { collectedIDs.contains($0.key) }
        guard authorized else {
            entries = []
            storedEntries = collected.filter { $0.isManageable && (!$0.isConfiguredVisible || $0.isPending) }
            inventoryError = nil
            lastRefresh = Date()
            return
        }
        guard case let .success(inventory) = live else {
            inventoryError = "暂时无法读取当前菜单栏。请刷新重试。"
            lastRefresh = nil
            return
        }
        inventoryError = nil
        lastWindowInventory = inventory.windows
        let processes = runningByBundleID.values.compactMap { app -> MenuBarProcess? in
            guard let id = app.bundleIdentifier else { return nil }
            return MenuBarProcess(pid: app.processIdentifier, bundleID: id, name: app.localizedName ?? id)
        } + [MenuBarProcess(pid: ProcessInfo.processInfo.processIdentifier, bundleID: ownBundleID, name: "Bar")]
        let resolved = MenuBarWindowScanner.resolve(inventory.windows, processes: processes, accessibility: accessibility)
            .filter { $0.source?.bundleID != ownBundleID }
        let projected = makeLiveEntries(resolved, records: preferenceRecords, legacy: collected)
        storedEntries = projected.stored
        let rebuilt = disambiguate(projected.current.sorted { lhs, rhs in
            let byName = lhs.appName.localizedStandardCompare(rhs.appName)
            if byName != .orderedSame { return byName == .orderedAscending }
            return lhs.id < rhs.id
        })
        if entries != rebuilt { entries = rebuilt }
        lastRefresh = Date()
        lastScanSeconds = Date().timeIntervalSince(started)
        lastPreferenceReads = preferences.filesRead
        lastCacheHits = preferences.cacheHits
        Self.logger.debug("scan seconds=\(self.lastScanSeconds, privacy: .public) reads=\(preferences.filesRead, privacy: .public) cacheHits=\(preferences.cacheHits, privacy: .public) AX=\(authorized, privacy: .public)")
    }

    func makeLiveEntries(_ resolved: [ResolvedMenuBarWindow], records: [String: [StatusItemPreferences.Record]],
                         legacy: [Entry]) -> (current: [Entry], stored: [Entry]) {
        var represented = Set<String>()
        let current = resolved.map { item -> Entry in
            let source = item.source
            let id = source?.bundleID ?? "unknown"
            let name = source?.name ?? "未识别图标"
            let record = MenuBarWindowScanner.matchingRecord(for: item, siblings: resolved, records: records[id] ?? [])
            let legacyID = record.map { id + "/" + $0.autosaveName }
            let previous = legacy.first { $0.id == legacyID }
            let onScreen = item.window.isOnScreen
            // Offscreen rows are readonly until the move engine is ready.
            // They must not consume the separate legacy restore action.
            if let legacyID, onScreen { represented.insert(legacyID) }
            let state: Entry.State = onScreen
                ? (record?.isVisible == false ? .hiding : .shown)
                : (previous?.state == .showing ? .showing : .hidden)
            return Entry(id: "window-\(item.window.hostPID)-\(item.window.id)", bundleID: id, appName: name,
                autosaveName: record?.autosaveName ?? "",
                displayName: displayName(axName: item.accessibleName, appName: name), state: state,
                isSystemOwned: id.hasPrefix("com.apple."), icon: source.flatMap { icon(bundleID: $0.bundleID) },
                isRunning: true, order: Int(item.window.frame.minX), axName: item.accessibleName,
                isManageable: record != nil && source != nil && !id.hasPrefix("com.apple.") && onScreen,
                observedVisible: onScreen, windowID: item.window.id)
        }
        let stored = legacy.filter {
            $0.isManageable && !represented.contains($0.id) && (!$0.isConfiguredVisible || $0.isPending)
        }.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
        return (current, stored)
    }

    func rescan() async {
        await scanner.invalidate()
        missingApps.removeAll()
        appURLs.removeAll(keepingCapacity: true)
        appNames.removeAll(keepingCapacity: true)
        iconCache.removeAll(keepingCapacity: true)
        await refresh(force: true)
        if sandboxEnabled { readSandboxPreferences() }
    }

    /// Some hosted items appear/disappear without a workspace notification
    /// (including a process terminated outside AppKit). The delegate calls
    /// this only while our window is foreground; unchanged windows need no AX
    /// or preference reread.
    func refreshIfMenuBarChanged() async {
        guard hasAccessibilityAccess, !isRefreshing, !isBusy else { return }
        let snapshot = await MenuBarWindowScanner.snapshot()
        if case let .success(windows) = snapshot, windows == lastWindowInventory { return }
        await refresh(force: true)
    }

    func readSandboxPreferences() {
        guard !isReadingSandboxPreferences, !lastTargets.isEmpty else { return }
        sandboxEnabled = true
        isReadingSandboxPreferences = true
        let targets = lastTargets
        let ownID = Bundle.main.bundleIdentifier ?? "com.ryanbzhou.bar"
        sandboxTask = Task { [weak self, sandboxScanner] in
            let snapshot = await sandboxScanner.preferences(for: targets, excluding: ownID, includeContainers: true)
            guard let self else { return }
            self.sandboxPreferences = snapshot.containers
            self.isReadingSandboxPreferences = false
            self.hasReadSandboxPreferences = true
            self.sandboxReadNote = snapshot.unreadableContainers > 0
                ? "有 \(snapshot.unreadableContainers) 个应用暂时无法读取，可稍后重试。"
                : "读取完成。没有可写图标设置的应用不会加入列表。"
            await self.refresh(force: true)
        }
    }

    func applicationChanged(bundleID: String?) {
        if let bundleID {
            missingApps.remove(bundleID)
            appURLs.removeValue(forKey: bundleID)
            appNames.removeValue(forKey: bundleID)
            iconCache.removeValue(forKey: bundleID)
        }
        // The delegate batches workspace notifications, and only refreshes
        // when the window is visible.
        lastRefresh = nil
    }

    /// Builds the entries of one app.
    ///
    /// The app's preference records and the icons on screen describe the
    /// same row of icons in the same order: the records carry the position
    /// macOS remembers, and the bigger that position the further left the
    /// icon sits, while the Accessibility API reports the row left to
    /// right. Walking the records in that order and consuming the icons as
    /// we go lines the two up, and what is left over are the icons macOS
    /// keeps no settings for.
    func entries(
        bundleID: String,
        appName: String,
        icon: NSImage?,
        isSystemOwned: Bool,
        isRunning: Bool,
        records: [StatusItemPreferences.Record],
        axItems: [AXStatusItem],
        isReadable: Bool
    ) -> [Entry] {
        // Apple's own items share one crowded domain, where the records
        // outnumber the icons on screen and cannot be lined up with them.
        // They are listed under the name the Accessibility API gives them
        // and left to System Settings.
        if isSystemOwned {
            guard isRunning else { return [] }
            return axItems.enumerated().map { index, axItem in
                Entry(
                    id: "\(bundleID)/system/\(index)",
                    bundleID: bundleID,
                    appName: appName,
                    autosaveName: "",
                    displayName: displayName(axName: axItem.name, appName: appName),
                    state: .shown,
                    isSystemOwned: true,
                    icon: icon,
                    isRunning: true,
                    order: Int(axItem.frame.minX),
                    axName: axItem.name,
                    isManageable: false,
                    observedVisible: true
                )
            }
        }

        // Left to right: the biggest position sits furthest left.
        let ordered = records.sorted { lhs, rhs in
            lhs.position == rhs.position
                ? lhs.autosaveName < rhs.autosaveName
                : lhs.position > rhs.position
        }

        let positions = Set(ordered.map(\.position))
        // A partial live row does not tell which historical records remain.
        // Matching its first icon to the first saved position can name the
        // wrong writable setting, even when every saved position is unique.
        let canAssociate = ordered.count == 1 && axItems.count <= 1
            || (!ordered.isEmpty && ordered.allSatisfy(\.hasKnownPosition) && positions.count == ordered.count && axItems.count == ordered.count)
        var onScreen = axItems
        var visibleLeft = ordered.filter(\.isVisible).count
        var result: [Entry] = []

        for record in ordered {
            if record.isVisible {
                visibleLeft -= 1
                if !onScreen.isEmpty {
                    result.append(entry(
                        for: record, axItem: onScreen.removeFirst(), state: .shown,
                        bundleID: bundleID, appName: appName, icon: icon, isRunning: isRunning
                    ))
                } else if !isRunning {
                    result.append(entry(
                        for: record, axItem: nil, state: .inactiveVisible,
                        bundleID: bundleID, appName: appName, icon: icon, isRunning: false
                    ))
                } else {
                    // The app could not be read, so all that is known is
                    // what macOS was told.
                    result.append(entry(
                        for: record, axItem: nil, state: .shown,
                        bundleID: bundleID, appName: appName, icon: icon, isRunning: true
                    ))
                }
            } else {
                // macOS was told to hide it. When more icons sit in the bar
                // than the visible records account for, this one is still
                // there and its owner has yet to rebuild it.
                let stillThere = isRunning && isReadable && canAssociate && !onScreen.isEmpty && onScreen.count > visibleLeft
                result.append(entry(
                    for: record,
                    axItem: stillThere ? onScreen.removeFirst() : nil,
                    state: stillThere ? .hiding : (isRunning ? .hidden : .inactiveHidden),
                    bundleID: bundleID, appName: appName, icon: icon, isRunning: isRunning
                ))
            }
        }

        // Icons macOS keeps no settings for — the owner never gave its
        // status item an autosave name — can be listed but not hidden.
        for (index, axItem) in onScreen.enumerated() {
            result.append(Entry(
                id: "\(bundleID)/unnamed/\(index)",
                bundleID: bundleID,
                appName: appName,
                autosaveName: "",
                displayName: displayName(axName: axItem.name, appName: appName),
                state: .shown,
                isSystemOwned: false,
                icon: icon,
                isRunning: true,
                order: Int(axItem.frame.minX),
                axName: axItem.name,
                isManageable: false
            ))
        }

        return result.map { entry in
            var result = entry
            if entry.isManageable && !canAssociate, let index = ordered.firstIndex(where: { $0.autosaveName == entry.autosaveName }) {
                let internalName = entry.autosaveName.range(of: #"^(?:Item|item|StatusItem|statusItem)[-_.0-9]*$"#, options: .regularExpression) != nil
                result.displayName = internalName ? "\(appName) · 图标 \(index + 1)" : "\(appName) · \(entry.autosaveName)"
                result.axName = ""
                result.order = nil
            }
            result.observedVisible = isRunning
                ? (isReadable && axItems.isEmpty ? false
                    : (isReadable && (canAssociate || !entry.isManageable) ? result.order != nil : nil))
                : false
            return result
        }
    }

    private func entry(
        for record: StatusItemPreferences.Record,
        axItem: AXStatusItem?,
        state: Entry.State,
        bundleID: String,
        appName: String,
        icon: NSImage?,
        isRunning: Bool
    ) -> Entry {
        let axName = axItem?.name ?? ""
        return Entry(
            id: "\(bundleID)/\(record.autosaveName)",
            bundleID: bundleID,
            appName: appName,
            autosaveName: record.autosaveName,
            displayName: displayName(axName: axName, appName: appName),
            state: state,
            isSystemOwned: false,
            icon: icon,
            isRunning: isRunning,
            order: axItem.map { Int($0.frame.minX) },
            axName: axName,
            // Some real status items (including Sogou's saved Item-0) have
            // visibility flags but no preferred-position key. The presence
            // of an NSStatusItem preference record is enough to manage it.
            isManageable: true
        )
    }

    private func displayName(axName: String, appName: String) -> String {
        let name = axName.trimmingCharacters(in: .whitespacesAndNewlines)
        // A counter or an internal symbol identifier does not identify the app.
        let isCounter = !name.isEmpty && name.allSatisfy(\.isNumber)
        let isSymbolIdentifier = name.range(
            of: #"^[a-z0-9]+(?:\.[a-z0-9]+)+$"#,
            options: .regularExpression
        ) != nil
        return name.isEmpty || isCounter || isSymbolIdentifier ? appName : name
    }

    /// Gives items that share a name a number, so three "ChatGPT Computer
    /// Use" entries can be told apart.
    private func disambiguate(_ entries: [Entry]) -> [Entry] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.bundleID + "/" + entry.displayName, default: 0] += 1
        }
        var seen: [String: Int] = [:]
        var result: [Entry] = []
        for var entry in entries {
            let key = entry.bundleID + "/" + entry.displayName
            guard counts[key] ?? 0 > 1 else {
                result.append(entry)
                continue
            }
            seen[key, default: 0] += 1
            entry.displayName = "\(entry.displayName) · 图标 \(seen[key]!)"
            result.append(entry)
        }
        return result
    }

    // MARK: - Hiding and showing

    /// Saves an item's visibility and restarts its owner only when safe.
    func setVisible(_ visible: Bool, for entry: Entry) async {
        guard hasAccessibilityAccess, entry.isManageable, !entry.isSystemOwned, !entry.autosaveName.isEmpty,
              pendingIDs.isEmpty, !isRefreshing else { return }
        if let windowID = entry.windowID, MenuBarWindowScanner.frame(of: windowID) == nil {
            statusMessage = "这个图标已经离开菜单栏，正在更新列表。"
            await refresh(force: true)
            return
        }
        pendingIDs.insert(entry.id)
        dismissStatus()
        defer { pendingIDs.remove(entry.id) }
        let action = visible ? "显示" : "隐藏"

        guard await writeVisibility(visible, for: entry) else {
            statusMessage = "未能保存「\(entry.appName)」的设置，请重试。"
            statusIsError = true
            pendingIDs.remove(entry.id)
            await refresh(force: true)
            return
        }

        if let app = runningApplication(bundleID: entry.bundleID) {
            pendingChanges[entry.preferenceID] = PendingChange(visible: visible, pid: app.processIdentifier, launchedAt: app.launchDate)
        }
        if visible {
            removeRemembered(entry.preferenceID)
        } else {
            remember(entry)
        }

        if !entry.isRunning {
            statusMessage = "已保存，下次打开「\(entry.appName)」时生效。"
        } else if let app = runningApplication(bundleID: entry.bundleID),
                  app.activationPolicy == .accessory {
            if await AppRestart.restart(app) {
                statusMessage = "已\(action)「\(entry.displayName)」。"
            } else {
                statusMessage = "设置已保存，请稍后重新打开「\(entry.appName)」。"
            }
        } else {
            statusMessage = "已保存，重新打开「\(entry.appName)」后生效。"
        }

        pendingIDs.remove(entry.id)
        await refresh(force: true)
    }

    /// Restarts the owning app so a change that is waiting for it lands.
    func applyNow(for entry: Entry) async {
        guard entry.isManageable, !entry.isSystemOwned, pendingIDs.isEmpty, !isRefreshing else { return }
        pendingIDs.insert(entry.id)
        dismissStatus()
        defer { pendingIDs.remove(entry.id) }

        let visible = entry.state != .hiding

        if !entry.isRunning {
            statusMessage = "所属应用「\(entry.appName)」没有运行；设置会在它下次启动时应用。"
            pendingIDs.remove(entry.id)
            await refresh(force: true)
            return
        } else if let app = runningApplication(bundleID: entry.bundleID) {
            guard await AppRestart.restart(app) else {
                statusMessage = "设置已保存；「\(entry.appName)」未退出，可稍后重新打开。"
                statusIsError = true
                pendingIDs.remove(entry.id)
                await refresh(force: true)
                return
            }
        } else {
            statusMessage = "所属应用「\(entry.appName)」没有在运行，无法立即应用设置。"
            pendingIDs.remove(entry.id)
            await refresh(force: true)
            return
        }

        pendingIDs.remove(entry.id)
        await refresh(force: true)
        let requestedState = visible ? "显示" : "隐藏"
        statusMessage = "已重新打开「\(entry.appName)」，应用\(requestedState)设置。"
    }

    private func writeVisibility(_ visible: Bool, for entry: Entry) async -> Bool {
        let autosaveName = entry.autosaveName
        let bundleID = entry.bundleID
        await scanner.invalidate(bundleID: bundleID)
        let result = await Task.detached(priority: .userInitiated) {
            guard StatusItemPreferences.setVisible(
                visible,
                autosaveName: autosaveName,
                bundleID: bundleID
            ) else { return false }
            return StatusItemPreferences.isVisible(autosaveName: autosaveName, bundleID: bundleID) == visible
        }.value
        if result, sandboxPreferences[bundleID] != nil {
            sandboxPreferences[bundleID]?[StatusItemPreferences.visibleCCPrefix + autosaveName] = .flag(visible)
            sandboxPreferences[bundleID]?[StatusItemPreferences.visiblePrefix + autosaveName] = .flag(visible)
        }
        return result
    }

    /// Shows every hidden item at once.
    func showAll() async {
        let hidden = (entries + storedEntries).filter { $0.isManageable && !$0.isSystemOwned && !$0.isConfiguredVisible }
        guard hasAccessibilityAccess, pendingIDs.isEmpty, !isRefreshing, !hidden.isEmpty else { return }
        for entry in hidden { pendingIDs.insert(entry.id) }
        defer { pendingIDs.removeAll() }

        var changed: [Entry] = []
        var failed: [Entry] = []
        for entry in hidden {
            if await writeVisibility(true, for: entry) {
                removeRemembered(entry.preferenceID)
                if let app = runningApplication(bundleID: entry.bundleID) {
                    pendingChanges[entry.preferenceID] = PendingChange(visible: true, pid: app.processIdentifier, launchedAt: app.launchDate)
                }
                changed.append(entry)
            } else {
                failed.append(entry)
            }
        }

        var restartedOwners = Set<String>()
        var restartFailures: [String] = []
        for entry in changed where entry.isRunning && restartedOwners.insert(entry.bundleID).inserted {
            if let app = runningApplication(bundleID: entry.bundleID),
                      app.activationPolicy == .accessory {
                if !(await AppRestart.restart(app)) {
                    restartFailures.append(entry.appName)
                }
            }
        }

        let manualRestartOwners = Set(changed.compactMap { entry -> String? in
            guard entry.isRunning, !entry.isSystemOwned,
                  let app = runningApplication(bundleID: entry.bundleID),
                  app.activationPolicy != .accessory else { return nil }
            return entry.appName
        }).sorted()

        pendingIDs.removeAll()
        await refresh(force: true)
        var messages: [String] = []
        if !failed.isEmpty {
            messages.append("\(failed.count) 项设置未写入成功，请检查后重试。")
        }
        if !restartFailures.isEmpty {
            messages.append("以下应用无法自动重启：\(Set(restartFailures).sorted().joined(separator: "、"))。")
        }
        if !manualRestartOwners.isEmpty {
            messages.append("请重启以下所属应用以应用设置：\(manualRestartOwners.joined(separator: "、"))。")
        }
        if messages.isEmpty {
            messages.append("已保存所有显示设置；未运行的应用会在下次启动时应用。")
        }
        statusMessage = messages.joined(separator: " ")
        statusIsError = !failed.isEmpty || !restartFailures.isEmpty
    }

    // MARK: - Remembered hidden items

    private static let rememberedKey = "rememberedHiddenItems"

    /// The items this app hid, with enough detail to list them even after
    /// their owner has quit.
    private static var rememberedHiddenItems: [Entry] {
        guard let data = UserDefaults.standard.data(forKey: rememberedKey),
              let items = try? JSONDecoder().decode([RememberedItem].self, from: data) else { return [] }
        return items.map(\.entry)
    }

    private func remember(_ entry: Entry) {
        var remembered = Self.rememberedHiddenItems
        guard !remembered.contains(where: { $0.id == entry.preferenceID }) else { return }
        remembered.append(entry)
        if let data = try? JSONEncoder().encode(remembered.map(RememberedItem.init(entry:))) {
            UserDefaults.standard.set(data, forKey: Self.rememberedKey)
        }
    }

    private func removeRemembered(_ id: String) {
        let remembered = Self.rememberedHiddenItems.filter { $0.id != id }
        if let data = try? JSONEncoder().encode(remembered.map(RememberedItem.init(entry:))) {
            UserDefaults.standard.set(data, forKey: Self.rememberedKey)
        }
    }

    /// Codable form of an entry, for the small list of hidden items we keep.
    private struct RememberedItem: Codable {
        let id: String
        let bundleID: String
        let appName: String
        let autosaveName: String
        let displayName: String
        let isSystemOwned: Bool
        let order: Int?

        init(entry: Entry) {
            id = entry.preferenceID
            bundleID = entry.bundleID
            appName = entry.appName
            autosaveName = entry.autosaveName
            displayName = entry.displayName
            isSystemOwned = entry.isSystemOwned
            order = entry.order
        }

        var entry: Entry {
            Entry(
                id: id,
                bundleID: bundleID,
                appName: appName,
                autosaveName: autosaveName,
                displayName: displayName.hasPrefix("未命名状态栏图标") ? appName : displayName,
                state: .inactiveHidden,
                isSystemOwned: isSystemOwned,
                icon: nil,
                isRunning: false,
                order: order,
                axName: "",
                isManageable: !isSystemOwned && !bundleID.hasPrefix("com.apple.") && !autosaveName.isEmpty
            )
        }
    }

    // MARK: - Icons

    @ObservationIgnored private var iconCache: [String: NSImage] = [:]

    private func applicationURL(bundleID: String) -> URL? {
        if let saved = appURLs[bundleID], FileManager.default.fileExists(atPath: saved.path) { return saved }
        appURLs.removeValue(forKey: bundleID)
        guard !missingApps.contains(bundleID),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              FileManager.default.fileExists(atPath: url.path) else {
            missingApps.insert(bundleID)
            return nil
        }
        appURLs[bundleID] = url
        return url
    }

    private func icon(for app: NSRunningApplication) -> NSImage? {
        guard let id = app.bundleIdentifier, let url = app.bundleURL else { return nil }
        appURLs[id] = url
        return icon(bundleID: id)
    }

    private func icon(bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = applicationURL(bundleID: bundleID) else { return nil }
        let source = NSWorkspace.shared.icon(forFile: url.path)
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { rect in
            source.draw(in: rect)
            return true
        }
        // Rasterize now instead of retaining a drawing closure holding the
        // original potentially large icon. Both 1x and 2x displays are sharp.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 48, height: 48))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: size)
        small.addRepresentation(bitmap)
        if iconCache.count >= 128 { iconCache.removeAll(keepingCapacity: true) }
        iconCache[bundleID] = small
        return small
    }

    private func installedAppName(bundleID: String) -> String {
        if let name = appNames[bundleID] { return name }
        guard let url = applicationURL(bundleID: bundleID), let bundle = Bundle(url: url) else { return bundleID }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        appNames[bundleID] = name
        return name
    }

    // MARK: - Helpers

    private func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }
}

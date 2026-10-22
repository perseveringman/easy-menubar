//
//  StatusItemModel.swift
//  Bar
//
//  Owns the list of menu bar items and the hide/show operations.
//
//  Two different things are tracked for every item:
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

private struct AppScanTarget: Sendable {
    let bundleID: String
    let processIdentifier: pid_t?
    let localizedName: String?
}

private struct AppScanResult: Sendable {
    let target: AppScanTarget
    let records: [StatusItemPreferences.Record]
    let status: AXStatus
}

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
    init(entries: [Entry] = []) {
        self.entries = entries
    }

    private(set) var isRefreshing = false
    private var refreshGeneration: UInt64 = 0
    /// Entries whose change is still being applied by the system.
    private(set) var pendingIDs: Set<String> = []
    /// A short note about what just happened, shown under the list.
    private(set) var statusMessage: String?

    var searchText = ""

    /// `true` when the app can read other apps' menus for nicer labels.
    private(set) var hasAccessibilityAccess = false

    // MARK: - Derived state

    var onScreenEntries: [Entry] {
        entries.filter(\.isOnScreen)
    }

    var offScreenEntries: [Entry] {
        entries.filter { $0.isRunning && !$0.isOnScreen && !$0.isConfiguredVisible && $0.isManageable }
    }

    var inactiveEntries: [Entry] {
        entries.filter { !$0.isRunning }
    }

    var waitingToShowEntries: [Entry] {
        entries.filter { $0.state == .showing }
    }

    var filteredOnScreenEntries: [Entry] {
        filter(onScreenEntries)
    }

    var filteredOffScreenEntries: [Entry] {
        filter(offScreenEntries)
    }

    var filteredInactiveEntries: [Entry] {
        filter(inactiveEntries)
    }

    var filteredWaitingToShowEntries: [Entry] {
        filter(waitingToShowEntries)
    }

    var hasHiddenItems: Bool {
        entries.contains { !$0.isConfiguredVisible && $0.isManageable }
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

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        isRefreshing = true
        hasAccessibilityAccess = AccessibilityScanner.isAuthorized
        defer {
            if generation == refreshGeneration {
                isRefreshing = false
            }
        }

        let runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        var runningByBundleID: [String: NSRunningApplication] = [:]
        var targets: [String: AppScanTarget] = [:]
        for app in runningApps {
            guard let bundleID = app.bundleIdentifier else { continue }
            runningByBundleID[bundleID] = app
            targets[bundleID] = AppScanTarget(
                bundleID: bundleID,
                processIdentifier: app.processIdentifier,
                localizedName: app.localizedName
            )
        }

        let remembered = Self.rememberedHiddenItems
        for item in remembered where targets[item.bundleID] == nil {
            targets[item.bundleID] = AppScanTarget(
                bundleID: item.bundleID,
                processIdentifier: nil,
                localizedName: item.appName
            )
        }

        // Scan persisted non-sandboxed preference domains as well as live
        // apps. AX IPC and file reads run away from the main thread so a slow
        // helper process cannot freeze the list or its progress indicators.
        let runningTargets = Array(targets.values)
        let scanResults = await Task.detached(priority: .utility) {
            var allTargets = Dictionary(uniqueKeysWithValues: runningTargets.map { ($0.bundleID, $0) })
            for bundleID in StatusItemPreferences.bundleIDsWithStatusItemsInSharedPreferences() {
                if allTargets[bundleID] == nil {
                    allTargets[bundleID] = AppScanTarget(
                        bundleID: bundleID,
                        processIdentifier: nil,
                        localizedName: nil
                    )
                }
            }

            return allTargets.values.map { target in
                let status = target.processIdentifier.map {
                    AccessibilityScanner.status(forProcessIdentifier: $0)
                } ?? AXStatus(items: [], isReadable: false)
                return AppScanResult(
                    target: target,
                    records: StatusItemPreferences.records(for: target.bundleID),
                    status: status
                )
            }
        }.value

        var collected: [Entry] = []
        for result in scanResults {
            let target = result.target
            let runningApp = runningByBundleID[target.bundleID]
            let appName = runningApp?.localizedName
                ?? target.localizedName
                ?? installedAppName(bundleID: target.bundleID)
            let appIcon = runningApp.map { icon(for: $0) } ?? icon(bundleID: target.bundleID)
            let systemOwned = target.bundleID.hasPrefix("com.apple.")

            collected.append(contentsOf: entries(
                bundleID: target.bundleID,
                appName: appName,
                icon: appIcon,
                isSystemOwned: systemOwned,
                isRunning: runningApp != nil,
                records: result.records,
                axItems: result.status.items,
                isReadable: result.status.isReadable
            ))
        }

        // Preserve Bar-hidden items even when their preference file is no
        // longer readable or their owner has removed the status item.
        for item in remembered where !collected.contains(where: { $0.id == item.id }) {
            var entry = item
            if let app = runningByBundleID[item.bundleID] {
                entry.isRunning = true
                entry.icon = icon(for: app)
                if entry.state == .inactiveHidden { entry.state = .hidden }
            }
            collected.append(entry)
        }

        guard generation == refreshGeneration else { return }
        entries = disambiguate(collected.sorted { lhs, rhs in
            switch (lhs.order, rhs.order) {
            case let (l?, r?): l == r ? lhs.appName < rhs.appName : l < r
            case (nil, nil): lhs.appName == rhs.appName ? lhs.id < rhs.id : lhs.appName.localizedStandardCompare(rhs.appName) == .orderedAscending
            case (nil, _): false
            case (_, nil): true
            }
        })
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
            return axItems.map { axItem in
                Entry(
                    id: "\(bundleID)/system/\(Int(axItem.frame.minX))",
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
                    isManageable: false
                )
            }
        }

        // Left to right: the biggest position sits furthest left.
        let ordered = records.sorted { lhs, rhs in
            lhs.position == rhs.position
                ? lhs.autosaveName < rhs.autosaveName
                : lhs.position > rhs.position
        }

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
                } else if isReadable {
                    // macOS was told to show it, but the icon is not there.
                    result.append(entry(
                        for: record, axItem: nil, state: .showing,
                        bundleID: bundleID, appName: appName, icon: icon, isRunning: true
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
                let stillThere = isRunning && isReadable && !onScreen.isEmpty && onScreen.count > visibleLeft
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
        for axItem in onScreen {
            result.append(Entry(
                id: "\(bundleID)/#\(Int(axItem.frame.minX))",
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

        return result
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
        guard entry.isManageable, pendingIDs.isEmpty else { return }
        pendingIDs.insert(entry.id)
        statusMessage = nil
        defer { pendingIDs.remove(entry.id) }
        let action = visible ? "显示" : "隐藏"

        guard await writeVisibility(visible, for: entry) else {
            statusMessage = "macOS 没有确认「\(entry.displayName)」的\(action)设置写入成功。请重试；如果仍失败，可能是所属应用的偏好文件不可写。"
            pendingIDs.remove(entry.id)
            await refresh()
            return
        }

        if visible {
            removeRemembered(entry.id)
        } else {
            remember(entry)
        }

        if !entry.isRunning {
            statusMessage = "已保存「\(entry.displayName)」的\(action)设置；所属应用「\(entry.appName)」下次启动时生效。"
        } else if entry.isSystemOwned {
            await ControlCenter.restart()
            statusMessage = "已保存「\(entry.displayName)」的\(action)设置，并已刷新系统菜单栏。"
        } else if let app = runningApplication(bundleID: entry.bundleID),
                  app.activationPolicy == .accessory {
            if await AppRestart.restart(app) {
                statusMessage = "已保存「\(entry.displayName)」的\(action)设置，并已重启所属应用「\(entry.appName)」。"
            } else {
                statusMessage = "已保存「\(entry.displayName)」的设置，但无法自动重启所属应用「\(entry.appName)」。"
            }
        } else {
            statusMessage = "已保存「\(entry.displayName)」的\(action)设置；请重启所属应用「\(entry.appName)」后生效。"
        }

        pendingIDs.remove(entry.id)
        await refresh()
    }

    /// Restarts the owning app so a change that is waiting for it lands.
    func applyNow(for entry: Entry) async {
        guard pendingIDs.isEmpty else { return }
        pendingIDs.insert(entry.id)
        statusMessage = nil
        defer { pendingIDs.remove(entry.id) }

        let visible = entry.state != .hiding

        if !entry.isRunning {
            statusMessage = "所属应用「\(entry.appName)」没有运行；设置会在它下次启动时应用。"
            pendingIDs.remove(entry.id)
            await refresh()
            return
        } else if entry.isSystemOwned {
            await ControlCenter.restart()
        } else if let app = runningApplication(bundleID: entry.bundleID) {
            guard await AppRestart.restart(app) else {
                statusMessage = "已保存设置，但无法重启所属应用「\(entry.appName)」。"
                pendingIDs.remove(entry.id)
                await refresh()
                return
            }
        } else {
            statusMessage = "所属应用「\(entry.appName)」没有在运行，无法立即应用设置。"
            pendingIDs.remove(entry.id)
            await refresh()
            return
        }

        pendingIDs.remove(entry.id)
        await refresh()
        let requestedState = visible ? "显示" : "隐藏"
        statusMessage = "已请求重启所属应用「\(entry.appName)」以应用「\(entry.displayName)」的\(requestedState)设置；列表会在重扫后更新。"
    }

    private func writeVisibility(_ visible: Bool, for entry: Entry) async -> Bool {
        let autosaveName = entry.autosaveName
        let bundleID = entry.bundleID
        return await Task.detached(priority: .userInitiated) {
            guard StatusItemPreferences.setVisible(
                visible,
                autosaveName: autosaveName,
                bundleID: bundleID
            ) else { return false }
            return StatusItemPreferences.isVisible(
                autosaveName: autosaveName,
                bundleID: bundleID
            ) == visible
        }.value
    }

    /// Shows every hidden item at once.
    func showAll() async {
        let hidden = entries.filter { !$0.isConfiguredVisible && $0.isManageable }
        guard pendingIDs.isEmpty, !hidden.isEmpty else { return }
        for entry in hidden { pendingIDs.insert(entry.id) }
        defer { pendingIDs.removeAll() }

        var changed: [Entry] = []
        var failed: [Entry] = []
        for entry in hidden {
            if await writeVisibility(true, for: entry) {
                removeRemembered(entry.id)
                changed.append(entry)
            } else {
                failed.append(entry)
            }
        }

        var restartedOwners = Set<String>()
        var restartFailures: [String] = []
        for entry in changed where entry.isRunning && restartedOwners.insert(entry.bundleID).inserted {
            if entry.isSystemOwned {
                await ControlCenter.restart()
            } else if let app = runningApplication(bundleID: entry.bundleID),
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
        await refresh()
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
        guard !remembered.contains(where: { $0.id == entry.id }) else { return }
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
            id = entry.id
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
                isManageable: true
            )
        }
    }

    // MARK: - Icons

    private var iconCache: [String: NSImage] = [:]

    private func icon(for app: NSRunningApplication) -> NSImage? {
        let key = app.bundleIdentifier ?? ""
        if let cached = iconCache[key] { return cached }
        guard let url = app.bundleURL else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[key] = image
        return image
    }

    private func icon(bundleID: String) -> NSImage? {
        if let cached = iconCache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[bundleID] = image
        return image
    }

    private func installedAppName(bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let bundle = Bundle(url: url) else { return bundleID }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleID
    }

    // MARK: - Helpers

    private func runningApplication(bundleID: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
    }
}

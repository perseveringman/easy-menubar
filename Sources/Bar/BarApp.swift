import AppKit
import SwiftUI

extension Notification.Name {
    static let barFocusSearch = Notification.Name("BarFocusSearch")
    static let barRestoreMenuBarEntry = Notification.Name("BarRestoreMenuBarEntry")
}

@main
struct BarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = StatusItemModel()

    var body: some Scene {
        Window("Bar", id: "main") {
            ContentView()
                .environment(model)
                .background(WindowAccessor { delegate.attachWindow($0) })
                .task {
                    delegate.bind(model)
                    await model.refresh()
                    delegate.updateStatusItemIcon(hasHidden: model.hasHiddenItems)
                }
                .onChange(of: model.hasHiddenItems) { _, hidden in
                    delegate.updateStatusItemIcon(hasHidden: hidden)
                }
        }
        .defaultSize(width: 480, height: 560)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("关于 Bar") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Bar",
                        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                        .credits: NSAttributedString(string: "让菜单栏，留给常用的图标。\nhttps://github.com/perseveringman/easy-menubar")
                    ])
                }
            }
            CommandGroup(after: .textEditing) {
                Button("搜索应用") { NotificationCenter.default.post(name: .barFocusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appTermination) {
                Button("退出 Bar") { NSApp.terminate(nil) }
                    .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

/// Workspace/focus events handle normal changes. A lightweight window check
/// fills notification gaps only while our window is foreground; no periodic
/// scans or permission checks run while Bar waits closed in the menu bar.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: StatusItemModel?
    private var statusItem: NSStatusItem?
    private var observations: [(NotificationCenter, NSObjectProtocol)] = []
    private var refreshTask: Task<Void, Never>?
    private var visibleInventoryTask: Task<Void, Never>?
    private var hasLaunched = false
    private var didPresentWindow = false

    func bind(_ model: StatusItemModel) {
        self.model = model
        startIfNeeded()
        startVisibleInventoryChecks()
    }

    func attachWindow(_ window: NSWindow?) {
        guard let window, self.window !== window else { return }
        self.window = window
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BarMainWindow")
        observe(NSWindow.didBecomeKeyNotification, object: window) { [weak self] _ in
            self?.requestRefresh()
            self?.startVisibleInventoryChecks()
        }
        observe(NSWindow.didResignKeyNotification, object: window) { [weak self] _ in
            self?.stopVisibleInventoryChecks()
        }
        observe(NSWindow.willCloseNotification, object: window) { [weak self] _ in
            self?.refreshTask?.cancel()
            self?.stopVisibleInventoryChecks()
            self?.model?.dismissStatus()
        }
        observe(NSWindow.didMiniaturizeNotification, object: window) { [weak self] _ in
            self?.refreshTask?.cancel()
            self?.stopVisibleInventoryChecks()
        }
        observe(NSWindow.didDeminiaturizeNotification, object: window) { [weak self] _ in
            self?.requestRefresh()
        }
        if hasLaunched && !didPresentWindow { openWindow() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        startIfNeeded()
    }

    /// Either SwiftUI's first content task or AppKit's launch callback can
    /// arrive first. Both must lead to exactly one live menu-bar entry.
    private func startIfNeeded() {
        guard !hasLaunched else { return }
        hasLaunched = true
        restoreMenuBarEntry()

        observe(.barRestoreMenuBarEntry) { [weak self] _ in
            self?.restoreMenuBarEntry()
            self?.model?.reportMenuBarRecovery()
        }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in self?.requestRefresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(name, center: workspace) { [weak self] bundleID in
                guard bundleID != Bundle.main.bundleIdentifier else { return }
                self?.model?.applicationChanged(bundleID: bundleID)
                self?.requestRefresh(force: true)
            }
        }
        observe(NSWorkspace.didWakeNotification, center: workspace) { [weak self] _ in
            self?.model?.applicationChanged(bundleID: nil)
            self?.requestRefresh(force: true)
        }
        observe(NSWorkspace.activeSpaceDidChangeNotification, center: workspace) { [weak self] _ in
            self?.model?.applicationChanged(bundleID: nil)
            self?.requestRefresh(force: true)
        }
        observe(NSApplication.didChangeScreenParametersNotification) { [weak self] _ in
            self?.model?.applicationChanged(bundleID: nil)
            self?.requestRefresh(force: true)
        }
        if window != nil { openWindow() }
    }

    private func restoreMenuBarEntry() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        MenuBarEntryPreferences.prepare()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = MenuBarEntryPreferences.name
        item.isVisible = true
        item.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "Bar")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Bar · 显示或收起窗口，右键显示菜单"
        item.button?.setAccessibilityLabel("Bar · 菜单栏图标管理")
        statusItem = item
        updateStatusItemIcon(hasHidden: model?.hasHiddenItems ?? false)
    }

    private func observe(_ name: Notification.Name, object: AnyObject? = nil,
                         center: NotificationCenter = .default,
                         action: @escaping @MainActor (String?) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { notification in
            let id = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { action(id) }
        }
        observations.append((center, token))
    }

    private func requestRefresh(force: Bool = false) {
        guard let window, window.isVisible, !window.isMiniaturized, let model, !model.isBusy else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            guard let self, self.window?.isVisible == true else { return }
            await model.refresh(force: force)
        }
    }

    private func startVisibleInventoryChecks() {
        guard let window, window.isVisible, window.isKeyWindow, !window.isMiniaturized, let model else { return }
        visibleInventoryTask?.cancel()
        visibleInventoryTask = Task { [weak self, weak model] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                guard let self, let model, let window = self.window,
                      window.isVisible, window.isKeyWindow, !window.isMiniaturized else { return }
                await model.refreshIfMenuBarChanged()
            }
        }
    }

    private func stopVisibleInventoryChecks() {
        visibleInventoryTask?.cancel()
        visibleInventoryTask = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTask?.cancel()
        stopVisibleInventoryChecks()
        for (center, token) in observations { center.removeObserver(token) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func updateStatusItemIcon(hasHidden: Bool) {
        statusItem?.button?.image = NSImage(systemSymbolName: hasHidden ? "eye.slash.fill" : "eye.slash",
                                           accessibilityDescription: "Bar")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func openWindow() {
        guard let window else { return }
        didPresentWindow = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        requestRefresh()
        startVisibleInventoryChecks()
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let statusItem else { return }
            let menu = NSMenu()
            let open = menu.addItem(withTitle: "打开 Bar", action: #selector(openWindow), keyEquivalent: "")
            open.target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "退出 Bar", action: #selector(quit), keyEquivalent: "q").target = self
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
        } else if window?.isKeyWindow == true, window?.isVisible == true {
            window?.orderOut(nil)
            refreshTask?.cancel()
        } else {
            openWindow()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> WindowObserver {
        let view = WindowObserver()
        view.onResolve = onResolve
        return view
    }
    func updateNSView(_ view: WindowObserver, context: Context) {
        view.onResolve = onResolve
        if let window = view.window { onResolve(window) }
    }
}

final class WindowObserver: NSView {
    var onResolve: (NSWindow?) -> Void = { _ in }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onResolve(window)
    }
}

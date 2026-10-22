//
//  BarApp.swift
//  Bar
//
//  A menu bar app that keeps one screen: the list of status bar items.
//

import AppKit
import SwiftUI

@main
struct BarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = StatusItemModel()

    var body: some Scene {
        Window("状态栏", id: "main") {
            ContentView()
                .environment(model)
                .background(WindowAccessor { window in delegate.window = window })
                .task {
                    await model.refresh()
                    delegate.model = model
                    delegate.updateStatusItemIcon(hasHidden: model.hasHiddenItems)
                }
                .onChange(of: model.hasHiddenItems) { _, hasHidden in
                    delegate.updateStatusItemIcon(hasHidden: hasHidden)
                }
        }
        .defaultSize(width: 480, height: 600)
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
            CommandGroup(replacing: .appTermination) {
                Button("退出 Bar") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    var model: StatusItemModel?

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "eye.slash", accessibilityDescription: "状态栏")
        item.button?.image?.isTemplate = true
        item.button?.target = self
        item.button?.action = #selector(handleStatusItemClick(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Bar · 点击打开，右键显示菜单"
        statusItem = item

        // Bring the window forward the first time so the app explains itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.openWindow()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func updateStatusItemIcon(hasHidden: Bool) {
        let symbol = hasHidden ? "eye.slash.fill" : "eye.slash"
        statusItem?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "状态栏")
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func handleStatusItemClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        guard event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true else {
            openWindow()
            return
        }

        guard let statusItem else { return }
        let menu = NSMenu()
        let openItem = menu.addItem(withTitle: "打开 Bar", action: #selector(openWindow), keyEquivalent: "")
        openItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(withTitle: "退出 Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// Hands the `NSWindow` that hosts the SwiftUI content to the app delegate,
/// so the menu bar button can bring it forward.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

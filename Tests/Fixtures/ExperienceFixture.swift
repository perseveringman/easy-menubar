import AppKit

let application = NSApplication.shared
let kind = Bundle.main.object(forInfoDictionaryKey: "AuditKind") as? String ?? "utility"
let isRegular = kind == "regular" || kind == "refusing"
application.setActivationPolicy(isRegular ? .regular : .accessory)

final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var items: [(String, NSStatusItem)] = []
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "退出测试应用", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        mainMenu.addItem(appMenuItem)
        NSApp.mainMenu = mainMenu
        let names = kind == "multiple" ? ["Clock", "Focus"] : ["AuditItem"]
        for name in names {
            let key = "NSStatusItem VisibleCC \(name)"
            if kind != "unnamed", UserDefaults.standard.object(forKey: key) == nil {
                UserDefaults.standard.set(true, forKey: key)
                UserDefaults.standard.synchronize()
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if kind != "unnamed" { item.autosaveName = name }
            item.button?.title = kind == "multiple" ? name : "Audit"
            item.button?.toolTip = "Bar Audit \(kind) \(name)"
            items.append((name, item))
        }
        if isRegular || kind == "unnamed" {
            let view = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            view.title = "Bar Audit \(kind)"
            let label = NSTextField(labelWithString: kind == "refusing" ? "Test app refuses normal termination." : "Disposable test application. No user documents.")
            label.frame = NSRect(x: 16, y: 35, width: 270, height: 40)
            label.maximumNumberOfLines = 2
            view.contentView?.addSubview(label)
            self.window = view
            if kind == "unnamed" { view.makeKeyAndOrderFront(nil) }
        }
        recordState()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        kind == "refusing" ? .terminateCancel : .terminateNow
    }
    func recordState() {
        let payload: [String: Any] = [
            "kind": kind, "pid": ProcessInfo.processInfo.processIdentifier,
            "items": items.map { ["name": $0.0, "visible": $0.1.isVisible] as [String: Any] },
        ]
        try? JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: "/private/tmp/bar-audit-\(kind).json"), options: .atomic)
    }
}
let delegate = FixtureDelegate()
application.delegate = delegate
application.run()

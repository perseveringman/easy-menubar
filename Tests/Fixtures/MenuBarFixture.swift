// Standalone disposable UI fixture. No third-party app settings are changed.
import AppKit
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
final class Delegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let key = "NSStatusItem VisibleCC ReleaseFixture"
        if UserDefaults.standard.object(forKey: key) == nil {
            UserDefaults.standard.set(true, forKey: key)
            UserDefaults.standard.synchronize()
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "ReleaseFixture"
        item.button?.title = "Bar Test"
        item.button?.toolTip = "Bar Release Test"
        self.item = item
        let state = ["pid": String(ProcessInfo.processInfo.processIdentifier), "visible": String(item.isVisible)]
        try? JSONSerialization.data(withJSONObject: state).write(to: URL(fileURLWithPath: "/tmp/bar-release-fixture-state.json"))
    }
}
let delegate = Delegate()
app.delegate = delegate
app.run()

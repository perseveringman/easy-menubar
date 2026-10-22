//
//  AppRestart.swift
//  Bar
//
//  Restarts a menu bar utility so it rebuilds its status item.
//
//  macOS reads a status item's visibility when the app creates it, so a
//  freshly written flag only shows up once the owner builds the item again.
//  Request normal termination only; never force-quit an app that refuses.
//

import AppKit
import Darwin

enum AppRestart {
    /// Quits the app and launches it again. Returns `false` when the app
    /// could not be bounced.
    @discardableResult
    static func restart(_ app: NSRunningApplication) async -> Bool {
        guard let bundleURL = app.bundleURL else { return false }
        let pid = app.processIdentifier

        app.terminate()

        // Wait for the app to actually go away before starting it again.
        var didExit = false
        for _ in 0 ..< 30 {
            if kill(pid, 0) != 0 {
                didExit = true
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard didExit else { return false }
        try? await Task.sleep(for: .milliseconds(250))

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration)
            return true
        } catch {
            return false
        }
    }
}

//
//  ControlCenter.swift
//  Bar
//
//  macOS 26 hosts every menu bar item inside Control Center, and Control
//  Center caches each item's visibility. Writing the preference is only
//  half the job — the host has to read it again.
//
//  Restarting Control Center makes it re-read every status item's
//  preferences. It relaunches on its own immediately, so the menu bar only
//  blinks for a moment.
//

import Foundation

enum ControlCenter {
    /// Restarts Control Center and waits for it to come back.
    static func restart() async {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
            process.arguments = ["ControlCenter"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }.value

        // Give the relaunch a moment before the bar is re-read.
        try? await Task.sleep(for: .milliseconds(900))
    }
}

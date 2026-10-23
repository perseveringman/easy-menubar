import Foundation
import XCTest
@testable import Bar

final class ScannerCacheTests: XCTestCase {
    private var home: URL!
    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: home.appending(path: "Library/Preferences"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: home) }

    private func write(_ value: [String: Any], domain: String, container: Bool = false, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        let path = container ? "Library/Containers/\(domain)/Data/Library/Preferences/\(domain).plist" : "Library/Preferences/\(domain).plist"
        let url = home.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0).write(to: url, options: .atomic)
    }

    func testWarmScanReadsNoUnchangedFilesAndDoesNotIncludeUnrelatedPreferences() throws {
        for index in 0 ..< 100 { try write(["unrelated": String(repeating: "x", count: 2048)], domain: "test.unrelated.\(index)") }
        try write(["NSStatusItem VisibleCC main": false], domain: "test.menu")
        var cache = StatusPreferenceCache(home: home)
        let cold = cache.scan(bundleIDs: ["test.menu"], excluding: nil)
        XCTAssertEqual(cold.records.count, 1)
        XCTAssertEqual(cold.records["test.menu"]?.first?.isVisible, false)
        XCTAssertEqual(cold.filesRead, 101)
        let warm = cache.scan(bundleIDs: ["test.menu"], excluding: nil)
        XCTAssertEqual(warm.filesRead, 0)
        XCTAssertGreaterThanOrEqual(warm.cacheHits, 101)
    }

    func testFileChangesNewFilesAndDeletionArePickedUpWithoutClearingTheCache() throws {
        try write(["NSStatusItem VisibleCC main": false], domain: "test.menu")
        var cache = StatusPreferenceCache(home: home)
        _ = cache.scan(bundleIDs: [], excluding: nil)
        try write(["NSStatusItem VisibleCC main": true, "NSStatusItem Preferred Position main": 200], domain: "test.menu")
        try write(["NSStatusItem VisibleCC added": false], domain: "test.new")
        let changed = cache.scan(bundleIDs: [], excluding: nil)
        XCTAssertEqual(changed.filesRead, 2)
        XCTAssertEqual(changed.records["test.menu"]?.first?.isVisible, true)
        try FileManager.default.removeItem(at: home.appending(path: "Library/Preferences/test.menu.plist"))
        XCTAssertNil(cache.scan(bundleIDs: [], excluding: nil).records["test.menu"])
    }

    func testUnicodeBinaryKeysAndContainerOverlayKeepSharedFields() throws {
        let name = "中文图标"
        try write(["NSStatusItem VisibleCC \(name)": false, "NSStatusItem Preferred Position \(name)": 12], domain: "test.container")
        try write(["NSStatusItem Preferred Position \(name)": 99], domain: "test.container", container: true)
        var cache = StatusPreferenceCache(home: home)
        let snapshot = cache.scan(bundleIDs: ["test.container"], excluding: nil, includeContainers: true)
        XCTAssertEqual(snapshot.records["test.container"]?.first?.autosaveName, name)
        XCTAssertEqual(snapshot.records["test.container"]?.first?.isVisible, false)
        XCTAssertEqual(snapshot.records["test.container"]?.first?.position, 99)
    }

    func testInitialScanDoesNotReadContainersUntilRequested() throws {
        try write(["NSStatusItem VisibleCC sandbox": false], domain: "test.protected", container: true)
        var cache = StatusPreferenceCache(home: home)
        let initial = cache.scan(bundleIDs: ["test.protected"], excluding: nil)
        XCTAssertTrue(initial.records.isEmpty)
        XCTAssertEqual(initial.filesRead, 0)
        let optedIn = cache.scan(bundleIDs: ["test.protected"], excluding: nil, includeContainers: true)
        XCTAssertEqual(optedIn.records["test.protected"]?.first?.isVisible, false)
    }

    func testProtectedReadTimeoutDoesNotWaitForAnUnansweredSystemDecision() throws {
        let script = home.appending(path: "blocked-reader.sh")
        try Data("exec /bin/sleep 30\n".utf8).write(to: script)
        let start = Date()
        let result = StatusPreferenceCache.readProtectedFile(script,
            executable: URL(fileURLWithPath: "/bin/sh"), timeout: 0.05)
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testXMLAndOwnAndAppleDomains() throws {
        try write(["NSStatusItem VisibleCC item": true], domain: "test.xml", format: .xml)
        try write(["NSStatusItem VisibleCC item": false], domain: "test.self")
        try write(["NSStatusItem VisibleCC item": false], domain: "com.apple.fake")
        var cache = StatusPreferenceCache(home: home)
        let result = cache.scan(bundleIDs: ["test.self", "com.apple.fake"], excluding: "test.self")
        XCTAssertEqual(Set(result.records.keys), ["test.xml"])
    }

    func testSystemAndInvalidWritesAreRejectedBeforeLaunchingDefaults() {
        XCTAssertFalse(StatusItemPreferences.setVisible(false, autosaveName: "main", bundleID: "com.apple.fake"))
        XCTAssertFalse(StatusItemPreferences.setVisible(false, autosaveName: "", bundleID: "test.fixture"))
        XCTAssertFalse(StatusItemPreferences.setVisible(false, autosaveName: "main", bundleID: "/tmp/file"))
    }
}

private final class ProbeCounter: @unchecked Sendable {
    let lock = NSLock()
    var active = 0
    var maximum = 0
    func probe(_ pid: pid_t) -> AXStatus {
        lock.lock(); active += 1; maximum = max(active, maximum); lock.unlock()
        Thread.sleep(forTimeInterval: 0.015)
        lock.lock(); active -= 1; lock.unlock()
        return AXStatus(items: [], isReadable: pid != 3)
    }
}

@MainActor
final class AccessibilitySchedulingTests: XCTestCase {
    func testSlowOwnersDoNotCreateUnboundedConcurrentIPCOrDropOtherResults() async {
        let counter = ProbeCounter()
        let targets = (1...20).map { AppScanTarget(bundleID: "test.\($0)", processIdentifier: pid_t($0), localizedName: nil) }
        let result = await StatusItemScanner.accessibility(for: targets, probe: counter.probe)
        XCTAssertEqual(result.count, 20)
        XCTAssertEqual(result["test.3"]?.isReadable, false)
        XCTAssertTrue(result["test.20"]!.isReadable)
        XCTAssertGreaterThan(counter.maximum, 1)
        XCTAssertLessThanOrEqual(counter.maximum, 4)
    }
}

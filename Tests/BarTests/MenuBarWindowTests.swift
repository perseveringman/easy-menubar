import CoreGraphics
import XCTest
@testable import Bar

final class MenuBarWindowTests: XCTestCase {
    private let host = MenuBarProcess(pid: 10, bundleID: "com.apple.controlcenter", name: "Control Center")
    private let utility = MenuBarProcess(pid: 20, bundleID: "test.utility", name: "Utility")
    private let other = MenuBarProcess(pid: 30, bundleID: "test.other", name: "Other")
    private let first = CGRect(x: 100, y: 0, width: 24, height: 24)
    private let second = CGRect(x: 124, y: 0, width: 24, height: 24)

    private func window(_ id: CGWindowID = 1, frame: CGRect? = nil, title: String = "", pid: pid_t = 10) -> MenuBarWindow {
        MenuBarWindow(id: id, hostPID: pid, title: title, frame: frame ?? first, isOnScreen: true)
    }

    private func status(_ name: String, frame: CGRect? = nil) -> AXStatus {
        AXStatus(items: [AXStatusItem(name: name, frame: frame ?? first)], isReadable: true)
    }

    func testHostedWindowsResolveToCreatorsRatherThanSharedHost() {
        let resolved = MenuBarWindowScanner.resolve([window(), window(2, frame: second)],
            processes: [host, utility, other], accessibility: [
                host.bundleID: AXStatus(items: [AXStatusItem(name: "Item-0", frame: first), AXStatusItem(name: "Item-1", frame: second)], isReadable: true),
                utility.bundleID: status("Utility menu"), other.bundleID: status("Other menu", frame: second),
            ])
        XCTAssertEqual(resolved.map { $0.source?.bundleID }, [utility.bundleID, other.bundleID])
        XCTAssertEqual(resolved.map(\.accessibleName), ["Utility menu", "Other menu"])
    }

    func testAmbiguousCreatorAndGenericHostSlotRemainUnknown() {
        let conflict = MenuBarWindowScanner.resolve([window()], processes: [host, utility, other],
            accessibility: [utility.bundleID: status("A"), other.bundleID: status("B")])
        XCTAssertNil(conflict[0].source)
        let generic = MenuBarWindowScanner.resolve([window()], processes: [host],
            accessibility: [host.bundleID: status("Item-0")])
        XCTAssertNil(generic[0].source, "A generic host slot cannot identify the owner")
    }

    func testDescriptiveHostedButtonDoesNotFalselyBecomeAnAppleItem() {
        let resolved = MenuBarWindowScanner.resolve([window()], processes: [host, utility],
            accessibility: [host.bundleID: status("Audit")])
        XCTAssertNil(resolved[0].source)
        XCTAssertEqual(resolved[0].accessibleName, "Audit", "The host may supply a useful label without owning the icon")
    }

    func testHostedAXIdentifierCanNameTheCreatorWithoutItsOwnExtrasMenu() {
        let ax = AXStatus(items: [AXStatusItem(name: "Utility", frame: first, identifier: "test.utility.Item-0")], isReadable: true)
        let resolved = MenuBarWindowScanner.resolve([window()], processes: [host, utility], accessibility: [host.bundleID: ax])
        XCTAssertEqual(resolved[0].source?.pid, utility.pid)
    }

    func testNearbyIconCannotBorrowAnOwnersIdentity() {
        let near = first.offsetBy(dx: 3, dy: 0)
        let resolved = MenuBarWindowScanner.resolve([window()], processes: [host, utility],
            accessibility: [utility.bundleID: status("Utility", frame: near)])
        XCTAssertNil(resolved[0].source)
    }

    func testHostedWindowPaddingDoesNotPreventAnExactCenterMatch() {
        let cgFrame = CGRect(x: 100, y: 0, width: 42, height: 33)
        let axFrame = CGRect(x: 103, y: 4.5, width: 36, height: 24)
        let resolved = MenuBarWindowScanner.resolve([window(frame: cgFrame)], processes: [host, utility],
            accessibility: [utility.bundleID: status("Utility", frame: axFrame)])
        XCTAssertEqual(resolved[0].source?.pid, utility.pid)
        XCTAssertEqual(resolved[0].accessibleName, "Utility")
    }

    func testAsymmetricPaddingRequiresUniqueFullContainmentNotMereProximity() {
        let cgFrame = CGRect(x: 100, y: 0, width: 50, height: 33)
        let axFrame = CGRect(x: 102, y: 4.5, width: 24, height: 24)
        let resolved = MenuBarWindowScanner.resolve([window(frame: cgFrame)], processes: [host, utility],
            accessibility: [utility.bundleID: status("Utility", frame: axFrame)])
        XCTAssertEqual(resolved[0].source?.pid, utility.pid)
        let ambiguous = MenuBarWindowScanner.resolve([window(frame: cgFrame)], processes: [host, utility, other],
            accessibility: [utility.bundleID: status("Utility", frame: axFrame),
                            other.bundleID: status("Other", frame: axFrame.offsetBy(dx: 5, dy: 0))])
        XCTAssertNil(ambiguous[0].source)
    }

    func testNativeWindowOwnerDoesNotRequireAnAXLabel() {
        let resolved = MenuBarWindowScanner.resolve([window(pid: utility.pid)], processes: [utility], accessibility: [:])
        XCTAssertEqual(resolved[0].source?.pid, utility.pid)
        XCTAssertTrue(resolved[0].accessibleName.isEmpty)
    }

    func testTitleNamespaceRequiresBoundaryAndPrefersLongestBundleID() {
        let helper = MenuBarProcess(pid: 40, bundleID: "test.utility.helper", name: "Helper")
        let resolved = MenuBarWindowScanner.resolve([window(title: "test.utility.helper.Item-0"), window(2, title: "test.utilityish.Item-0")],
            processes: [host, utility, helper], accessibility: [:])
        XCTAssertEqual(resolved[0].source?.pid, helper.pid)
        XCTAssertNil(resolved[1].source)
    }

    func testPartialHistoryCannotBeMatchedByPositionOrCountOfVisibleFlags() {
        let item = ResolvedMenuBarWindow(window: window(), source: utility, accessibleName: "Current icon")
        let records = [
            StatusItemPreferences.Record(autosaveName: "Item-0", isVisible: false, position: 200),
            StatusItemPreferences.Record(autosaveName: "Item-1", isVisible: true, position: 100),
        ]
        XCTAssertNil(MenuBarWindowScanner.matchingRecord(for: item, siblings: [item], records: records))
        let secondItem = ResolvedMenuBarWindow(window: window(2, frame: second), source: utility, accessibleName: "Other icon")
        XCTAssertNil(MenuBarWindowScanner.matchingRecord(for: item, siblings: [item, secondItem], records: records),
            "Even equal counts do not establish which historical key belongs to which live window")
    }

    func testExactItemIdentitySurvivesReorderingAndSingleRecordIsNotSharedByTwoWindows() {
        let records = [
            StatusItemPreferences.Record(autosaveName: "Clock", isVisible: true, position: 200),
            StatusItemPreferences.Record(autosaveName: "Focus", isVisible: false, position: 100),
        ]
        let item = ResolvedMenuBarWindow(window: window(title: "test.utility.Focus"), source: utility, accessibleName: "Focus mode")
        XCTAssertEqual(MenuBarWindowScanner.matchingRecord(for: item, siblings: [item], records: records)?.autosaveName, "Focus")
        let generic = ResolvedMenuBarWindow(window: window(), source: utility, accessibleName: "")
        let another = ResolvedMenuBarWindow(window: window(2, frame: second), source: utility, accessibleName: "")
        XCTAssertNil(MenuBarWindowScanner.matchingRecord(for: generic, siblings: [generic, another], records: [records[0]]))
    }

    @MainActor
    func testThreeSavedHiddenKeysCannotCreateThreeCurrentIcons() {
        let model = StatusItemModel()
        let records = (0..<3).map { StatusItemPreferences.Record(autosaveName: "Item-\($0)", isVisible: false, position: $0) }
        let old = model.entries(bundleID: utility.bundleID, appName: utility.name, icon: nil,
            isSystemOwned: false, isRunning: true, records: records, axItems: [], isReadable: false)
        let actual = ResolvedMenuBarWindow(window: window(), source: utility, accessibleName: "Current icon")
        let inventory = model.makeLiveEntries([actual], records: [utility.bundleID: records], legacy: old)
        XCTAssertEqual(inventory.current.count, 1)
        XCTAssertEqual(inventory.current[0].windowID, 1)
        XCTAssertEqual(inventory.current[0].displayName, "Current icon")
        XCTAssertFalse(inventory.current[0].isManageable, "Ambiguous old keys cannot back a writable switch")
        XCTAssertEqual(inventory.stored.count, 3)
        let stopped = model.makeLiveEntries([], records: [utility.bundleID: records], legacy: old)
        XCTAssertTrue(stopped.current.isEmpty)
        XCTAssertEqual(stopped.stored.count, 3, "Old hidden settings must remain recoverable")
    }

    @MainActor
    func testOffscreenLiveWindowDoesNotConsumeItsOnlyLegacyRecoveryControl() {
        let model = StatusItemModel()
        let record = StatusItemPreferences.Record(autosaveName: "main", isVisible: false, position: 10)
        let old = model.entries(bundleID: utility.bundleID, appName: utility.name, icon: nil,
            isSystemOwned: false, isRunning: true, records: [record], axItems: [], isReadable: false)
        let offscreen = MenuBarWindow(id: 1, hostPID: 10, title: "", frame: first, isOnScreen: false)
        let actual = ResolvedMenuBarWindow(window: offscreen, source: utility, accessibleName: "Utility")
        let inventory = model.makeLiveEntries([actual], records: [utility.bundleID: [record]], legacy: old)
        XCTAssertEqual(inventory.current.count, 1)
        XCTAssertFalse(inventory.current[0].isManageable)
        XCTAssertEqual(inventory.stored.map(\.preferenceID), [utility.bundleID + "/main"],
            "A readonly current window must not remove the user's legacy restore action")
    }
}

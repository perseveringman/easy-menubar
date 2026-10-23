import AppKit
import XCTest
@testable import Bar

final class PreferenceTests: XCTestCase {
    func testPositionOnlyItemDefaultsToVisible() {
        let records = StatusItemPreferences.records(in: ["NSStatusItem Preferred Position utility": 120])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.autosaveName, "utility")
        XCTAssertEqual(records.first?.isVisible, true)
    }

    func testCurrentVisibilityWinsOverLegacyAndMissingPositionIsManageable() {
        let records = StatusItemPreferences.records(in: [
            "NSStatusItem VisibleCC Item-0": false,
            "NSStatusItem Visible Item-0": true,
            "NSStatusItem Visible legacy": false,
            "unrelated": true,
            "NSStatusItem VisibleCC ": true,
        ])
        XCTAssertEqual(records.count, 2)
        XCTAssertTrue(records.allSatisfy { !$0.isVisible })
        XCTAssertTrue(records.allSatisfy { $0.position == 0 })
    }
}

final class ModelTests: XCTestCase {
    @MainActor
    func testInactiveHiddenAndPendingItemsAppearInOneSection() {
        let states: [StatusItemModel.Entry.State] = [.shown, .hiding, .hidden, .showing, .inactiveVisible, .inactiveHidden]
        let entries = states.enumerated().map { index, state in
            StatusItemModel.Entry(id: "item-\(index)", bundleID: "test.bar", appName: "Test", autosaveName: "item-\(index)", displayName: "Test", state: state, isSystemOwned: false, icon: nil, isRunning: index < 4, order: nil, axName: "", isManageable: true)
        }
        let model = StatusItemModel(entries: entries)
        let allSections = model.shownEntries + model.hiddenEntries + model.inactiveEntries + model.unmanagedEntries
        XCTAssertEqual(allSections.count, entries.count)
        XCTAssertEqual(Set(allSections.map(\.id)).count, entries.count)
        XCTAssertTrue(model.hasHiddenItems)
        let inactiveOnly = StatusItemModel(entries: [entries.last!])
        XCTAssertTrue(inactiveOnly.hasHiddenItems, "Restore all must remain available for stopped apps")
        XCTAssertEqual(inactiveOnly.hiddenEntries.count, 1)
        XCTAssertTrue(inactiveOnly.inactiveEntries.isEmpty)
    }

    @MainActor
    func testUnreadableAccessibilityDoesNotClaimPendingRestart() {
        let model = StatusItemModel()
        let records = [StatusItemPreferences.Record(autosaveName: "main", isVisible: true, position: 10)]
        let unreadable = model.entries(bundleID: "test.bar", appName: "Test", icon: nil, isSystemOwned: false, isRunning: true, records: records, axItems: [], isReadable: false)
        XCTAssertEqual(unreadable.first?.state, .shown)
        let readable = model.entries(bundleID: "test.bar", appName: "Test", icon: nil, isSystemOwned: false, isRunning: true, records: records, axItems: [], isReadable: true)
        XCTAssertEqual(readable.first?.state, .shown, "An old visible preference is not a request to restart")
        XCTAssertEqual(readable.first?.observedVisible, false)
        XCTAssertNil(unreadable.first?.observedVisible)
    }

    @MainActor
    func testUnnamedAndSystemItemsCannotBeChanged() {
        let model = StatusItemModel()
        let ax = [AXStatusItem(name: "A menu", frame: CGRect(x: 10, y: 0, width: 20, height: 24))]
        for isSystem in [false, true] {
            let entries = model.entries(bundleID: "test.bar", appName: "Test", icon: nil, isSystemOwned: isSystem, isRunning: true, records: [], axItems: ax, isReadable: true)
            XCTAssertEqual(entries.count, 1)
            XCTAssertEqual(entries.first?.isManageable, false)
        }
    }

    @MainActor
    func testAmbiguousMultipleItemsDoNotBorrowAnotherIconsNameOrClaimItsVisibility() {
        let model = StatusItemModel()
        let records = [
            StatusItemPreferences.Record(autosaveName: "Clock", isVisible: true, position: 0, hasKnownPosition: false),
            StatusItemPreferences.Record(autosaveName: "Focus", isVisible: false, position: 0, hasKnownPosition: false),
        ]
        let ax = [AXStatusItem(name: "Different unnamed item", frame: CGRect(x: 10, y: 0, width: 20, height: 24))]
        let entries = model.entries(bundleID: "test.multiple", appName: "Utility", icon: nil, isSystemOwned: false,
            isRunning: true, records: records, axItems: ax, isReadable: true)
        XCTAssertEqual(entries.map(\.displayName), ["Utility · Clock", "Utility · Focus"])
        XCTAssertTrue(entries.allSatisfy { $0.observedVisible == nil })
        XCTAssertFalse(entries.contains { $0.isPending })
    }

    @MainActor
    func testSearchMatchesOwnerAndTrimsWhitespace() {
        let model = StatusItemModel()
        let records = [StatusItemPreferences.Record(autosaveName: "main", isVisible: true, position: 0)]
        let entries = model.entries(bundleID: "test.bar", appName: "Rectangle", icon: nil, isSystemOwned: false, isRunning: false, records: records, axItems: [], isReadable: false)
        let searchable = StatusItemModel(entries: entries)
        searchable.searchText = "  rectangle  "
        XCTAssertEqual(searchable.filteredInactiveEntries.count, 1)
        searchable.searchText = "missing"
        XCTAssertTrue(searchable.filteredInactiveEntries.isEmpty)
    }
}

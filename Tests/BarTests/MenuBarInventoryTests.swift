import CoreGraphics
import XCTest
@testable import Bar

@MainActor
final class MenuBarInventoryTests: XCTestCase {
    private func item(x: CGFloat) -> MenuBarWindow {
        MenuBarWindow(id: 1, hostPID: 10, title: "", frame: CGRect(x: x, y: 0, width: 42, height: 33), isOnScreen: true)
    }

    func testReflowDiscardsOldAXLabelsAndRereadsAgainstStableGeometry() async {
        let before = [item(x: 100)]
        let after = [item(x: 130)]
        let probe = InventoryProbe(snapshots: [.success(before), .success(after), .success(after)])
        let result = await MenuBarInventoryReader.read(targets: [],
            windows: { await probe.windows() }, accessibility: { _ in await probe.accessibility() })
        guard case let .success(inventory) = result else { return XCTFail("Expected a stable second pass") }
        XCTAssertEqual(inventory.windows, after)
        XCTAssertEqual(inventory.accessibility["test.utility"]?.items.first?.name, "pass-2")
        let count = await probe.accessibilityReads
        XCTAssertEqual(count, 2)
    }

    func testContinuouslyChangingGeometryHasABoundedRetryAndPublishesNoMixedInventory() async {
        let probe = InventoryProbe(snapshots: [.success([item(x: 100)]), .success([item(x: 130)]), .success([item(x: 160)])])
        let result = await MenuBarInventoryReader.read(targets: [],
            windows: { await probe.windows() }, accessibility: { _ in await probe.accessibility() })
        guard case .failure(.layoutChanging) = result else { return XCTFail("A mixed snapshot must not be published") }
        let count = await probe.accessibilityReads
        XCTAssertEqual(count, 2)
    }

    func testUnavailableEnumerationIsNotReportedAsAnEmptyMenuBar() async {
        let probe = InventoryProbe(snapshots: [.failure(.unavailable)])
        let result = await MenuBarInventoryReader.read(targets: [],
            windows: { await probe.windows() }, accessibility: { _ in await probe.accessibility() })
        guard case .failure(.unavailable) = result else { return XCTFail("Preserve the enumeration failure") }
        let count = await probe.accessibilityReads
        XCTAssertEqual(count, 0)
    }
}

private actor InventoryProbe {
    let snapshots: [Result<[MenuBarWindow], MenuBarWindowError>]
    private var windowReads = 0
    private(set) var accessibilityReads = 0

    init(snapshots: [Result<[MenuBarWindow], MenuBarWindowError>]) { self.snapshots = snapshots }

    func windows() -> Result<[MenuBarWindow], MenuBarWindowError> {
        defer { windowReads += 1 }
        return snapshots[min(windowReads, snapshots.count - 1)]
    }

    func accessibility() -> [String: AXStatus] {
        accessibilityReads += 1
        return ["test.utility": AXStatus(items: [AXStatusItem(name: "pass-\(accessibilityReads)",
            frame: CGRect(x: 0, y: 0, width: 24, height: 24))], isReadable: true)]
    }
}

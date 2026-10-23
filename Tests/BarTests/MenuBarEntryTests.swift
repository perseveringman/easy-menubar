import Foundation
import XCTest
@testable import Bar

final class MenuBarEntryTests: XCTestCase {
    func testHiddenOrDisplacedEntryRecoversWithoutChangingManagedApplications() throws {
        let suite = "BarEntryTest." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let name = MenuBarEntryPreferences.name
        defaults.set(900, forKey: StatusItemPreferences.preferredPositionPrefix + name)
        defaults.set(false, forKey: StatusItemPreferences.visibleCCPrefix + name)
        let remembered = Data("user hidden records".utf8)
        defaults.set(remembered, forKey: "rememberedHiddenItems")
        defaults.set(false, forKey: StatusItemPreferences.visibleCCPrefix + "Item-0")

        MenuBarEntryPreferences.prepare(in: defaults)

        XCTAssertEqual(defaults.integer(forKey: StatusItemPreferences.preferredPositionPrefix + name), 0)
        XCTAssertTrue(defaults.bool(forKey: StatusItemPreferences.visibleCCPrefix + name))
        XCTAssertTrue(defaults.bool(forKey: StatusItemPreferences.visiblePrefix + name))
        XCTAssertEqual(defaults.data(forKey: "rememberedHiddenItems"), remembered)
        XCTAssertFalse(defaults.bool(forKey: StatusItemPreferences.visibleCCPrefix + "Item-0"))
    }
}

import XCTest
@testable import Strand

final class NativeMoreListTests: XCTestCase {

    func testPersonalMoreListOrder() {
        XCTAssertEqual(NativeMoreItem.titles, ["Strap", "Profile", "Data & Backup", "About"])
        XCTAssertEqual(NativeMoreItem.allCases.map(\.rawValue), ["strap", "profile", "dataBackup", "about"])
    }

    func testPersonalMoreListHidesAlarmAndNotifications() {
        let titles = NativeMoreItem.titles
        XCTAssertFalse(titles.contains("Alarm"))
        XCTAssertFalse(titles.contains("Alarms"))
        XCTAssertFalse(titles.contains("Notifications"))
        XCTAssertFalse(NativeMoreItem.allCases.map(\.icon).contains("alarm.fill"))
        XCTAssertFalse(NativeMoreItem.allCases.map(\.icon).contains("bell.badge.fill"))
    }
}

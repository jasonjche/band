import XCTest
@testable import Strand

final class NativeMoreListTests: XCTestCase {

    func testPersonalMoreListOrder() {
        XCTAssertEqual(
            NativeMoreItem.titles,
            ["Strap", "Data & Backup", "Profile", "Settings", "Notifications", "About"]
        )
        XCTAssertEqual(
            NativeMoreItem.allCases.map(\.rawValue),
            ["strap", "dataBackup", "profile", "settings", "notifications", "about"]
        )
        XCTAssertEqual(NativeMoreSection.allCases.flatMap(\.items), NativeMoreItem.allCases)
    }

    func testPersonalMoreListHidesAlarmAndMovedHealthItems() {
        let titles = NativeMoreItem.titles
        XCTAssertFalse(titles.contains("Alarm"))
        XCTAssertFalse(titles.contains("Alarms"))
        XCTAssertFalse(titles.contains("Trends"))
        XCTAssertFalse(titles.contains("Healthspan"))
        XCTAssertFalse(titles.contains("Sleep Planner"))
        XCTAssertFalse(titles.contains("Assessments"))
        XCTAssertFalse(titles.contains("Automations"))
        XCTAssertFalse(titles.contains("Test Centre"))
        XCTAssertFalse(NativeMoreItem.allCases.map(\.icon).contains("alarm.fill"))
        XCTAssertTrue(titles.contains("Notifications"))
        XCTAssertFalse(titles.contains("Journal"))  // Journal lives on Home
    }
}

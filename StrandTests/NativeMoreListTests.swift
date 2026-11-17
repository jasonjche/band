import XCTest
@testable import Strand

final class NativeMoreListTests: XCTestCase {

    func testPersonalMoreListOrder() {
        XCTAssertEqual(NativeMoreItem.titles, ["Healthspan", "Strap", "Profile", "Sleep Planner", "Assessments", "Data & Backup", "About"])
        XCTAssertEqual(NativeMoreItem.allCases.map(\.rawValue), ["healthspan", "strap", "profile", "sleepPlanner", "assessments", "dataBackup", "about"])
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

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

    func testSettingsBindsLegacyPreferenceKeys() {
        XCTAssertEqual(NativeMoreItem.settings.title, "Settings")
        XCTAssertEqual(
            NativeAppSettingsView.boundKeys,
            [
                UnitPrefs.systemKey,
                UnitPrefs.distanceSystemKey,
                UnitPrefs.temperatureKey,
                UnitPrefs.skinTempDisplayKey,
                UnitPrefs.effortScaleKey,
                NativeStyle.storageKey,
                ScreenIdle.strapSyncKeepAwakeKey,
            ]
        )
        XCTAssertEqual(UnitPrefs.systemKey, "units.system")
        XCTAssertEqual(UnitPrefs.distanceSystemKey, "units.distance")
        XCTAssertEqual(UnitPrefs.temperatureKey, "units.temperature")
        XCTAssertEqual(UnitPrefs.skinTempDisplayKey, "units.skinTempDisplay")
        XCTAssertEqual(UnitPrefs.effortScaleKey, "effort.scale")
        XCTAssertEqual(NativeStyle.storageKey, "noop.nativeStyle")
        XCTAssertEqual(ScreenIdle.strapSyncKeepAwakeKey, "syncKeepScreenOn")
    }
}

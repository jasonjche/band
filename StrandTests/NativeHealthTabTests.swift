import XCTest
import WhoopStore
@testable import Strand

final class NativeHealthTabTests: XCTestCase {

    func testTabTagsStayStable() {
        XCTAssertEqual(NativeRootTab.home.rawValue, 0)
        XCTAssertEqual(NativeRootTab.health.rawValue, 1)
        XCTAssertEqual(NativeRootTab.more.rawValue, 4)
        XCTAssertEqual(NativeRootTab.coachTag, 3)
        XCTAssertEqual(NativeRootTab.pathSlotCount, 5)
        XCTAssertEqual(NativeRootTab.ordered.map(\.rawValue), [0, 1, 4])
    }

    func testSwipeWalksHomeHealthMore() {
        XCTAssertEqual(NativeRootTab.next(from: 0, direction: 1), 1)
        XCTAssertEqual(NativeRootTab.next(from: 1, direction: 1), 4)
        XCTAssertEqual(NativeRootTab.next(from: 4, direction: 1), 4)
        XCTAssertEqual(NativeRootTab.next(from: 4, direction: -1), 1)
        XCTAssertEqual(NativeRootTab.next(from: 1, direction: -1), 0)
        XCTAssertEqual(NativeRootTab.next(from: 0, direction: -1), 0)
        XCTAssertEqual(NativeRootTab.next(from: 3, direction: 1), 3)
    }

    func testHealthIndexOrder() {
        XCTAssertEqual(
            NativeHealthItem.titles,
            ["Healthspan", "Trends", "Reports"]
        )
        XCTAssertEqual(NativeHealthItem.tabLinks, [.trends, .reports])  // Healthspan is the tab root
        XCTAssertEqual(NativeHealthItem.healthspan.icon, "sparkles")
        XCTAssertEqual(NativeHealthItem.trends.icon, "chart.xyaxis.line")
    }

    func testRowsShowTheirStaticSubtitle() {
        for item in NativeHealthItem.allCases {
            XCTAssertNil(NativeHealthTabLogic.liveSummary(for: item, days: [], todayKey: "2026-11-16"))
            XCTAssertFalse(item.subtitle.isEmpty)
        }
    }

    func testHealthTabLinksOmitRowSubtitles() {
        let src = try! String(contentsOfFile: NativeHealthTabTests.healthTabPath, encoding: .utf8)
        XCTAssertFalse(src.contains("subtitle: item.subtitle"))
        XCTAssertTrue(src.contains("NativeSettingsRow(title: item.title, icon: item.icon, color: item.color)"))
    }

    private static var healthTabPath: String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return root.appendingPathComponent("Strand/Native/NativeHealthTab.swift").path
    }

    private func sampleMetric(day: String, hrv: Double? = nil, rhr: Int? = nil,
                              resp: Double? = nil, spo2: Double? = nil, skin: Double? = nil) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: rhr, avgHrv: hrv, recovery: nil, strain: nil,
            exerciseCount: nil, spo2Pct: spo2, skinTempDevC: skin, respRateBpm: resp
        )
    }

    private func shift(_ key: String, _ days: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = formatter.date(from: key)!
        return formatter.string(from: calendar.date(byAdding: .day, value: days, to: date)!)
    }
}

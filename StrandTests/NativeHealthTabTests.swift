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
            ["Healthspan", "Health Monitor", "Stress Monitor", "Trends", "Reports"]
        )
        XCTAssertEqual(NativeHealthItem.healthspan.icon, "sparkles")
        XCTAssertEqual(NativeHealthItem.trends.icon, "chart.xyaxis.line")
    }

    func testHealthMonitorSummaryIsCheapAndMatchesHome() {
        XCTAssertNil(NativeHealthTabLogic.liveSummary(for: .healthMonitor, days: [], todayKey: "2026-11-16"))
        XCTAssertNil(NativeHealthTabLogic.liveSummary(for: .healthspan, days: [], todayKey: "2026-11-16"))

        var days: [DailyMetric] = []
        for offset in (1...20).reversed() {
            days.append(sampleMetric(day: shift("2026-11-16", -offset), hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5))
        }
        days.append(sampleMetric(day: "2026-11-16", hrv: 66, rhr: 51, resp: 14.7, spo2: 98, skin: 34.5))
        XCTAssertEqual(
            NativeHealthTabLogic.liveSummary(for: .healthMonitor, days: days, todayKey: "2026-11-16"),
            "Within Range"
        )
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

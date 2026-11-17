import XCTest
import WhoopStore
@testable import Strand

/// Home layout: WHOOP section order, one stress-level resolver, dashboard rows, journal glyphs.
@MainActor
final class NativeHomeLayoutTests: XCTestCase {

    func testHomeAndStressPageShareOneLevelResolver() {
        let samples = [(ts: 100, bpm: 48), (ts: 200, bpm: 86), (ts: 300, bpm: 124)]
        let hours = NativeHomeCharts.stressSeries(samples: samples, stride: 1)
        let key = "2026-11-12"
        let home = NativeStressResolver.level(hours: hours, days: [], todayKey: key)
        let page = NativeStressResolver.level(hours: hours, days: [], todayKey: key)
        XCTAssertEqual(home, page)
        XCTAssertEqual(home ?? -1, NativeHomeCharts.stressLevel(hours: hours, days: [], todayKey: key) ?? -1, accuracy: 0.01)
        XCTAssertEqual(home ?? -1, 2.0, accuracy: 0.01)

        let day = DailyMetric(
            day: key,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 62, avgHrv: 40, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let emptyHours: [NativeHourPoint] = []
        let homeFallback = NativeStressResolver.level(hours: emptyHours, days: [day], todayKey: key)
        let pageFallback = NativeStressResolver.level(hours: emptyHours, days: [day], todayKey: key)
        XCTAssertEqual(homeFallback, pageFallback)
        XCTAssertEqual(
            homeFallback ?? -1,
            NativeHomeCharts.stressLevel(hours: emptyHours, days: [day], todayKey: key) ?? -1,
            accuracy: 0.01
        )
        XCTAssertNotNil(homeFallback)
    }

    func testHomeSectionOrderMatchesWHOOP() {
        XCTAssertEqual(HomeSectionOrder.content, [
            "rings",
            "Health Monitor",
            "My Day",
            "Activities",
            "Tonight's Sleep",
            "Journal",
            "My Dashboard",
            "Stress Monitor",
            "Strain & Recovery",
        ])
    }

    func testJournalStripUsesCheckmarkInTintAndEmptyCircle() {
        XCTAssertEqual(HomeJournalGlyph.filled, "checkmark.circle.fill")
        XCTAssertEqual(HomeJournalGlyph.symbol(filled: true), "checkmark.circle.fill")
        XCTAssertNil(HomeJournalGlyph.symbol(filled: false), "empty days draw an empty circle, not a glyph")
        let dots = NativeHomeCharts.journalDots(
            filled: [true, false, true, false, true, true, false],
            todayKey: "2026-11-16"
        )
        XCTAssertEqual(dots.map(\.filled), [true, false, true, false, true, true, false])
        XCTAssertEqual(dots.count, 7)
    }

    func testDashboardRowsHideWhenThereIsNoValue() {
        let empty = DailyMetric(
            day: "2026-11-12",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let none = HomeMetricItem.make(
            dashboard: NativeDay.make(
                days: [empty], sleeps: [], workouts: [],
                todayKey: empty.day, connected: false, effortScale: .whoop
            ).dashboard,
            days: [empty],
            todayKey: empty.day
        )
        XCTAssertTrue(none.isEmpty)

        let scored = DailyMetric(
            day: "2026-11-12",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 51, avgHrv: 66, recovery: nil, strain: nil,
            exerciseCount: nil, steps: 1200, activeKcalEst: 400
        )
        let model = NativeDay.make(
            days: [scored], sleeps: [], workouts: [],
            todayKey: scored.day, connected: false, effortScale: .whoop
        )
        let rows = HomeMetricItem.make(
            dashboard: model.dashboard, days: [scored], todayKey: scored.day, vo2max: 48.2
        )
        XCTAssertEqual(rows.map(\.title), [
            "Heart Rate Variability",
            "Resting Heart Rate",
            "Steps",
            "VO₂ Max",
            "Calories",
        ])
        XCTAssertFalse(rows.contains { $0.title.contains("Zones") })
        XCTAssertFalse(rows.contains { $0.title.contains("Strength") })
    }
}

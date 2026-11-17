import XCTest
import WhoopStore
import StrandAnalytics
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
        XCTAssertEqual(
            home ?? -1,
            NativeHomeCharts.stressValue(bpm: 124, baselines: .fallback),
            accuracy: 0.01
        )

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
            "Steps",
            "VO₂ Max",
            "Calories",
        ])
        XCTAssertFalse(rows.contains { $0.title.contains("Heart Rate Variability") })
        XCTAssertFalse(rows.contains { $0.title.contains("Resting Heart Rate") })
        XCTAssertFalse(rows.contains { $0.title.contains("Respiratory") })
        XCTAssertFalse(rows.contains { $0.title.contains("Zones") })
        XCTAssertFalse(rows.contains { $0.title.contains("Strength") })
    }

    func testDefaultDashboardOmitsHealthMonitorMetricsUntilChosen() {
        XCTAssertFalse(HomeDashboardMetric.defaultIds.contains(where: HomeDashboardMetric.healthMonitorIds.contains))
        let scored = DailyMetric(
            day: "2026-11-12",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 51, avgHrv: 66, recovery: nil, strain: nil,
            exerciseCount: nil, respRateBpm: 14.2, steps: 1200, activeKcalEst: 400
        )
        let model = NativeDay.make(
            days: [scored], sleeps: [], workouts: [],
            todayKey: scored.day, connected: false, effortScale: .whoop
        )
        let chosen = HomeMetricItem.make(
            dashboard: model.dashboard, days: [scored], todayKey: scored.day,
            ids: ["hrv", "steps"]
        )
        XCTAssertEqual(chosen.map { $0.title }, ["Heart Rate Variability", "Steps"])
    }

    func testStressLevelIsLastSampleNotDayMean() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sleep = NativeHourPoint(time: start, value: NativeHomeCharts.stressValue(bpm: 52))
        let morning = NativeHourPoint(
            time: start.addingTimeInterval(8 * 3600),
            value: NativeHomeCharts.stressValue(bpm: 64)
        )
        let last = NativeHourPoint(
            time: start.addingTimeInterval(12 * 3600),
            value: NativeHomeCharts.stressValue(bpm: 124)
        )
        let hours = [sleep, morning, last]
        let mean = (sleep.value + morning.value + last.value) / 3
        let level = NativeHomeCharts.stressLevel(hours: hours, days: [], todayKey: "2023-11-14")
        XCTAssertEqual(level ?? -1, last.value, accuracy: 0.01)
        XCTAssertEqual(level ?? -1, NativeHomeCharts.stressValue(bpm: 124), accuracy: 0.01)
        XCTAssertGreaterThan(abs((level ?? 0) - mean), 0.5)
        XCTAssertEqual(
            NativeStressResolver.level(hours: hours, days: [], todayKey: "2023-11-14"),
            level
        )
    }

    func testStressSeriesOmitsGapsInsteadOfZeroFilling() {
        let t0 = 1_700_000_000
        let buckets = [
            HRBucket(ts: t0, bpm: 86, minBpm: 86, maxBpm: 86),
            HRBucket(ts: t0 + 7200, bpm: 124, minBpm: 124, maxBpm: 124),
        ]
        let hours = NativeHomeCharts.stressSeries(buckets: buckets)
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].value, NativeHomeCharts.stressValue(bpm: 86), accuracy: 0.01)
        XCTAssertEqual(hours[1].value, NativeHomeCharts.stressValue(bpm: 124), accuracy: 0.01)
        XCTAssertFalse(hours.contains { $0.value == 0 })
        XCTAssertEqual(
            NativeHomeCharts.stressLevel(hours: hours, days: [], todayKey: "2023-11-14") ?? -1,
            NativeHomeCharts.stressValue(bpm: 124),
            accuracy: 0.01
        )
    }

    func testEmptyHoursYieldNilNotZero() {
        XCTAssertNil(NativeHomeCharts.stressLevel(hours: [], days: [], todayKey: "2023-11-14"))
        XCTAssertTrue(NativeHomeCharts.stressSeries(buckets: []).isEmpty)
        XCTAssertTrue(NativeHomeCharts.stressSeries(samples: []).isEmpty)
        // Relative to fallback RHR 60, 12 bpm/band. Old pins were absolute (bpm-48)/38.
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 60), 0, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 72), 1, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 84), 2, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 96), 3, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 200), 3, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 48), 0, accuracy: 0.01)
    }

    func testWorkoutBucketsAreOmittedFromTheSeries() {
        let t0 = 1_700_000_000
        let buckets = [
            HRBucket(ts: t0, bpm: 72, minBpm: 72, maxBpm: 72),
            HRBucket(ts: t0 + 300, bpm: 150, minBpm: 150, maxBpm: 150),
            HRBucket(ts: t0 + 600, bpm: 72, minBpm: 72, maxBpm: 72),
        ]
        let start = Date(timeIntervalSince1970: TimeInterval(t0 + 300))
        let end = Date(timeIntervalSince1970: TimeInterval(t0 + 600))
        let hours = NativeHomeCharts.stressSeries(
            buckets: buckets,
            baselines: .fallback,
            workouts: [(start: start, end: end)]
        )
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours[0].time.timeIntervalSince1970, TimeInterval(t0), accuracy: 0.01)
        XCTAssertEqual(hours[1].time.timeIntervalSince1970, TimeInterval(t0 + 600), accuracy: 0.01)
        XCTAssertFalse(hours.contains { $0.value >= 2 })
        XCTAssertEqual(
            NativeHomeCharts.stressLevel(hours: hours, days: [], todayKey: "2023-11-14") ?? -1,
            NativeHomeCharts.stressValue(bpm: 72),
            accuracy: 0.01
        )
    }

    func testStressBaselinesPreferTodayThenRecentMedian() {
        let today = DailyMetric(
            day: "2023-11-14",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 58, avgHrv: 44, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let prior = DailyMetric(
            day: "2023-11-13",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 64, avgHrv: 50, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let withToday = NativeHomeCharts.stressBaselines(days: [prior, today], todayKey: today.day)
        XCTAssertEqual(withToday.wakeRestingHR, 58, accuracy: 0.01)
        XCTAssertEqual(withToday.sleepRestingHR, 58, accuracy: 0.01)
        XCTAssertEqual(withToday.rmssd ?? -1, 44, accuracy: 0.01)
        let withoutToday = NativeHomeCharts.stressBaselines(days: [prior], todayKey: today.day)
        XCTAssertEqual(withoutToday.wakeRestingHR, 64, accuracy: 0.01)
        let empty = NativeHomeCharts.stressBaselines(days: [], todayKey: today.day)
        XCTAssertEqual(empty.wakeRestingHR, BandStress.defaultRestingHR, accuracy: 0.01)
        XCTAssertNil(empty.rmssd)
    }

    func testTimeInHighDoesNotCountGapsAsHigh() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let consecutive: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 2.1),
            NativeHourPoint(time: t0.addingTimeInterval(300), value: 2.4),
            NativeHourPoint(time: t0.addingTimeInterval(600), value: 0.4),
        ]
        XCTAssertEqual(NativeStressHistory.timeInHighMinutes(consecutive) ?? -1, 10, accuracy: 0.01)

        let gapped: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 2.1),
            NativeHourPoint(time: t0.addingTimeInterval(3 * 3600), value: 0.4),
        ]
        XCTAssertNil(NativeStressHistory.timeInHighMinutes(gapped))
    }

    func testDateStepperChevronsFitBesideStrapOnIPhone15() {
        let strapBudget: CGFloat = 96
        XCTAssertEqual(HomeDateStepperLayout.chevronSize, 32, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            HomeDateStepperLayout.compactWidth + HomeDateStepperLayout.strapGutter + strapBudget,
            HomeDateStepperLayout.iphone15Width
        )
        XCTAssertEqual(NativeHomeLoadMetrics.publishedSnapshotsPerLoad, 1)
    }
}

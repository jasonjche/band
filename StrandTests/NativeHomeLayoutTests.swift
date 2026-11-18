import XCTest
import WhoopStore
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Home layout: WHOOP section order, one stress-level resolver, dashboard rows, journal glyphs.
@MainActor
final class NativeHomeLayoutTests: XCTestCase {

    func testDayAverageAndWeekBarShareMinuteSeriesMean() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let hours = [
            NativeHourPoint(time: start, value: 0.4),
            NativeHourPoint(time: start.addingTimeInterval(60), value: 0.6),
        ]
        let mean = 0.5
        let key = "2023-11-14"
        let day = DailyMetric(
            day: key,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 62, avgHrv: 40, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let average = NativeStressHistory.dayAverage(hours: hours, days: [day], dayKey: key)
        XCTAssertEqual(average ?? -1, mean, accuracy: 0.01)

        let fallback = NativeStressHistory.dayAverage(hours: [], days: [day], dayKey: key)
        XCTAssertEqual(fallback, NativeStressHistory.dailyScore(days: [day], dayKey: key))
        XCTAssertNotNil(fallback)
        XCTAssertGreaterThan(abs((fallback ?? 0) - mean), 0.05)

        let weekPoints = NativeStressHistory.daily(
            days: [day], ending: key, minuteMeans: [key: mean]
        )
        XCTAssertEqual(weekPoints.first?.value ?? -1, mean, accuracy: 0.01)
        XCTAssertEqual(weekPoints.first?.value, average)

        let fallbackPoints = NativeStressHistory.daily(days: [day], ending: key)
        XCTAssertEqual(fallbackPoints.first?.value, fallback)
    }

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
            "Stress Monitor",
            "My Day",
            "Activities",
            "Tonight's Sleep",
            "Journal",
            "My Dashboard",
            "Stress Monitor chart",
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

    func testDashboardRowsStayWhenThereIsNoValue() {
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
        XCTAssertEqual(none.map(\.title), HomeDashboardMetric.defaultIds.compactMap { id in
            HomeDashboardMetric(rawValue: id)?.title
        })
        XCTAssertTrue(none.allSatisfy { $0.value == HomeDashboardMetric.emptyValue })
        XCTAssertEqual(none.map(\.route), HomeDashboardMetric.defaultIds.compactMap { id in
            HomeDashboardMetric(rawValue: id)?.route
        })

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
            "Respiratory Rate",
            "Steps",
            "Heart Rate Zones 1–3",
            "Heart Rate Zones 4–5",
            "Strength Activity Time",
            "VO₂ Max",
            "Calories",
        ])
        XCTAssertEqual(rows.first { $0.title == "Heart Rate Variability" }?.value, "66")
        XCTAssertEqual(rows.first { $0.title == "Resting Heart Rate" }?.value, "51")
        XCTAssertEqual(rows.first { $0.title == "Respiratory Rate" }?.value, HomeDashboardMetric.emptyValue)
        XCTAssertEqual(rows.first { $0.title == "Steps" }?.value, NativeDayLogic.countText(1200))
        XCTAssertEqual(rows.first { $0.title == "Heart Rate Zones 1–3" }?.value, HomeDashboardMetric.emptyValue)
        XCTAssertEqual(rows.first { $0.title == "VO₂ Max" }?.value, "48.2")
        XCTAssertEqual(rows.first { $0.title == "Calories" }?.value, NativeDayLogic.countText(400))
    }

    func testDefaultDashboardIncludesHealthMonitorMetricsAndHonorsChosenIds() {
        XCTAssertTrue(HomeDashboardMetric.defaultIds.contains(where: HomeDashboardMetric.healthMonitorIds.contains))
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
        // Orthostatic wake floor: fallback RHR 60 + 10, 12 bpm/band.
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 60), 0, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 70), 0, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 82), 1, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 94), 2, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 106), 3, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 200), 3, accuracy: 0.01)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 48), 0, accuracy: 0.01)
    }

    func testWorkoutBucketsKeepTheLineRunning() {
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
        // WHOOP draws stress through a workout (high is expected) and labels the span.
        XCTAssertEqual(hours.count, 3)
        XCTAssertEqual(hours[1].time.timeIntervalSince1970, TimeInterval(t0 + 300), accuracy: 0.01)
        XCTAssertEqual(hours[1].value, NativeHomeCharts.stressValue(bpm: 150), accuracy: 0.01)
        XCTAssertEqual(hours[2].time.timeIntervalSince1970, TimeInterval(t0 + 600), accuracy: 0.01)
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
            NativeHourPoint(time: t0.addingTimeInterval(60), value: 2.4),
            NativeHourPoint(time: t0.addingTimeInterval(120), value: 0.4),
        ]
        XCTAssertEqual(NativeStressHistory.timeInHighMinutes(consecutive) ?? -1, 2, accuracy: 0.01)

        let gapped: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 2.1),
            NativeHourPoint(time: t0.addingTimeInterval(3 * 3600), value: 0.4),
        ]
        XCTAssertNil(NativeStressHistory.timeInHighMinutes(gapped))
    }

    func testStressBandDurationsSkipGapsLikeTimeInHigh() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let consecutive: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 0.4),
            NativeHourPoint(time: t0.addingTimeInterval(60), value: 1.4),
            NativeHourPoint(time: t0.addingTimeInterval(120), value: 2.4),
            NativeHourPoint(time: t0.addingTimeInterval(180), value: 2.1),
        ]
        let durations = NativeStressBandTime.durations(consecutive)
        XCTAssertEqual(durations.low, 60, accuracy: 0.01)
        XCTAssertEqual(durations.mid, 60, accuracy: 0.01)
        XCTAssertEqual(durations.high, 60, accuracy: 0.01)
        XCTAssertEqual(NativeStressHistory.timeInHighMinutes(consecutive) ?? -1, 1, accuracy: 0.01)

        let gapped: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 2.1),
            NativeHourPoint(time: t0.addingTimeInterval(3 * 3600), value: 0.4),
        ]
        XCTAssertEqual(NativeStressBandTime.durations(gapped).total, 0, accuracy: 0.01)
        XCTAssertEqual(NativeStressBandTime.clock(3660), "1:01")
    }

    func testStressTypicalPrefersSameWeekdayThenLastSevenDays() {
        let saturday = NativeStressBandDurations(low: 3600, mid: 13 * 3600, high: 7 * 3600)
        let other = NativeStressBandDurations(low: 10 * 3600, mid: 8 * 3600, high: 2 * 3600)
        let daily = [
            (weekday: 7, durations: saturday),
            (weekday: 1, durations: other),
            (weekday: 7, durations: NativeStressBandDurations(low: 1800, mid: 12 * 3600, high: 8 * 3600)),
            (weekday: 3, durations: other),
        ]
        let typical = NativeStressBandTime.typical(daily: daily, todayWeekday: 7)
        XCTAssertEqual(typical?.sameWeekday, true)
        XCTAssertEqual(typical?.durations.low ?? -1, 2700, accuracy: 0.01)

        let sparse = [
            (weekday: 2, durations: other),
            (weekday: 3, durations: other),
        ]
        let fallback = NativeStressBandTime.typical(daily: sparse, todayWeekday: 7)
        XCTAssertEqual(fallback?.sameWeekday, false)
        XCTAssertEqual(fallback?.durations.low ?? -1, other.low, accuracy: 0.01)

        XCTAssertEqual(
            NativeStressBandTime.deltaPercent(current: 3600, typical: 7200) ?? -1,
            -0.5,
            accuracy: 1e-9
        )
    }

    func testStressDrawBridgesFiveMinuteGapsAndDropsShortFragments() {
        XCTAssertEqual(NativeStressMonitorMath.drawConnectGap, 5 * 60, accuracy: 0.01)
        XCTAssertEqual(NativeStressMonitorMath.minDrawDuration, 5 * 60, accuracy: 0.01)

        let t0 = Date(timeIntervalSince1970: 0)
        func points(_ offsets: [Int], value: Double = 1) -> [NativeHourPoint] {
            offsets.map {
                NativeHourPoint(time: t0.addingTimeInterval(TimeInterval($0 * 60)), value: value)
            }
        }

        // 6 minutes of 1-minute samples: keep, one polyline, stored vertices only.
        let long = points(Array(0...6))
        let longSegments = NativeStressMonitorMath.segments(long)
        XCTAssertEqual(longSegments.count, 1)
        XCTAssertEqual(longSegments[0].map(\.time), long.map(\.time))

        // 4-minute scrap and a lone minute: display-only drop.
        XCTAssertTrue(NativeStressMonitorMath.segments(points(Array(0...4))).isEmpty)
        XCTAssertTrue(NativeStressMonitorMath.segments(points([0])).isEmpty)

        // Two samples 5 minutes apart: connect and keep (span == 5 min).
        let bridged = NativeStressMonitorMath.segments(points([0, 5, 6]))
        XCTAssertEqual(bridged.count, 1)
        XCTAssertEqual(bridged[0].count, 3)

        // 5 min + 1 s hole: two short fragments, neither drawn.
        let split: [NativeHourPoint] = [
            NativeHourPoint(time: t0, value: 1),
            NativeHourPoint(time: t0.addingTimeInterval(5 * 60 + 1), value: 1.2),
        ]
        XCTAssertTrue(NativeStressMonitorMath.segments(split).isEmpty)

        // Two 6-minute runs with a 6-minute hole: two polylines, nothing in the gap.
        let left = points(Array(0...6), value: 1)
        let right = points(Array(12...18), value: 2)
        let gapped = NativeStressMonitorMath.segments(left + right)
        XCTAssertEqual(gapped.count, 2)
        XCTAssertEqual(gapped[0].last?.time, left.last?.time)
        XCTAssertEqual(gapped[1].first?.time, right.first?.time)

        // Averages still see the short scrap that drawing dropped.
        let scrap = points(Array(0...2), value: 2.4)
        XCTAssertTrue(NativeStressMonitorMath.segments(scrap).isEmpty)
        XCTAssertEqual(NativeScopeSeries.mean(scrap.map(\.value)) ?? -1, 2.4, accuracy: 1e-9)
    }

    func testStressTimelineSmoothsMinuteScores() {
        let t0 = 1_700_000_000
        var buckets: [HRBucket] = []
        for i in 0..<11 {
            let bpm = i == 5 ? 96.0 : 60.0
            buckets.append(HRBucket(ts: t0 + i * 60, bpm: bpm, minBpm: bpm, maxBpm: bpm))
        }
        let hours = NativeHomeCharts.stressSeries(buckets: buckets)
        XCTAssertEqual(hours.count, 11)
        // 15-minute centred mean; the 11-minute run averages the spike over 11 minutes.
        let spike = NativeHomeCharts.stressValue(bpm: 96)
        XCTAssertEqual(hours[5].value, spike / 11, accuracy: 0.05)
        XCTAssertLessThan(hours[5].value, 1)
    }

    func testWakingSitReadsLowAndLightActivityReadsMedium() {
        let overnight = BandStress.Baselines(wakeRestingHR: 57, sleepRestingHR: 57, rmssd: nil)
        // Calm sitting +11…+18 above the 4 AM trough stays Low.
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 68, baselines: overnight), 1 / 12, accuracy: 0.02)
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 73, baselines: overnight), 6 / 12, accuracy: 0.02)
        XCTAssertLessThan(NativeHomeCharts.stressValue(bpm: 75, baselines: overnight), 1)
        // Standing / light everyday activity is Medium, not High.
        let stand = NativeHomeCharts.stressValue(bpm: 84, baselines: overnight)
        XCTAssertGreaterThan(stand, 1)
        XCTAssertLessThan(stand, 2)
        // High still needs a genuine non-locomotion lift (~+34 bpm over overnight RHR).
        XCTAssertEqual(NativeHomeCharts.stressValue(bpm: 91, baselines: overnight), 2, accuracy: 0.05)
        XCTAssertEqual(NativeHomeCharts.wakeOrthostaticBPM, 10, accuracy: 1e-9)
        XCTAssertEqual(NativeHomeCharts.sleepOrthostaticBPM, 5, accuracy: 1e-9)
    }

    func testWalkingBucketsHoldToPreWalkCalmAndDoNotBleed() {
        let t0 = 1_700_000_000
        let overnight = BandStress.Baselines(wakeRestingHR: 57, sleepRestingHR: 57, rmssd: nil)
        var buckets: [HRBucket] = []
        var activity: Set<Int> = []
        for i in 0..<40 {
            let ts = t0 + i * 60
            let walking = (15..<27).contains(i)
            let bpm = walking ? 105.0 : 70.0
            buckets.append(HRBucket(ts: ts, bpm: bpm, minBpm: bpm, maxBpm: bpm))
            if walking { activity.insert(ts) }
        }
        let hours = NativeHomeCharts.stressTimeline(
            buckets: buckets,
            baselines: overnight,
            activityBuckets: activity
        ).hours
        let sit = NativeHomeCharts.stressValue(bpm: 70, baselines: overnight)
        XCTAssertEqual(sit, 3 / 12, accuracy: 0.02)
        XCTAssertLessThan(sit, 1)
        // Unlogged walking at 105 bpm would have scored 3.0 and smeared into sitting.
        XCTAssertEqual(hours.count, 40)
        XCTAssertEqual(hours.map(\.value).max() ?? 9, sit, accuracy: 0.08)
        XCTAssertLessThan(hours[20].value, NativeHomeCharts.walkingStressCap)
        XCTAssertEqual(hours[8].value, sit, accuracy: 0.05)
        XCTAssertEqual(hours[32].value, sit, accuracy: 0.05)
    }

    func testStressTimelineMergesWalkingExclusionsAndKeepsTheLineThroughThem() {
        let t0 = 1_700_000_000
        let buckets = (0..<3).map {
            HRBucket(ts: t0 + $0 * 60, bpm: 80, minBpm: 80, maxBpm: 80)
        }
        let activity: Set<Int> = [t0, t0 + 60, t0 + 12 * 60]
        let timeline = NativeHomeCharts.stressTimeline(
            buckets: buckets,
            activityBuckets: activity
        )
        let walks = timeline.exclusions.filter { $0.kind == .activity }
        XCTAssertEqual(walks.count, 1)
        XCTAssertEqual(walks[0].startTs, t0)
        XCTAssertEqual(walks[0].endTs, t0 + 13 * 60)
        // WHOOP-style: the span is labelled, and the line still runs through it.
        XCTAssertEqual(timeline.hours.count, 3)
        XCTAssertEqual(timeline.hours[0].time.timeIntervalSince1970, TimeInterval(t0), accuracy: 0.01)
    }

    func testStressMonitorMergesActivitiesAndDownsamplesDraw() {
        let t0 = Date(timeIntervalSince1970: 0)
        let merged = NativeStressMonitorMath.mergeDateSpans([
            (start: t0, end: t0.addingTimeInterval(600)),
            (start: t0.addingTimeInterval(300), end: t0.addingTimeInterval(900)),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].start.timeIntervalSince1970, 0, accuracy: 0.01)
        XCTAssertEqual(merged[0].end.timeIntervalSince1970, 900, accuracy: 0.01)
        let points = (0..<1_440).map {
            NativeHourPoint(time: t0.addingTimeInterval(TimeInterval($0 * 60)), value: 1)
        }
        XCTAssertEqual(points.count, 1_440)
        XCTAssertEqual(
            NativeStressMonitorMath.drawPoints(points).count,
            NativeStressMonitorMath.drawBudget
        )
        XCTAssertEqual(NativeStressMonitorMath.drawPoints(Array(points.prefix(10))).count, 10)
    }

    func testStressMonitorLineStopsStayGreenThroughMedium() {
        XCTAssertEqual(
            NativeStressMonitorMath.lineStopValues,
            [0, 1.0, 1.2, 2.0, 2.4, 2.7, 3.0]
        )
        XCTAssertEqual(
            NativeStressMonitorMath.lineStops(style: .apple).map(\.value),
            NativeStressMonitorMath.lineStopValues
        )
        XCTAssertEqual(
            NativeStressMonitorMath.lineStops(style: .whoop).map(\.value),
            NativeStressMonitorMath.lineStopValues
        )
        XCTAssertEqual(NativeStressMonitorMath.yAxisValues, [0, 1, 2, 3])
        XCTAssertEqual(NativeStressMonitorMath.yLabel(0), "0.0")
        XCTAssertEqual(NativeStressMonitorMath.yLabel(1), "1.0")
        XCTAssertEqual(NativeStressMonitorMath.yLabel(2), "2.0")
        XCTAssertEqual(NativeStressMonitorMath.yLabel(3), "3.0")
        XCTAssertEqual(NativeHomeCharts.stressBand(1.2), "MEDIUM")
        XCTAssertEqual(NativeHomeCharts.stressBandWord(1.2), "Medium")
        let low = NativeStressMonitorMath.mappedLineStops(style: .apple, yMin: 0.2, yMax: 0.8)
        XCTAssertFalse(low.contains { abs($0.value - 3.0) < 0.01 })
        XCTAssertTrue(low.allSatisfy { $0.location >= 0 && $0.location <= 1 })
        XCTAssertGreaterThanOrEqual(low.count, 2)
    }

    func testStressSummariesDropWorkoutExclusions() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let hours = (0..<10).map {
            NativeHourPoint(time: t0.addingTimeInterval(TimeInterval($0 * 60)), value: $0 < 5 ? 0.4 : 2.4)
        }
        let exclusions = [
            BandStress.ExclusionSpan(
                startTs: Int(t0.timeIntervalSince1970) + 5 * 60,
                endTs: Int(t0.timeIntervalSince1970) + 10 * 60,
                kind: .workout
            )
        ]
        let summary = NativeStressHistory.excluding(hours, exclusions)
        XCTAssertEqual(summary.count, 5)
        XCTAssertNil(NativeStressHistory.timeInHighMinutes(summary))
        XCTAssertEqual(NativeStressBandTime.durations(summary).high, 0, accuracy: 0.01)
        XCTAssertGreaterThan(NativeStressBandTime.durations(hours).high, 0)
    }

    func testStressHeaderLastUpdatedPrefix() {
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            NativeStressMonitorMath.lastUpdated(time)?.hasPrefix("Last updated "),
            true
        )
        XCTAssertNil(NativeStressMonitorMath.lastUpdated(nil))
    }

    func testStressIconClustersCollapseOverlapIntoCount() {
        let start = Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(24 * 3600)
        let activities: [(start: Date, end: Date, symbol: String)] = [
            (
                start.addingTimeInterval(8 * 3600),
                start.addingTimeInterval(8.5 * 3600),
                "figure.run"
            ),
            (
                start.addingTimeInterval(8.3 * 3600),
                start.addingTimeInterval(8.8 * 3600),
                "figure.walk"
            ),
            (
                start.addingTimeInterval(16 * 3600),
                start.addingTimeInterval(17 * 3600),
                "figure.outdoor.cycle"
            ),
        ]
        let clusters = NativeStressMonitorMath.iconClusters(
            activities: activities, plotStart: start, plotEnd: end
        )
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].count, 2)
        XCTAssertEqual(clusters[1].count, 1)
        XCTAssertEqual(clusters[1].symbol, "figure.outdoor.cycle")
        XCTAssertEqual(
            NativeStressMonitorMath.activities(
                workouts: [(start: start, end: start.addingTimeInterval(600))],
                symbols: ["figure.run"]
            ).first?.symbol,
            "figure.run"
        )
    }

    func testStressNowMarkerSitsAtPlotEndOnToday() {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let dayStart = Calendar.current.startOfDay(for: day)
        let now = dayStart.addingTimeInterval(21 * 3600)
        XCTAssertTrue(NativeStressMonitorMath.showsNow(dayStart: dayStart, now: now))
        XCTAssertEqual(
            NativeStressMonitorMath.plotEnd(dayStart: dayStart, now: now).timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.01
        )
        let marks = NativeStressMonitorMath.xAxisDates(dayStart: dayStart, plotEnd: now)
        XCTAssertEqual(marks.count, 4)
        XCTAssertEqual(marks.last?.timeIntervalSince1970 ?? -1, now.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertTrue(NativeStressMonitorMath.isNow(now, now: now))
        let past = dayStart.addingTimeInterval(-2 * 86_400)
        XCTAssertFalse(NativeStressMonitorMath.showsNow(dayStart: past, now: now))
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? now
        XCTAssertFalse(NativeStressMonitorMath.showsNow(dayStart: dayStart, now: dayEnd))
    }

    func testDateStepperChevronsFitBesideStrapOnIPhone15() {
        let strapBudget: CGFloat = 96
        XCTAssertEqual(HomeDateStepperLayout.chevronSize, 44, accuracy: 0.5)
        XCTAssertEqual(HomeDateStepperLayout.hitHeight, 44, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            HomeDateStepperLayout.streakWidth
                + HomeDateStepperLayout.strapGutter
                + HomeDateStepperLayout.compactWidth
                + HomeDateStepperLayout.strapGutter
                + strapBudget,
            HomeDateStepperLayout.iphone15Width
        )
        XCTAssertEqual(NativeHomeLoadMetrics.publishedSnapshotsPerLoad, 1)
    }

    func testPullToRefreshHoldsTheSpinnerWhenAlreadyCaughtUp() {
        XCTAssertEqual(NativeHomeSync.minimumVisible, 0.6, accuracy: 1e-9)
        let now = Date(timeIntervalSince1970: 1_700_000_600)
        XCTAssertEqual(
            NativeHomeSync.remainingHold(
                since: Date(timeIntervalSince1970: 1_700_000_000),
                now: now
            ),
            0,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            NativeHomeSync.remainingHold(
                since: Date(timeIntervalSince1970: 1_700_000_599.7),
                now: now
            ),
            0.3,
            accuracy: 1e-4
        )
    }

    func testStrapStatusShowsSyncingWhilePullingOrBackfilling() {
        XCTAssertEqual(
            HomeStrapStatusLogic.mode(isPullRefreshing: true, backfilling: false, showSynced: false),
            .syncing
        )
        XCTAssertEqual(
            HomeStrapStatusLogic.mode(isPullRefreshing: false, backfilling: true, showSynced: true),
            .syncing
        )
        XCTAssertEqual(
            HomeStrapStatusLogic.mode(isPullRefreshing: false, backfilling: false, showSynced: true),
            .synced
        )
        XCTAssertEqual(
            HomeStrapStatusLogic.mode(isPullRefreshing: false, backfilling: false, showSynced: false),
            .idle
        )
        XCTAssertEqual(HomeStrapStatusLogic.syncedHold, 1.2, accuracy: 1e-9)
    }

    func testStressLaneIconsSitAboveThePlot() {
        XCTAssertEqual(NativeStressLaneIcon.iconLane, 24, accuracy: 0.5)
        XCTAssertEqual(NativeStressLaneIcon.iconOffsetY, 12, accuracy: 0.5)
        XCTAssertEqual(NativeStressLaneIcon.iconCenterY(plotMinY: 0), -12, accuracy: 0.5)
        XCTAssertEqual(NativeStressLaneIcon.iconCenterY(plotMinY: 24), 12, accuracy: 0.5)
        XCTAssertLessThan(NativeStressLaneIcon.iconCenterY(plotMinY: 0), 0)
        XCTAssertLessThan(NativeStressLaneIcon.iconCenterY(plotMinY: 24), 24)
    }

    func testCalendarCellsPadToSixWeeksAndHonorFirstWeekday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        let month = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let sunday = HomeCalendarMath.cells(month: month, calendar: calendar)
        XCTAssertEqual(sunday.count, HomeCalendarMath.cellsPerMonth)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(sunday[0])), 1)
        XCTAssertEqual(HomeCalendarMath.weekdaySymbols(calendar: calendar).first, "S")

        calendar.firstWeekday = 2
        let monday = HomeCalendarMath.cells(month: month, calendar: calendar)
        XCTAssertNil(monday[0])
        XCTAssertEqual(monday.compactMap { $0 }.count, 30)
        XCTAssertEqual(HomeCalendarMath.weekdaySymbols(calendar: calendar).first, "M")
    }

    func testCalendarPagingAndFutureDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let first = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let range = first...today
        let november = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        XCTAssertTrue(HomeCalendarMath.canPage(from: november, delta: -1, range: range, calendar: calendar))
        XCTAssertFalse(HomeCalendarMath.canPage(from: november, delta: 1, range: range, calendar: calendar))
        XCTAssertTrue(HomeCalendarMath.isEnabled(today, range: range, calendar: calendar))
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        XCTAssertFalse(HomeCalendarMath.isEnabled(tomorrow, range: range, calendar: calendar))
        XCTAssertEqual(HomeCalendarSheetLayout.rows, 6)
        XCTAssertEqual(
            HomeCalendarSheetLayout.compactHeight,
            NoopMetrics.space4 + HomeCalendarSheetLayout.actions + NoopMetrics.space2
                + HomeCalendarSheetLayout.header
                + HomeCalendarSheetLayout.weekdayRow + HomeCalendarSheetLayout.gridHeight
                + NoopMetrics.space4,
            accuracy: 0.5
        )
    }

    func testCalendarRecoveryMatchesHomeRingScoresAndWHOOPBands() {
        XCTAssertEqual(NativeChrome.recoveryBandIndex(0), 0)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(33), 0)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(34), 1)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(66), 1)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(67), 2)
        XCTAssertEqual(NativeChrome.recoveryBandIndex(100), 2)

        let day = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 51, avgHrv: 66, recovery: 37, strain: nil,
            exerciseCount: nil
        )
        let scores = NativeBandScores.resolve(days: [day], sleeps: [], workouts: [], importedSleep: [:])
        let map = HomeCalendarRecovery.values(days: [day], sleeps: [], workouts: [], importedSleep: [:])
        XCTAssertEqual(map[day.day], scores.byDay[day.day]?.recovery)
        let model = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: day.day, connected: false, effortScale: .whoop
        )
        if let recovery = scores.byDay[day.day]?.recovery {
            XCTAssertEqual(model.recovery.value, NativeScoreMath.percent(recovery))
        }
    }

    func testLiveTodayStrainFillsWeekChartInsteadOfZeroCliff() {
        let today = "2026-11-18"
        let now = localDate(year: 2026, month: 11, day: 18, hour: 9, minute: 51)
        let prior = DailyMetric(
            day: "2026-11-17",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 51, avgHrv: 66, recovery: 49, strain: 40,
            exerciseCount: nil, steps: 8_000, activeKcalEst: 2_000
        )
        let todayDay = DailyMetric(
            day: today,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 52, avgHrv: 60, recovery: nil, strain: 0,
            exerciseCount: nil, steps: 2_000, activeKcalEst: 400
        )
        let snapshot = NativeHomeRebuild.run(NativeHomeRebuild.Input(
            days: [prior, todayDay], sleeps: [], importedSleep: [:],
            workouts: [], journalEntries: [], vo2max: nil,
            sampleHours: [], liveTodayStrain: 22,
            selectedKey: today, selectedDay: now,
            effortScale: .whoop, smartAlarmEnabled: false, smartAlarmMinutes: 7 * 60,
            dashboardJSON: "", temperature: .celsius, stressExtraExclusions: [],
            now: now
        ))
        let todayPoint = snapshot.weekStrain.first { $0.key == today }
        XCTAssertEqual(
            todayPoint?.value ?? -1,
            NativeDayLogic.strainDisplayValue(22, scale: .whoop),
            accuracy: 1e-9
        )
        XCTAssertEqual(snapshot.dayModel.strain.value, NativeDayLogic.strainText(22, scale: .whoop))
    }

    func testMissingTodayStrainIsOmittedNotZero() {
        let today = "2026-11-18"
        let now = localDate(year: 2026, month: 11, day: 18, hour: 9, minute: 51)
        let todayDay = DailyMetric(
            day: today,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 52, avgHrv: 60, recovery: nil, strain: nil,
            exerciseCount: nil, steps: 2_000, activeKcalEst: 400
        )
        let snapshot = NativeHomeRebuild.run(NativeHomeRebuild.Input(
            days: [todayDay], sleeps: [], importedSleep: [:],
            workouts: [], journalEntries: [], vo2max: nil,
            sampleHours: [], liveTodayStrain: nil,
            selectedKey: today, selectedDay: now,
            effortScale: .whoop, smartAlarmEnabled: false, smartAlarmMinutes: 7 * 60,
            dashboardJSON: "", temperature: .celsius, stressExtraExclusions: [],
            now: now
        ))
        let todayPoint = snapshot.weekStrain.first { $0.key == today }
        XCTAssertFalse(todayPoint?.value.isFinite ?? true)
    }

    func testUnfinishedTodayCaloriesDoNotShowDownArrow() {
        let today = "2026-11-18"
        let now = localDate(year: 2026, month: 11, day: 18, hour: 9, minute: 51)
        let prior = (8...17).map { day in
            DailyMetric(
                day: String(format: "2026-11-%02d", day),
                totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                disturbances: nil, restingHr: 51, avgHrv: 66, recovery: nil, strain: 40,
                exerciseCount: nil, steps: 8_000, activeKcalEst: 2_000
            )
        }
        let todayDay = DailyMetric(
            day: today,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 52, avgHrv: 60, recovery: nil, strain: nil,
            exerciseCount: nil, steps: 2_000, activeKcalEst: 400
        )
        let viewing = NativeDay.make(
            days: prior + [todayDay], sleeps: [], workouts: [],
            todayKey: today, connected: false, effortScale: .whoop, now: now
        )
        XCTAssertEqual(viewing.dashboard.first { $0.title == "Calories" }?.delta, NativeScore.Delta.none)
        XCTAssertEqual(viewing.dashboard.first { $0.title == "Steps" }?.delta, NativeScore.Delta.none)

        let above = DailyMetric(
            day: today,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 52, avgHrv: 60, recovery: nil, strain: nil,
            exerciseCount: nil, steps: 12_000, activeKcalEst: 3_000
        )
        let ahead = NativeDay.make(
            days: prior + [above], sleeps: [], workouts: [],
            todayKey: today, connected: false, effortScale: .whoop, now: now
        )
        XCTAssertEqual(ahead.dashboard.first { $0.title == "Calories" }?.delta, NativeScore.Delta.up)

        let completed = DailyMetric(
            day: "2026-11-17",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: 51, avgHrv: 66, recovery: nil, strain: 40,
            exerciseCount: nil, steps: 2_000, activeKcalEst: 400
        )
        let past = NativeDay.make(
            days: prior.filter { $0.day != completed.day } + [completed], sleeps: [], workouts: [],
            todayKey: completed.day, connected: false, effortScale: .whoop, now: now
        )
        XCTAssertEqual(past.dashboard.first { $0.title == "Calories" }?.delta, NativeScore.Delta.down)
        XCTAssertEqual(past.strain.rows.first { $0.title == "Steps" }?.delta, NativeScore.Delta.down)
    }

    func testScreenAddsiOSTabBarScrollClearance() {
        #if os(iOS)
        XCTAssertEqual(NativeChrome.screenScrollBottomExtra, 48)
        #else
        XCTAssertEqual(NativeChrome.screenScrollBottomExtra, 0)
        #endif
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

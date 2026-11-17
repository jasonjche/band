import XCTest
import WhoopStore
import StrandAnalytics
import StrandDesign
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
        XCTAssertEqual(NativeStressMonitorMath.segments(consecutivePoints()).count, 1)
        XCTAssertEqual(NativeStressMonitorMath.segments(gappedPoints()).count, 2)
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
        XCTAssertEqual(hours[5].value, 0.6, accuracy: 0.05)
        XCTAssertLessThan(hours[5].value, 1)
    }

    func testStressTimelineMergesWalkingExclusionsWithoutDrawingThemAsHours() {
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
        XCTAssertEqual(timeline.hours.count, 1)
        XCTAssertEqual(timeline.hours[0].time.timeIntervalSince1970, TimeInterval(t0 + 120), accuracy: 0.01)
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

    private func consecutivePoints() -> [NativeHourPoint] {
        let t0 = Date(timeIntervalSince1970: 0)
        return [
            NativeHourPoint(time: t0, value: 1),
            NativeHourPoint(time: t0.addingTimeInterval(60), value: 1.2),
        ]
    }

    private func gappedPoints() -> [NativeHourPoint] {
        let t0 = Date(timeIntervalSince1970: 0)
        return [
            NativeHourPoint(time: t0, value: 1),
            NativeHourPoint(time: t0.addingTimeInterval(3600), value: 1.2),
        ]
    }

    func testDateStepperChevronsFitBesideStrapOnIPhone15() {
        let strapBudget: CGFloat = 96
        XCTAssertEqual(HomeDateStepperLayout.chevronSize, 32, accuracy: 0.5)
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
            NoopMetrics.space4 + HomeCalendarSheetLayout.header + NoopMetrics.space2
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
}

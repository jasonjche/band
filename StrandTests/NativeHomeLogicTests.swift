import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class NativeHomeLogicTests: XCTestCase {

    private func workout(
        start: Int, duration: Int, source: String, sport: String = "Running"
    ) -> WorkoutRow {
        WorkoutRow(
            startTs: start, endTs: start + duration, sport: sport, source: source,
            durationS: Double(duration), energyKcal: nil, avgHr: nil, maxHr: nil, strain: 8,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }

    func testDedupePrefersManualThenDetectedThenImported() {
        let start = 1_700_000_000
        let imported = workout(start: start, duration: 3_600, source: "whoop")
        let detected = workout(start: start + 60, duration: 3_600, source: "my-whoop-noop")
        let manual = workout(start: start + 120, duration: 3_600, source: "manual")
        let kept = HomeActivityDedupe.collapse([imported, detected, manual])
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.source, "manual")

        let withoutManual = HomeActivityDedupe.collapse([imported, detected])
        XCTAssertEqual(withoutManual.count, 1)
        XCTAssertEqual(withoutManual.first?.source, "my-whoop-noop")
    }

    func testDedupeKeepsSessionsThatBarelyTouch() {
        let start = 1_700_000_000
        let first = workout(start: start, duration: 3_600, source: "whoop")
        let second = workout(start: start + 3_000, duration: 3_600, source: "manual")
        // overlap 600s vs shorter 3600s = 16% — keep both
        let kept = HomeActivityDedupe.collapse([first, second])
        XCTAssertEqual(kept.count, 2)
    }

    func testDedupeDoesNotRemoveRowsFromTheStoreListWhenUsedForHomeCount() {
        let todayKey = "2026-11-12"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Int(formatter.date(from: todayKey)!.timeIntervalSince1970) + 10 * 3600
        let day = DailyMetric(
            day: todayKey,
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: 12,
            exerciseCount: 2
        )
        let imported = workout(start: start, duration: 3_600, source: "whoop")
        let strap = workout(start: start + 30, duration: 3_600, source: "my-whoop-noop")
        let model = NativeDay.make(
            days: [day], sleeps: [], workouts: [imported, strap],
            todayKey: todayKey,
            connected: false, effortScale: .whoop
        )
        XCTAssertEqual(model.activities.count, 1, "Home lists one overlapping session")
        XCTAssertEqual([imported, strap].count, 2, "store rows stay")
    }

    func testSleepStreakEndsAtSelectedDayAndKeepsZero() {
        let today = "2026-11-16"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        func session(on key: String) -> CachedSleepSession {
            let day = formatter.date(from: key)!
            let end = Int(day.timeIntervalSince1970) + 12 * 3600
            return CachedSleepSession(
                startTs: end - 8 * 3600, endTs: end,
                efficiency: 0.9, restingHr: 52, avgHrv: 60, stagesJSON: nil
            )
        }
        XCTAssertEqual(
            HomeSleepStreak.days(sleeps: [], imported: [:], todayKey: today),
            0
        )
        XCTAssertEqual(
            HomeSleepStreak.days(sleeps: [session(on: today)], imported: [:], todayKey: today),
            1
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-16"), session(on: "2026-11-15"), session(on: "2026-11-14")],
                imported: [:],
                todayKey: today
            ),
            3
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-15"), session(on: "2026-11-14")],
                imported: [:],
                todayKey: today
            ),
            2,
            "tonight not yet recorded must not zero a live streak"
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-13")],
                imported: [:],
                todayKey: today
            ),
            0
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-14"), session(on: "2026-11-15")],
                imported: [:],
                todayKey: "2026-11-15",
                viewingToday: false
            ),
            2
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-14")],
                imported: [:],
                todayKey: "2026-11-15",
                viewingToday: false
            ),
            0,
            "a past day with no night does not borrow the previous night"
        )
        let imported: [String: ImportedSleepFigures] = [
            "2026-11-16": ImportedSleepFigures(performancePct: 80, consistencyPct: nil, needMin: 480, debtMin: nil),
            "2026-11-15": ImportedSleepFigures(performancePct: 72, consistencyPct: nil, needMin: 480, debtMin: nil),
        ]
        XCTAssertEqual(HomeSleepStreak.days(sleeps: [], imported: imported, todayKey: today), 2)
    }

    func testDashboardStorePersistsEnabledIdsInOrder() {
        let suite = "native.home.dashboard.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HomeDashboardStore.decode(nil), HomeDashboardMetric.defaultIds)
        XCTAssertEqual(HomeDashboardMetric.defaultIds, [
            "hrv", "resting_hr", "respiratory", "steps",
            "hr_zones_13", "hr_zones_45", "strength", "vo2max", "calories",
        ])
        XCTAssertTrue(HomeDashboardMetric.healthMonitorIds.isSubset(of: Set(HomeDashboardMetric.defaultIds)))
        let ids = ["steps", "hrv", "calories"]
        HomeDashboardStore.save(ids, to: defaults)
        XCTAssertEqual(HomeDashboardStore.load(defaults), ids)
        XCTAssertEqual(HomeDashboardStore.decode("not-json"), HomeDashboardMetric.defaultIds)
        XCTAssertEqual(HomeDashboardStore.decode("[\"unknown\"]"), HomeDashboardMetric.defaultIds)
        XCTAssertEqual(HomeDashboardStore.decode("[\"hrv\",\"bogus\",\"steps\"]"), ["hrv", "steps"])
    }

    func testActivityPillGeometryIsShared() {
        XCTAssertEqual(HomeActivityLayout.pillWidth, 92)
        XCTAssertEqual(HomeActivityLayout.iconWidth, HomeActivityLayout.dashboardIconWidth)
        XCTAssertEqual(HomeActivityLayout.paddingH, 10)
    }

    func testTonightAlarmLabelWhenArmed() {
        let armed = NativeTonightSleep.make(needMin: 480, alarmEnabled: true, alarmMinutes: 7 * 60)
        XCTAssertEqual(armed?.alarmArmed, true)
        XCTAssertEqual(armed?.alarmLabel, "Alarm 7:00 AM")
        let off = NativeTonightSleep.make(needMin: 480, alarmEnabled: false, alarmMinutes: 7 * 60)
        XCTAssertEqual(off?.alarmArmed, false)
        XCTAssertNil(off?.alarmLabel)
    }

    func testVo2MaxRouteIsMeasuredAppleHealth() {
        XCTAssertEqual(HomeDashboardMetric.vo2max.route, .metric("vo2max"))
        XCTAssertEqual(HomeDashboardMetric.vo2max.unit, "ml/kg·min")
        XCTAssertEqual(NativeVo2Max.sourceLabel, "From Apple Health")
    }

    func testVo2MaxUsesLatestAppleReadingAndHidesEstimates() {
        func row(_ day: String, vo2: Double?) -> AppleDaily {
            AppleDaily(day: day, steps: nil, activeKcal: nil, basalKcal: nil, vo2max: vo2,
                       avgHr: nil, maxHr: nil, walkingHr: nil, weightKg: nil)
        }
        XCTAssertNil(NativeVo2Max.latest([]))
        XCTAssertNil(NativeVo2Max.latest([row("2026-11-17", vo2: nil), row("2026-11-16", vo2: 0)]))
        let reading = NativeVo2Max.latest([
            row("2026-11-15", vo2: 48.2),
            row("2026-11-16", vo2: nil),
            row("2026-11-17", vo2: 49.1),
        ])
        XCTAssertEqual(reading?.day, "2026-11-17")
        XCTAssertEqual(reading?.value ?? -1, 49.1, accuracy: 0.001)
        XCTAssertEqual(NativeVo2Max.points([row("2026-11-15", vo2: 48.2), row("2026-11-16", vo2: nil)]).map(\.key),
                       ["2026-11-15"])
    }

    func testStepHoursPreferAppleWhenAppleIsTheLargerDay() {
        XCTAssertTrue(NativeResolvedSteps.preferAppleHours(appleSum: 4_000, appleDaily: 8_202, mergedDaily: 8_202))
        XCTAssertFalse(NativeResolvedSteps.preferAppleHours(appleSum: 40, appleDaily: 40, mergedDaily: 9_000))
        XCTAssertFalse(NativeResolvedSteps.preferAppleHours(appleSum: 0, appleDaily: nil, mergedDaily: 99))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let ts = Int(start.timeIntervalSince1970) + 8 * 3600
        let points = NativeResolvedSteps.hourPoints(
            appleHours: [(ts: ts, steps: 1_200)],
            dayStart: start,
            calendar: calendar,
            preferApple: true
        )
        XCTAssertEqual(points.count, 24)
        XCTAssertEqual(points[8].value, 1_200, accuracy: 0.1)
        XCTAssertEqual(points.filter { $0.value == 0 }.count, 23)
        let empty = NativeResolvedSteps.hourPoints(
            appleHours: [(ts: ts, steps: 1_200)],
            dayStart: start,
            calendar: calendar,
            preferApple: false
        )
        XCTAssertEqual(empty.count, 24)
        XCTAssertTrue(empty.allSatisfy { $0.value == 0 })
    }

    func testChosenDashboardMetricWithNoValueStillShowsDash() {
        let empty = DailyMetric(
            day: "2026-11-12",
            totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
            disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil,
            exerciseCount: nil
        )
        let rows = HomeMetricItem.make(
            dashboard: NativeDay.make(
                days: [empty], sleeps: [], workouts: [],
                todayKey: empty.day, connected: false, effortScale: .whoop
            ).dashboard,
            days: [empty],
            todayKey: empty.day,
            ids: ["hrv", "steps", "calories"]
        )
        XCTAssertEqual(rows.map(\.title), ["Heart Rate Variability", "Steps", "Calories"])
        XCTAssertTrue(rows.allSatisfy { $0.value == HomeDashboardMetric.emptyValue })
        XCTAssertEqual(rows.map(\.route), [
            HomeDashboardMetric.hrv.route,
            HomeDashboardMetric.steps.route,
            HomeDashboardMetric.calories.route,
        ])
    }

    func testStressMonitorTileUsesSameBandAndClockAsTheChartCard() {
        let empty = HomeMonitorTile.stress(level: nil, at: nil)
        XCTAssertNil(empty.value)
        XCTAssertEqual(empty.accessibility, "No Data")

        let time = Date(timeIntervalSince1970: 1_763_409_000)
        let tile = HomeMonitorTile.stress(level: 1.5, at: time)
        XCTAssertEqual(tile.value, "1.5")
        XCTAssertEqual(tile.band, NativeHomeCharts.stressBandWord(1.5))
        XCTAssertEqual(tile.band, "Medium")
        XCTAssertEqual(tile.time, NativeScopeFormat.time(time))
        XCTAssertTrue(tile.accessibility.contains("1.5"))
        XCTAssertTrue(tile.accessibility.contains("Medium"))
    }

    func testStressWindowNowDoesNotCrossMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let noon = start.addingTimeInterval(12 * 3600)
        let nextMorning = start.addingTimeInterval(26 * 3600)
        XCTAssertEqual(HomeStressWindow.dayStart(for: noon, calendar: calendar), start)
        XCTAssertEqual(HomeStressWindow.now(dayStart: start, calendar: calendar, clock: noon), noon)
        XCTAssertEqual(
            HomeStressWindow.now(dayStart: start, calendar: calendar, clock: nextMorning),
            start.addingTimeInterval(24 * 3600)
        )
    }

    func testActivityItemsAreEquatableAndSortedByStart() {
        let start = 1_700_000_000
        let late = workout(start: start + 3_600, duration: 1_800, source: "manual", sport: "Run")
        let early = workout(start: start, duration: 1_800, source: "manual", sport: "Walk")
        let model = NativeDay.make(
            days: [], sleeps: [], workouts: [late, early],
            todayKey: Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(start))),
            connected: false, effortScale: .whoop
        )
        let items = HomeActivityItem.make(from: model)
        XCTAssertEqual(items.map(\.startTs), [start, start + 3_600])
        XCTAssertEqual(items, HomeActivityItem.make(from: model))
    }
}

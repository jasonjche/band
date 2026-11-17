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

    func testSleepStreakEndsTodayOrYesterdayAndHidesUnderTwo() {
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
            2
        )
        XCTAssertEqual(
            HomeSleepStreak.days(
                sleeps: [session(on: "2026-11-13")],
                imported: [:],
                todayKey: today
            ),
            0
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
        XCTAssertFalse(HomeDashboardMetric.defaultIds.contains("hrv"))
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

    func testChosenDashboardMetricWithNoValueIsHidden() {
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
        XCTAssertTrue(rows.isEmpty)
    }
}

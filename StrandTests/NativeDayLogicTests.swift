import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

/// Pins the Native shell data-correctness funnel: selected day, strain scale, sleep day key, journal ticks.
@MainActor
final class NativeDayLogicTests: XCTestCase {

    func testDefaultSelectionEqualsLogicalTodayAt0330And1000() {
        let at0330 = localDate(year: 2026, month: 11, day: 16, hour: 3, minute: 30)
        let at1000 = localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)

        XCTAssertEqual(NativeDayLogic.resolvedDayKey(stored: "", now: at0330), Repository.logicalDayKey(at0330))
        XCTAssertEqual(NativeDayLogic.resolvedDayKey(stored: "", now: at1000), Repository.logicalDayKey(at1000))
        XCTAssertNotEqual(Repository.logicalDayKey(at0330), Repository.logicalDayKey(at1000),
                          "03:30 and 10:00 must sit on opposite sides of the 04:00 rollover")

        let startOfCalendarDay = Calendar.current.startOfDay(for: at1000)
        XCTAssertNotEqual(
            Repository.logicalDayKey(startOfCalendarDay),
            NativeDayLogic.resolvedDayKey(stored: "", now: at1000),
            "startOfDay then logicalDayKey is the empty-key bug; the resolver must skip that path"
        )
    }

    func testSteppedSelectionExpiresOnTheNextLogicalDay() {
        let monday = localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        let tuesday = localDate(year: 2026, month: 11, day: 17, hour: 10, minute: 0)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: monday))!
        let launch = "test-launch"

        let stored = NativeDayLogic.persistSteppedDay(yesterday, now: monday, launchId: launch)
        XCTAssertEqual(
            NativeDayLogic.resolvedDayKey(stored: stored, now: monday, launchId: launch),
            Repository.localDayKey(yesterday)
        )
        XCTAssertEqual(
            NativeDayLogic.resolvedDayKey(stored: stored, now: tuesday, launchId: launch),
            Repository.logicalDayKey(tuesday)
        )
        XCTAssertEqual(
            NativeDayLogic.resolvedDayKey(stored: stored, now: monday, launchId: "other-launch"),
            Repository.logicalDayKey(monday),
            "a new process must not keep yesterday's stepped day"
        )
    }

    func testStrainFormattingMatchesRingWeekBarAndMetricOnBothScales() {
        let stored = 34.0
        let day = sampleMetric(day: "2026-11-16", strain: stored, recovery: 49, sleepMin: 431)

        for scale in [EffortScale.whoop, EffortScale.hundred] {
            let display = NativeDayLogic.strainDisplayValue(stored, scale: scale)
            let text = NativeDayLogic.strainText(stored, scale: scale)
            let bar = NativeWeek.points(kind: .strain, days: [day], todayKey: day.day, effortScale: scale)
                .first { $0.value.isFinite }?.value ?? .nan
            let model = NativeDay.make(
                days: [day], sleeps: [], workouts: [],
                todayKey: day.day, connected: true, effortScale: scale,
                now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
            )
            let cards = NativeWeek.cards(kind: .strain, days: [day], todayKey: day.day, effortScale: scale)
            let strainCard = cards.first { $0.title == "Strain" }

            XCTAssertEqual(bar, display, accuracy: 1e-9, "week bar must use the same scaler as the ring on \(scale)")
            XCTAssertEqual(model.strain.value, text, "ring caption must use NativeDayLogic.strainText on \(scale)")
            XCTAssertEqual(strainCard?.points.first { $0.value.isFinite }?.value ?? .nan, display, accuracy: 1e-9)
            XCTAssertEqual(strainCard?.maxY ?? -1, NativeDayLogic.strainMaxY(scale), accuracy: 1e-9)
            XCTAssertEqual(display, NativeDayLogic.strainDisplayValue(stored, scale: scale), accuracy: 1e-9,
                           "metric page must call this same scaler")
            if scale == .whoop {
                XCTAssertEqual(text, String(format: "%.1f", bar))
            } else {
                XCTAssertEqual(text, "\(Int(bar.rounded()))")
            }
        }

        XCTAssertEqual(NativeDayLogic.strainText(stored, scale: .whoop), "7.1")
        XCTAssertEqual(NativeDayLogic.strainText(stored, scale: .hundred), "34")
        XCTAssertEqual(NativeDayLogic.strainMaxY(.whoop), 21, accuracy: 1e-9)
        XCTAssertEqual(NativeDayLogic.strainMaxY(.hundred), 100, accuracy: 1e-9)
    }

    func testEffectiveStrainIsTheSameFunnelTodayUses() {
        XCTAssertEqual(NativeDayLogic.effectiveStrain(live: 12, stored: 8), 12)
        XCTAssertEqual(NativeDayLogic.effectiveStrain(live: 3, stored: 18), 18)
        XCTAssertEqual(NativeDayLogic.effectiveStrain(live: nil, stored: 18), 18)
        XCTAssertEqual(NativeDayLogic.effectiveStrain(live: 7, stored: nil), 7)
        XCTAssertNil(NativeDayLogic.effectiveStrain(live: nil, stored: nil))
        XCTAssertEqual(
            NativeDayLogic.effectiveStrain(live: 12, stored: 8),
            StrainScorer.effectiveEffort(live: 12, stored: 8)
        )
    }

    func testLiveStrainFillsTodayWhenTheStoredRowIsNil() {
        let today = "2026-11-16"
        let day = DailyMetric(
            day: today,
            totalSleepMin: 431, efficiency: 0.87, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 2, restingHr: 51, avgHrv: 66, recovery: 49, strain: nil,
            exerciseCount: 1
        )
        let now = localDate(year: 2026, month: 11, day: 16, hour: 16, minute: 0)
        let storedOnly = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop, now: now
        )
        XCTAssertFalse(storedOnly.strain.known)
        let live = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop, now: now,
            liveStrain: 22
        )
        XCTAssertTrue(live.strain.known)
        XCTAssertEqual(live.strain.value, NativeDayLogic.strainText(22, scale: .whoop))
        let yesterday = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 17, hour: 10, minute: 0),
            liveStrain: 22
        )
        XCTAssertFalse(yesterday.strain.known, "live strain is only for the logical today")
    }

    func testSleepSessionEnding0350LandsOnTheLogicalDayTheRingsUse() {
        let wake = localDate(year: 2026, month: 11, day: 16, hour: 3, minute: 50)
        XCTAssertNotEqual(Repository.localDayKey(wake), Repository.logicalDayKey(wake),
                          "03:50 is the window where local and logical keys disagree")

        let onset = wake.addingTimeInterval(-7 * 3600)
        let session = CachedSleepSession(
            startTs: Int(onset.timeIntervalSince1970),
            endTs: Int(wake.timeIntervalSince1970),
            efficiency: 0.9, restingHr: 50, avgHrv: 60, stagesJSON: nil
        )
        let todayKey = Repository.logicalDayKey(wake)
        XCTAssertEqual(NativeDayLogic.sleepSessionDayKey(wake), todayKey)

        let model = NativeDay.make(
            days: [], sleeps: [session], workouts: [],
            todayKey: todayKey, connected: true, effortScale: .whoop, now: wake
        )
        XCTAssertEqual(model.sleepEnd?.timeIntervalSince1970 ?? 0, wake.timeIntervalSince1970, accuracy: 0.5)
        XCTAssertEqual(model.sleepStart?.timeIntervalSince1970 ?? 0, onset.timeIntervalSince1970, accuracy: 0.5)
    }

    func testJournalChecksComeOnlyFromJournalEntries() {
        let today = "2026-11-16"
        let scoredWithoutJournal = sampleMetric(day: "2026-11-15", strain: 20, recovery: 55, sleepMin: 400)
        let scoredWithJournal = sampleMetric(day: today, strain: 34, recovery: 49, sleepMin: 431)
        let entries = [JournalEntry(day: today, question: "Did you drink any alcohol?", answeredYes: true, notes: nil)]

        let model = NativeDay.make(
            days: [scoredWithoutJournal, scoredWithJournal],
            sleeps: [], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0),
            journalEntries: entries
        )

        let keys = NativeWeek.lastSevenKeys(ending: today)
        XCTAssertEqual(model.journalDays.count, 7)
        XCTAssertEqual(model.journalDays, NativeDayLogic.journalChecks(entries: entries, todayKey: today))
        for (key, filled) in zip(keys, model.journalDays) {
            if key == today {
                XCTAssertTrue(filled, "a day with a journal entry is checked")
            } else {
                XCTAssertFalse(filled, "\(key) has recovery/sleep but no journal and must be unchecked")
            }
        }

        let empty = NativeDay.make(
            days: [scoredWithoutJournal, scoredWithJournal],
            sleeps: [], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop
        )
        XCTAssertEqual(empty.journalDays, Array(repeating: false, count: 7))
    }

    func testSleepDurationOneFunnelAcrossHomeAndSleep() {
        let today = "2026-11-15"
        let start = localDate(year: 2026, month: 11, day: 15, hour: 0, minute: 37)
        let end = localDate(year: 2026, month: 11, day: 15, hour: 8, minute: 0)
        let session = CachedSleepSession(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(end.timeIntervalSince1970),
            efficiency: 92.5, restingHr: 51, avgHrv: 66, stagesJSON: nil
        )
        let day = DailyMetric(
            day: today,
            totalSleepMin: 431, efficiency: 0.925, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 2, restingHr: 51, avgHrv: 66, recovery: 37, strain: 34,
            exerciseCount: 1, steps: 6545
        )
        let model = NativeDay.make(
            days: [day], sleeps: [session], workouts: [],
            todayKey: today, connected: true, effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 15, hour: 16, minute: 0)
        )
        let asleep = NativeDayLogic.asleepMinutes(
            light: 250, deep: 70, rem: 90, totalSleepMin: 431
        )
        XCTAssertEqual(asleep ?? -1, 410, accuracy: 0.1)
        XCTAssertEqual(model.asleepMinutes ?? -1, 410, accuracy: 0.1)
        XCTAssertEqual(model.inBedMinutes ?? -1, 443, accuracy: 0.6)
        XCTAssertEqual(model.sleepHours, NativeDayLogic.durationText(410))
        XCTAssertEqual(model.sleepBlock, model.sleepHours)
        let pill = HomeActivityItem.make(from: model).first { $0.kind == .sleep }
        XCTAssertEqual(pill?.trailing, model.sleepHours)
        let awake = model.sleepStages.first { $0.name == "Awake" }?.minutes ?? 0
        let staged = model.sleepStages.filter { $0.name != "Awake" }.compactMap(\.minutes).reduce(0, +)
        XCTAssertEqual(staged, 410, accuracy: 0.1)
        XCTAssertEqual(awake + staged, model.inBedMinutes ?? 0, accuracy: 0.6)
        let parts = NativeScoreMath.clockParts(model.asleepMinutes ?? 0)
        XCTAssertEqual(parts.hours, 6)
        XCTAssertEqual(parts.minutes, 50)
    }

    func testStepsOneFormatterOnHomeAndStrain() {
        let day = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: 410, efficiency: 0.92, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 1, restingHr: 51, avgHrv: 66, recovery: 49, strain: 34,
            exerciseCount: 1, steps: 6545, activeKcalEst: 512
        )
        let model = NativeDay.make(
            days: [day], sleeps: [], workouts: [],
            todayKey: day.day, connected: true, effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        )
        let expected = NativeDayLogic.countText(6545)
        XCTAssertEqual(model.dashboard.first { $0.title == "Steps" }?.value, expected)
        XCTAssertEqual(model.strain.rows.first { $0.title == "Steps" }?.value, expected)
        let home = HomeMetricItem.make(dashboard: model.dashboard, days: [day], todayKey: day.day)
            .first { $0.title == "Steps" }
        XCTAssertEqual(home?.value, expected)
    }

    func testHomeCaloriesRowUsesWholeDayEnergyAndHidesWhenNil() {
        let with = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: 410, efficiency: 0.92, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 1, restingHr: 51, avgHrv: 66, recovery: 49, strain: 34,
            exerciseCount: 1, steps: 6545, activeKcalEst: 512
        )
        let without = DailyMetric(
            day: "2026-11-16",
            totalSleepMin: 410, efficiency: 0.92, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 1, restingHr: 51, avgHrv: 66, recovery: 49, strain: 34,
            exerciseCount: 1, steps: 6545, activeKcalEst: nil
        )
        let now = localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        let modelWith = NativeDay.make(
            days: [with], sleeps: [], workouts: [],
            todayKey: with.day, connected: true, effortScale: .whoop, now: now
        )
        let expected = NativeDayLogic.countText(512)
        XCTAssertEqual(modelWith.dashboard.first { $0.title == "Calories" }?.value, expected)
        let home = HomeMetricItem.make(dashboard: modelWith.dashboard, days: [with], todayKey: with.day)
            .first { $0.title == "Calories" }
        XCTAssertEqual(home?.value, expected)
        XCTAssertEqual(home?.unit, "cal")
        let strainCard = NativeWeek.cards(kind: .strain, days: [with], todayKey: with.day)
            .first { $0.title == "Calories" }
        XCTAssertEqual(strainCard?.points.first { $0.key == with.day }?.value ?? -1, 512, accuracy: 0.1)

        let modelWithout = NativeDay.make(
            days: [without], sleeps: [], workouts: [],
            todayKey: without.day, connected: true, effortScale: .whoop, now: now
        )
        XCTAssertFalse(NativeScoreMath.hasValue(modelWithout.dashboard.first { $0.title == "Calories" }?.value ?? "—"))
        XCTAssertNil(
            HomeMetricItem.make(dashboard: modelWithout.dashboard, days: [without], todayKey: without.day)
                .first { $0.title == "Calories" }
        )
    }

    func testDayStrainAtLeastMaxActivityAndBothUseStrainText() {
        let day = sampleMetric(day: "2026-11-16", strain: 34, recovery: 49, sleepMin: 410)
        let start = localDate(year: 2026, month: 11, day: 16, hour: 8, minute: 27)
        let end = localDate(year: 2026, month: 11, day: 16, hour: 8, minute: 55)
        let workout = WorkoutRow(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(end.timeIntervalSince1970),
            sport: "Running", source: "my-whoop",
            durationS: 28 * 60, energyKcal: 312, avgHr: 168, maxHr: 182,
            strain: 26, distanceM: 5200,
            zonesJSON: #"{"zone1":8,"zone2":22,"zone3":18,"zone4":40,"zone5":12}"#,
            notes: nil, steps: 4200
        )
        XCTAssertGreaterThanOrEqual(day.strain ?? 0, workout.strain ?? .infinity)
        let model = NativeDay.make(
            days: [day], sleeps: [], workouts: [workout],
            todayKey: day.day, connected: true, effortScale: .whoop,
            now: localDate(year: 2026, month: 11, day: 16, hour: 10, minute: 0)
        )
        XCTAssertEqual(model.strain.value, NativeDayLogic.strainText(day.strain, scale: .whoop))
        XCTAssertEqual(model.activities.first?.strainText, NativeDayLogic.strainText(workout.strain, scale: .whoop))
        XCTAssertEqual(NativeDayLogic.strainText(34, scale: .whoop), "7.1")
        XCTAssertEqual(NativeDayLogic.strainText(26, scale: .whoop), "5.5")
        XCTAssertEqual(NativeDayLogic.strainYTicks(.whoop), [0, 7, 14, 21])
        XCTAssertEqual(NativeDayLogic.strainYTicks(.hundred), [0, 50, 100])
        let z13 = NativeDay.zoneMinutes([workout], zones: 0..<3)
        let z45 = NativeDay.zoneMinutes([workout], zones: 3..<5)
        XCTAssertEqual(z13 ?? -1, 28 * 0.48, accuracy: 0.2)
        XCTAssertEqual(z45 ?? -1, 28 * 0.52, accuracy: 0.2)
        XCTAssertEqual(
            model.strain.rows.first { $0.title == "Heart Rate Zones 1–3" }?.value,
            NativeDayLogic.durationText(z13 ?? 0)
        )
    }

    func testLineMarksBreakAtMissingDays() {
        let points = [
            NativeDayPoint(key: "2026-11-10", value: 58),
            NativeDayPoint(key: "2026-11-11", value: 62),
            NativeDayPoint(key: "2026-11-12", value: .nan),
            NativeDayPoint(key: "2026-11-13", value: 64),
        ]
        let drawn = NativeChartDay.linePoints(points)
        XCTAssertEqual(drawn.map(\.key), ["2026-11-10", "2026-11-11", "2026-11-13"])
        XCTAssertEqual(drawn.map(\.segment), [0, 0, 1])
        XCTAssertEqual(Set(drawn.map(\.segment)).count, 2)
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func sampleMetric(day: String, strain: Double, recovery: Double, sleepMin: Double) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleepMin, efficiency: 0.87, deepMin: 70, remMin: 90, lightMin: 250,
            disturbances: 2, restingHr: 51, avgHrv: 66, recovery: recovery, strain: strain,
            exerciseCount: 1
        )
    }
}

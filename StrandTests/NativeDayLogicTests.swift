import XCTest
import WhoopStore
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

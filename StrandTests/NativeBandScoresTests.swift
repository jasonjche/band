import XCTest
import WhoopStore
@testable import Strand
@testable import StrandAnalytics

final class NativeBandScoresTests: XCTestCase {

    func testImportedDayUsesWhoopRecovery() {
        let day = metric(day: "2026-10-10", recovery: 49)
        let imported: [String: ImportedSleepFigures] = [
            day.day: ImportedSleepFigures(performancePct: 91, consistencyPct: 77, needMin: 470, debtMin: 22)
        ]
        let snap = NativeBandScores.resolve(days: [day], importedSleep: imported)
        XCTAssertEqual(snap.byDay[day.day]?.recovery, 49)
        XCTAssertEqual(snap.byDay[day.day]?.source, .imported)
        let inputs = NativeBandScores.dayInputs(days: [day], sleeps: [], workouts: [], importedSleep: imported)
        XCTAssertEqual(inputs.first?.source, .imported)
    }

    func testStrapDayWithBandOutputUsesBand() throws {
        let built = strapHistory(days: 12, lastNoopRecovery: 11)
        let snap = NativeBandScores.resolve(days: built.days, sleeps: built.sleeps, importedSleep: [:])
        let params = try XCTUnwrap(NativeBandScores.params())
        let inputs = NativeBandScores.dayInputs(days: built.days, sleeps: built.sleeps, workouts: [], importedSleep: [:])
        XCTAssertTrue(inputs.allSatisfy { $0.source == .strap })
        let band = BandScores.evaluate(days: inputs, params: params)
        let last = try XCTUnwrap(built.days.last?.day)
        let bandRec = try XCTUnwrap(band.last?.recovery)
        XCTAssertEqual(snap.byDay[last]?.recovery, bandRec)
        XCTAssertNotEqual(snap.byDay[last]?.recovery, 11)
        XCTAssertEqual(snap.byDay[last]?.source, .band)
    }

    func testStrapDayInWarmupFallsBackToNoop() {
        let day = metric(day: "2026-10-10", recovery: 42)
        let sleep = session(ending: localDate(year: 2026, month: 10, day: 10, hour: 7, minute: 0))
        let snap = NativeBandScores.resolve(days: [day], sleeps: [sleep], importedSleep: [:])
        XCTAssertEqual(snap.byDay[day.day]?.recovery, 42, "warmup has no Band recovery yet")
        XCTAssertEqual(snap.byDay[day.day]?.source, .band)
        let inputs = NativeBandScores.dayInputs(days: [day], sleeps: [sleep], workouts: [], importedSleep: [:])
        XCTAssertEqual(inputs.first?.source, .strap)
    }

    func testEnergyUsesWholeDayActiveKcalNeverWorkoutKcal() {
        let day = metric(day: "2026-10-10", recovery: 50, kcal: 512)
        let start = localDate(year: 2026, month: 10, day: 10, hour: 10, minute: 0)
        let workout = WorkoutRow(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(start.timeIntervalSince1970) + 1800,
            sport: "Running", source: "whoop",
            durationS: 1800, energyKcal: 9999, avgHr: 160, maxHr: 180,
            strain: 10, distanceM: 4000,
            zonesJSON: #"{"z1":10,"z2":20,"z3":30,"z4":30,"z5":10}"#,
            notes: nil, steps: 3000
        )
        let inputs = NativeBandScores.dayInputs(days: [day], sleeps: [], workouts: [workout])
        XCTAssertEqual(inputs.first?.energyKcal, 512)
        XCTAssertNotEqual(inputs.first?.energyKcal, 9999)
    }

    func testWorkoutsKeyedBySleepSessionDayKey() {
        let early = metric(day: "2026-11-15", recovery: 40, kcal: 400)
        let late = metric(day: "2026-11-16", recovery: 50, kcal: 500)
        // 02:00 on the 16th is before the 04:00 rollover, so the sleep-session day is the 15th.
        let start = localDate(year: 2026, month: 11, day: 16, hour: 2, minute: 0)
        XCTAssertEqual(
            NativeDayLogic.sleepSessionDayKey(start),
            early.day
        )
        XCTAssertNotEqual(NativeDayLogic.sleepSessionDayKey(start), late.day)
        let workout = WorkoutRow(
            startTs: Int(start.timeIntervalSince1970),
            endTs: Int(start.timeIntervalSince1970) + 1800,
            sport: "Running", source: "whoop",
            durationS: 1800, energyKcal: 300, avgHr: 150, maxHr: 170,
            strain: 8, distanceM: 3000,
            zonesJSON: #"{"z1":10,"z2":20,"z3":30,"z4":30,"z5":10}"#,
            notes: nil, steps: 2000
        )
        let inputs = NativeBandScores.dayInputs(days: [early, late], sleeps: [], workouts: [workout])
        let byDay = Dictionary(uniqueKeysWithValues: inputs.map { ($0.day, $0) })
        XCTAssertNotNil(byDay[early.day]?.edwards)
        XCTAssertGreaterThan(byDay[early.day]?.edwards ?? 0, 0)
        XCTAssertNil(byDay[late.day]?.edwards)
    }

    // MARK: - fixtures

    private func strapHistory(days n: Int, lastNoopRecovery: Double)
    -> (days: [DailyMetric], sleeps: [CachedSleepSession]) {
        var days: [DailyMetric] = []
        var sleeps: [CachedSleepSession] = []
        for i in 0..<n {
            let day = String(format: "2026-10-%02d", i + 1)
            let rec = i == n - 1 ? lastNoopRecovery : 50.0
            days.append(metric(day: day, recovery: rec, hrv: 58 + Double(i % 5)))
            let end = localDate(year: 2026, month: 10, day: i + 1, hour: 7, minute: 0)
            sleeps.append(session(ending: end))
        }
        return (days, sleeps)
    }

    private func session(ending end: Date) -> CachedSleepSession {
        let endTs = Int(end.timeIntervalSince1970)
        let startTs = endTs - 8 * 3600
        return CachedSleepSession(
            startTs: startTs, endTs: endTs,
            efficiency: 0.90, restingHr: 52, avgHrv: 60,
            stagesJSON: nil
        )
    }

    private func metric(day: String, recovery: Double, hrv: Double = 60, kcal: Double? = 1800) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 430,
            efficiency: 0.90,
            deepMin: 80, remMin: 90, lightMin: 260,
            disturbances: 1,
            restingHr: 52,
            avgHrv: hrv,
            recovery: recovery,
            strain: 12,
            exerciseCount: 0,
            spo2Pct: 96.5,
            respRateBpm: 14.5,
            activeKcalEst: kcal,
            skinTempC: 33.4
        )
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}

import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeStrainTests: XCTestCase {

    func testImportedDayKeepsStoredWhoopStrain() {
        let stored = StrainScorer.effortValue(fromWhoopStrain: 7.1)
        XCTAssertEqual(NativeStrain.day(stored: stored, live: 99, imported: true), stored)
        XCTAssertEqual(
            NativeDayLogic.strainText(NativeStrain.day(stored: stored, live: 99, imported: true), scale: .whoop),
            "7.1"
        )
    }

    func testStrapDayPrefersLiveBandStrainOverStored() {
        let stored = 0.0
        let live = NativeStrain.score(constHR(75, seconds: 16 * 3600), maxHR: 190, restingHR: 60)
        let resolved = NativeStrain.day(stored: stored, live: live, imported: false)
        XCTAssertEqual(NativeDayLogic.strainText(resolved, scale: .whoop), "5.9")
        XCTAssertNotEqual(NativeDayLogic.strainText(resolved, scale: .whoop), "0.0")
    }

    func testNoWorkoutStrapDayAt75BpmReadsAboutFiveNine() {
        let samples = constHR(75, seconds: 16 * 3600)
        let stored = NativeStrain.score(samples, maxHR: 190, restingHR: 60)
        XCTAssertEqual(NativeDayLogic.strainText(stored, scale: .whoop), "5.9")
        XCTAssertGreaterThan(stored ?? 0, 20)
        XCTAssertLessThan(stored ?? 0, 30)
        let edwards = StrainScorer.strain(samples, maxHR: 190, restingHR: 60)
        XCTAssertEqual(edwards ?? -1, 0, accuracy: 1e-9, "Edwards still zeros this day")
    }

    func testImportedWhoopWorkoutKeepsStoredStrain() {
        let row = WorkoutRow(
            startTs: 1, endTs: 2, sport: "Running", source: "whoop",
            durationS: 1800, energyKcal: nil, avgHr: 140, maxHr: 160, strain: 34,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        XCTAssertTrue(NativeStrain.isImportedWorkout(row.source))
        XCTAssertEqual(NativeStrain.workout(row), 34)
    }

    func testRestingHRFallsBackToPriorDayThenDefault() {
        let today = DailyMetric(
            day: "2026-11-17", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil
        )
        let prior = DailyMetric(
            day: "2026-11-16", totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: 51, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil
        )
        XCTAssertEqual(NativeStrain.restingHR(day: today, days: [prior, today], dayKey: today.day), 51)
        XCTAssertEqual(NativeStrain.restingHR(day: today, days: [today], dayKey: today.day), 60)
        XCTAssertEqual(NativeStrain.restingHR(day: prior), 51)
    }

    private func constHR(_ bpm: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: $0, bpm: bpm) }
    }
}

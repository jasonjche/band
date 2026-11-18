import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class AppleWorkoutImportTests: XCTestCase {

    private func row(start: Int, end: Int, sport: String,
                     avgHr: Int? = nil, strain: Double? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: "apple-health",
                   durationS: Double(end - start), energyKcal: nil,
                   avgHr: avgHr, maxHr: avgHr, strain: strain,
                   distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
    }

    func testDropsGenericWorkoutInTheSameWindowAsASpecificSportWithHR() {
        let strength = row(start: 1_000, end: 2_800, sport: "Strength Training", avgHr: 128, strain: 22)
        let generic = row(start: 1_000, end: 2_800, sport: "Workout")
        let (keep, drop) = AppleWorkoutImport.partition([generic, strength])
        XCTAssertEqual(keep.map(\.sport), ["Strength Training"])
        XCTAssertEqual(drop.map(\.sport), ["Workout"])
        XCTAssertEqual(AppleWorkoutImport.collapseDuplicates([generic, strength]).map(\.sport),
                       ["Strength Training"])
    }

    func testSameWindowAllowsSixtySecondsOnStartAndEnd() {
        let strength = row(start: 1_000, end: 2_800, sport: "Strength Training", avgHr: 110, strain: 18)
        let generic = row(start: 1_060, end: 2_740, sport: "Workout")
        XCTAssertTrue(AppleWorkoutImport.sameWindow(strength, generic))
        let drop = AppleWorkoutImport.partition([strength, generic]).drop
        XCTAssertEqual(drop.map(\.sport), ["Workout"])
    }

    func testKeepsGenericWhenTheWindowDiffersByMoreThanSixtySeconds() {
        let strength = row(start: 1_000, end: 2_800, sport: "Strength Training", avgHr: 110, strain: 18)
        let generic = row(start: 1_061, end: 2_800, sport: "Workout")
        let (keep, drop) = AppleWorkoutImport.partition([strength, generic])
        XCTAssertEqual(Set(keep.map(\.sport)), ["Strength Training", "Workout"])
        XCTAssertTrue(drop.isEmpty)
    }

    func testKeepsALoneGenericWorkout() {
        let generic = row(start: 5_000, end: 6_000, sport: "Workout")
        let (keep, drop) = AppleWorkoutImport.partition([generic])
        XCTAssertEqual(keep.map(\.sport), ["Workout"])
        XCTAssertTrue(drop.isEmpty)
    }

    func testDoesNotDropTwoSpecificSports() {
        let run = row(start: 1_000, end: 2_800, sport: "Running", avgHr: 150, strain: 40)
        let walk = row(start: 1_000, end: 2_800, sport: "Walking", avgHr: 90, strain: 8)
        let (keep, drop) = AppleWorkoutImport.partition([run, walk])
        XCTAssertEqual(Set(keep.map(\.sport)), ["Running", "Walking"])
        XCTAssertTrue(drop.isEmpty)
    }

    func testScoresStrainFromAnyNonEmptyHRWindow() throws {
        let samples = (0..<30).map { HRSample(ts: 1_000 + $0 * 10, bpm: 140) }
        let scored = try XCTUnwrap(AppleWorkoutImport.scored(samples: samples, maxHR: 190))
        XCTAssertEqual(scored.avgHr, 140)
        XCTAssertEqual(scored.maxHr, 140)
        XCTAssertGreaterThan(scored.strain100, 0)
        XCTAssertNil(AppleWorkoutImport.scored(samples: [], maxHR: 190))
    }

    func testFilledWritesStrainAndLeavesExistingFields() throws {
        let samples = (0..<60).map { HRSample(ts: 1_000 + $0, bpm: 150) }
        let blank = row(start: 1_000, end: 1_060, sport: "Running")
        let filled = try XCTUnwrap(AppleWorkoutImport.filled(blank, samples: samples, maxHR: 190))
        XCTAssertEqual(filled.avgHr, 150)
        XCTAssertNotNil(filled.strain)
        XCTAssertGreaterThan(filled.strain ?? 0, 0)

        let already = row(start: 1_000, end: 1_060, sport: "Running", avgHr: 99, strain: 12)
        XCTAssertNil(AppleWorkoutImport.filled(already, samples: samples, maxHR: 190))
    }

    func testBackfillDropsDuplicateGenericsThenFillsTheRest() throws {
        let strength = row(start: 1_000, end: 2_800, sport: "Strength Training", avgHr: 128, strain: 22)
        let genericDup = row(start: 1_012, end: 2_790, sport: "Workout")
        let lonely = row(start: 9_000, end: 9_600, sport: "Workout")
        let (keep, drop) = AppleWorkoutImport.partition([strength, genericDup, lonely])
        XCTAssertEqual(drop.count, 1)
        XCTAssertEqual(Set(keep.map(\.sport)), ["Strength Training", "Workout"])

        let samples = (0..<120).map { HRSample(ts: 9_000 + $0, bpm: 130) }
        let filled = try XCTUnwrap(AppleWorkoutImport.filled(lonely, samples: samples, maxHR: 190))
        XCTAssertEqual(filled.sport, "Workout")
        XCTAssertNotNil(filled.strain)
        XCTAssertNotNil(filled.avgHr)
    }
}

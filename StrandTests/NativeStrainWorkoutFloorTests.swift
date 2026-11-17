import XCTest
import StrandAnalytics
@testable import Strand

final class NativeStrainWorkoutFloorTests: XCTestCase {

    func testDayIsUnchangedWhenItAlreadyCoversTheWorkout() {
        XCTAssertEqual(NativeStrain.withWorkout(day: 60, workoutMax: 50), 60)
        XCTAssertEqual(NativeStrain.withWorkout(day: 60, workoutMax: nil), 60)
    }

    func testWorkoutStandsInForAMissingDay() {
        XCTAssertEqual(NativeStrain.withWorkout(day: nil, workoutMax: 53), 53)
    }

    func testDayBelowItsWorkoutAddsTheWorkoutLoad() throws {
        let combined = try XCTUnwrap(NativeStrain.withWorkout(day: 41.4, workoutMax: 53.4))
        XCTAssertGreaterThan(combined, 53.4)
        XCTAssertLessThan(combined, 75)
    }

    func testLoadInvertsTheStrainCurve() throws {
        let params = try XCTUnwrap(BandStrain.bundledParams())
        let load = try XCTUnwrap(NativeStrain.load(effort100: 50, params: params))
        let back = try XCTUnwrap(BandStrain.effort100(BandStrain.strain(load: load, params: params)))
        XCTAssertEqual(back, 50, accuracy: 0.001)
    }

    func testWeightAppliesOnlyANewerReading() {
        let readings = [NativeWeight.Reading(day: "2026-10-30", kg: 73.1),
                        NativeWeight.Reading(day: "2026-11-04", kg: 72.7)]
        XCTAssertEqual(NativeWeight.weightToApply(readings: readings, lastAppliedDay: nil)?.kg, 72.7)
        XCTAssertNil(NativeWeight.weightToApply(readings: readings, lastAppliedDay: "2026-11-04"))
        XCTAssertEqual(NativeWeight.weightToApply(readings: readings, lastAppliedDay: "2026-10-30")?.day,
                       "2026-11-04")
    }
}

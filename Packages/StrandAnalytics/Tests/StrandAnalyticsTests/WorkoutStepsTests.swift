import XCTest
@testable import StrandAnalytics

final class WorkoutStepsTests: XCTestCase {

    func testScaledTicksAppliesCalibration() {
        XCTAssertEqual(WorkoutSteps.scaledTicks(120, ticksPerStep: 1), 120)
        XCTAssertEqual(WorkoutSteps.scaledTicks(240, ticksPerStep: 2), 120)
        XCTAssertNil(WorkoutSteps.scaledTicks(nil, ticksPerStep: 1))
        XCTAssertNil(WorkoutSteps.scaledTicks(0, ticksPerStep: 1))
        XCTAssertEqual(WorkoutSteps.scaledTicks(7, ticksPerStep: 0.5), 14)
    }

    func testAppleHoursAreProportionalToOverlap() {
        // Hour 08:00 has 6_000 steps; workout 08:21–09:00 is 39 minutes.
        let hour = 8 * 3_600
        let from = hour + 21 * 60
        let to = hour + 3_600
        let steps = WorkoutSteps.appleStepsInWindow([(ts: hour, steps: 6_000)], from: from, to: to)
        XCTAssertEqual(steps, 3_900)
    }

    func testAppleHoursIgnoreNonOverlappingBuckets() {
        let hour = 8 * 3_600
        XCTAssertNil(WorkoutSteps.appleStepsInWindow(
            [(ts: hour - 3_600, steps: 9_999)], from: hour, to: hour + 1_800
        ))
        XCTAssertEqual(
            WorkoutSteps.appleStepsInWindow([(ts: hour, steps: 3_600)], from: hour, to: hour + 1_800),
            1_800
        )
    }

    func testResolvePrefersStrapThenAppleThenStored() {
        XCTAssertEqual(WorkoutSteps.resolve(strap: 3_942, apple: 5_000, stored: 1), 3_942)
        XCTAssertEqual(WorkoutSteps.resolve(strap: nil, apple: 5_000, stored: 1), 5_000)
        XCTAssertEqual(WorkoutSteps.resolve(strap: 0, apple: nil, stored: 12), 12)
        XCTAssertNil(WorkoutSteps.resolve(strap: nil, apple: nil, stored: nil))
        XCTAssertNil(WorkoutSteps.resolve(strap: 0, apple: 0, stored: 0))
    }
}

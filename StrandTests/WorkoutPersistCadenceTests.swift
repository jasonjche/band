import XCTest
@testable import Strand

/// In-flight workout snapshots used to rewrite UserDefaults on every HR sample. The 15 s floor
/// keeps crash recovery and cuts the JSON encode of a growing sample array.
final class WorkoutPersistCadenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFirstWriteAndForcedWriteAlwaysPersist() {
        XCTAssertTrue(ActiveWorkoutPersistence.PersistCadence.due(
            lastPersistedAt: nil, now: t0, force: false))
        XCTAssertTrue(ActiveWorkoutPersistence.PersistCadence.due(
            lastPersistedAt: t0, now: t0.addingTimeInterval(1), force: true))
    }

    func testSampleTicksInsideTheWindowAreSkipped() {
        XCTAssertFalse(ActiveWorkoutPersistence.PersistCadence.due(
            lastPersistedAt: t0, now: t0.addingTimeInterval(14.9), force: false))
    }

    func testTheBoundaryBelongsToPersist() {
        XCTAssertTrue(ActiveWorkoutPersistence.PersistCadence.due(
            lastPersistedAt: t0,
            now: t0.addingTimeInterval(ActiveWorkoutPersistence.PersistCadence.interval),
            force: false))
    }
}

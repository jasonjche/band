import XCTest
import WhoopProtocol
@testable import Strand

final class AppleWorkoutHeartRateTests: XCTestCase {

    private func samples(from start: Int, every seconds: Int, count: Int, bpm: Int = 140) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0 * seconds, bpm: bpm) }
    }

    // MARK: - Coverage threshold

    func testStrapWinsWhenHalfTheMinutesHaveASample() {
        let from = 1_700_000_000
        let to = from + 600
        // 10-minute window; one beat in each of the first 5 minutes → exactly 50%.
        let strap = (0..<5).map { HRSample(ts: from + $0 * 60, bpm: 150) }
        let apple = [HRSample(ts: from + 10, bpm: 90)]
        let picked = WorkoutHeartRateSelection.select(strap: strap, apple: apple, from: from, to: to)
        XCTAssertEqual(picked.origin, .strap)
        XCTAssertEqual(picked.samples, strap)
        XCTAssertEqual(WorkoutHeartRateSelection.minuteCoverage(samples: strap, from: from, to: to), 0.5)
    }

    func testAppleWinsWhenStrapCoverageIsBelowHalf() {
        let from = 1_700_000_000
        let to = from + 600
        // 4 of 10 minutes → 40%.
        let strap = (0..<4).map { HRSample(ts: from + $0 * 60, bpm: 150) }
        let apple = samples(from: from, every: 5, count: 40, bpm: 128)
        let picked = WorkoutHeartRateSelection.select(strap: strap, apple: apple, from: from, to: to)
        XCTAssertEqual(picked.origin, .appleHealth)
        XCTAssertEqual(picked.samples, apple)
    }

    func testEmptyWindowAndEmptySourcesYieldNone() {
        let from = 1_700_000_000
        XCTAssertEqual(
            WorkoutHeartRateSelection.select(strap: [], apple: [], from: from, to: from).origin,
            .none)
        XCTAssertEqual(
            WorkoutHeartRateSelection.select(strap: [], apple: [], from: from, to: from + 600).origin,
            .none)
        let apple = [HRSample(ts: from + 1, bpm: 110)]
        let picked = WorkoutHeartRateSelection.select(strap: [], apple: apple, from: from, to: from + 600)
        XCTAssertEqual(picked.origin, .appleHealth)
        XCTAssertEqual(picked.samples, apple)
    }

    func testSamplesOutsideTheWindowDoNotCountTowardCoverage() {
        let from = 1_700_000_000
        let to = from + 600
        let strap = [
            HRSample(ts: from - 60, bpm: 140),
            HRSample(ts: to + 60, bpm: 140),
        ]
        XCTAssertEqual(WorkoutHeartRateSelection.minuteCoverage(samples: strap, from: from, to: to), 0)
        let apple = [HRSample(ts: from + 30, bpm: 100)]
        let picked = WorkoutHeartRateSelection.select(strap: strap, apple: apple, from: from, to: to)
        XCTAssertEqual(picked.origin, .appleHealth)
    }

    func testSparseStrapStillWinsOnceHalfTheMinutesAreHit() {
        let from = 1_700_000_000
        let to = from + 1_200
        // 20-minute window; beats in 10 distinct minutes, clustered then gapped.
        let strap = (0..<10).map { HRSample(ts: from + $0 * 120, bpm: 160) }
        XCTAssertEqual(WorkoutHeartRateSelection.minuteCoverage(samples: strap, from: from, to: to), 0.5)
        let picked = WorkoutHeartRateSelection.select(strap: strap, apple: [HRSample(ts: from, bpm: 80)],
                                                      from: from, to: to)
        XCTAssertEqual(picked.origin, .strap)
    }

    // MARK: - JSON side-store

    private func freshDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-workout-hr-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testStoreRoundTripAndEmptyFetchedMarker() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(AppleWorkoutHRStore.contains(startTs: 1_700_000_000, sport: "Running", in: dir))
        XCTAssertNil(AppleWorkoutHRStore.load(startTs: 1_700_000_000, sport: "Running", from: dir))

        let hr = [HRSample(ts: 1_700_000_010, bpm: 142), HRSample(ts: 1_700_000_020, bpm: 147)]
        AppleWorkoutHRStore.store(hr, startTs: 1_700_000_000, sport: "Running", into: dir)
        XCTAssertTrue(AppleWorkoutHRStore.contains(startTs: 1_700_000_000, sport: "Running", in: dir))
        XCTAssertEqual(AppleWorkoutHRStore.load(startTs: 1_700_000_000, sport: "Running", from: dir), hr)

        AppleWorkoutHRStore.store([], startTs: 1_700_000_500, sport: "Yoga", into: dir)
        XCTAssertTrue(AppleWorkoutHRStore.contains(startTs: 1_700_000_500, sport: "Yoga", in: dir),
                      "an empty fetch must still skip the next import")
        XCTAssertEqual(AppleWorkoutHRStore.load(startTs: 1_700_000_500, sport: "Yoga", from: dir), [])

        AppleWorkoutHRStore.remove(startTs: 1_700_000_000, sport: "Running", from: dir)
        XCTAssertFalse(AppleWorkoutHRStore.contains(startTs: 1_700_000_000, sport: "Running", in: dir))
    }

    func testStoreCapsAtMaxSamplesAndKeysBySport() throws {
        let dir = try freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tooMany = samples(from: 1_700_000_000, every: 1, count: AppleWorkoutHRStore.maxSamples + 25)
        AppleWorkoutHRStore.store(tooMany, startTs: 1_700_000_000, sport: "Running", into: dir)
        XCTAssertEqual(AppleWorkoutHRStore.load(startTs: 1_700_000_000, sport: "Running", from: dir)?.count,
                       AppleWorkoutHRStore.maxSamples)

        AppleWorkoutHRStore.store([HRSample(ts: 1, bpm: 90)], startTs: 1_700_000_000, sport: "Walking", into: dir)
        XCTAssertEqual(AppleWorkoutHRStore.load(startTs: 1_700_000_000, sport: "Running", from: dir)?.count,
                       AppleWorkoutHRStore.maxSamples)
        XCTAssertEqual(AppleWorkoutHRStore.load(startTs: 1_700_000_000, sport: "Walking", from: dir),
                       [HRSample(ts: 1, bpm: 90)])
    }
}

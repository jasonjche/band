import XCTest
import WhoopProtocol
import StrandImport

/// Pure windowing / downsample for strap HR attached to a Health workout.
final class WorkoutHeartRateWritebackTests: XCTestCase {

    private let start = 1_700_000_000
    private var end: Int { start + 60 }

    private func samples(_ offsetsAndBpm: [(Int, Int)]) -> [HRSample] {
        offsetsAndBpm.map { HRSample(ts: start + $0.0, bpm: $0.1) }
    }

    private func ts(_ result: [HRSample]) -> [Int] {
        result.map { $0.ts - start }
    }

    // MARK: - Window

    func testDropsSamplesOutsideTheWorkoutWindow() {
        let raw = samples([
            (-5, 90),
            (0, 100),
            (30, 120),
            (60, 130),
            (61, 140),
        ])
        let result = HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end)
        XCTAssertEqual(ts(result), [0, 30, 60])
        XCTAssertEqual(result.map(\.bpm), [100, 120, 130])
    }

    func testEmptyOrInvertedWindowYieldsNothing() {
        let raw = samples([(0, 100), (5, 110)])
        XCTAssertEqual(HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: start), [])
        XCTAssertEqual(HealthWriteback.workoutHeartRateSamples(raw, startTs: end, endTs: start), [])
        XCTAssertEqual(HealthWriteback.workoutHeartRateSamples([], startTs: start, endTs: end), [])
    }

    func testSortsUnsortedInput() {
        let raw = samples([(15, 115), (0, 100), (10, 110), (5, 105)])
        XCTAssertEqual(ts(HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end)),
                       [0, 5, 10, 15])
    }

    func testDedupesEqualTimestampsKeepingTheFirst() {
        let raw = [
            HRSample(ts: start + 10, bpm: 111),
            HRSample(ts: start + 10, bpm: 222),
            HRSample(ts: start + 20, bpm: 130),
        ]
        let result = HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end)
        XCTAssertEqual(result, [
            HRSample(ts: start + 10, bpm: 111),
            HRSample(ts: start + 20, bpm: 130),
        ])
    }

    func testDropsInvalidBpm() {
        let raw = samples([(0, 10), (5, 140), (10, 300), (15, 24), (20, 241)])
        XCTAssertEqual(HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end).map(\.bpm),
                       [140])
    }

    // MARK: - Downsample

    func testDownsamplesOneHertzToAboutOneSamplePerFiveSeconds() {
        let raw = (0...20).map { HRSample(ts: start + $0, bpm: 100 + $0) }
        let result = HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: start + 20)
        XCTAssertEqual(ts(result), [0, 5, 10, 15, 20])
        XCTAssertEqual(result.map(\.bpm), [100, 105, 110, 115, 120])
        XCTAssertEqual(HealthWriteback.workoutHeartRateIntervalSeconds, 5)
    }

    func testKeepsSparseSamplesAlreadyAtLeastFiveSecondsApart() {
        let raw = samples([(2, 90), (8, 100), (20, 110)])
        XCTAssertEqual(ts(HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end)),
                       [2, 8, 20])
    }

    func testWindowThenDedupThenDownsample() {
        let raw = [
            HRSample(ts: start - 1, bpm: 80),
            HRSample(ts: start + 3, bpm: 101),
            HRSample(ts: start + 4, bpm: 102),
            HRSample(ts: start + 4, bpm: 199),
            HRSample(ts: start + 9, bpm: 110),
            HRSample(ts: start + 61, bpm: 150),
        ]
        let result = HealthWriteback.workoutHeartRateSamples(raw, startTs: start, endTs: end)
        XCTAssertEqual(result, [
            HRSample(ts: start + 3, bpm: 101),
            HRSample(ts: start + 9, bpm: 110),
        ])
    }

    func testMetadataKeyIsStableAndDistinctFromTheWorkoutExternalUUID() {
        XCTAssertEqual(HealthWriteback.appleHealthWorkoutHeartRateMetadataKey, "noop.workoutHeartRate")
        XCTAssertNotEqual(HealthWriteback.appleHealthWorkoutHeartRateMetadataKey,
                          HealthWriteback.appleHealthWorkoutKeyPrefix)
        XCTAssertFalse(HealthWriteback.appleHealthWorkoutKey(startTs: start)
                        .hasPrefix(HealthWriteback.appleHealthWorkoutHeartRateMetadataKey))
    }
}

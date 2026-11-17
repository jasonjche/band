import XCTest
import StrandAnalytics
@testable import Strand

/// Which detected bouts the personal build logs without a prompt.
final class AutoSaveDetectedWorkoutsTests: XCTestCase {

    private func bout(_ start: Int, _ end: Int) -> DetectedWorkout {
        DetectedWorkout(startSec: start, endSec: end, avgBpm: 120, peakBpm: 150,
                        durationMin: (end - start) / 60)
    }

    func testKeepsFinishedBoutsOldestFirst() {
        let keep = Repository.autoSavableWorkouts(
            [bout(5_000, 6_000), bout(1_000, 2_000)],
            frontierTs: 10_000, settleSeconds: 600,
            autoDismissedTokens: [], detectedDismissedTokens: [])
        XCTAssertEqual(keep.map(\.startSec), [1_000, 5_000])
    }

    func testLeavesABoutThatMayStillBeRunning() {
        let keep = Repository.autoSavableWorkouts(
            [bout(1_000, 2_000), bout(8_000, 9_500)],
            frontierTs: 10_000, settleSeconds: 600,
            autoDismissedTokens: [], detectedDismissedTokens: [])
        XCTAssertEqual(keep.map(\.startSec), [1_000])
    }

    func testSkipsADeletedSpanEvenWhenTheBoundaryMoved() {
        let keep = Repository.autoSavableWorkouts(
            [bout(1_030, 2_010), bout(5_000, 6_000)],
            frontierTs: 10_000, settleSeconds: 600,
            autoDismissedTokens: ["5000:6000"], detectedDismissedTokens: ["1000:2000"])
        XCTAssertTrue(keep.isEmpty)
    }
}

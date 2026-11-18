import XCTest
import StrandAnalytics
import WhoopStore
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

    func testAutoSavedMarkerRequiresManualActivity() {
        XCTAssertTrue(Repository.isAutoSavedActivity(
            startTs: 1, endTs: 2, sport: "Activity", source: "manual",
            tokens: ["1:2"], grandfather: false, scanFrom: 0))
        XCTAssertFalse(Repository.isAutoSavedActivity(
            startTs: 1, endTs: 2, sport: "Running", source: "manual",
            tokens: ["1:2"], grandfather: false, scanFrom: 0))
        XCTAssertFalse(Repository.isAutoSavedActivity(
            startTs: 1, endTs: 2, sport: "Activity", source: "apple-health",
            tokens: ["1:2"], grandfather: false, scanFrom: 0))
        XCTAssertTrue(Repository.isAutoSavedActivity(
            startTs: 100, endTs: 200, sport: "Activity", source: "manual",
            tokens: [], grandfather: true, scanFrom: 50))
        XCTAssertFalse(Repository.isAutoSavedActivity(
            startTs: 10, endTs: 20, sport: "Activity", source: "manual",
            tokens: [], grandfather: true, scanFrom: 50))
        XCTAssertFalse(Repository.isAutoSavedActivity(
            startTs: 100, endTs: 200, sport: "Activity", source: "manual",
            tokens: [], grandfather: false, scanFrom: 50))
    }

    func testStaleAutoSavedRowsAreThoseThatNoLongerQualify() {
        let bogus = WorkoutRow(
            startTs: 1_000, endTs: 2_000, sport: "Activity", source: "manual",
            durationS: 1_000, energyKcal: nil, avgHr: 92, maxHr: 121, strain: 4.9,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let real = WorkoutRow(
            startTs: 3_000, endTs: 4_000, sport: "Activity", source: "manual",
            durationS: 1_000, energyKcal: nil, avgHr: 103, maxHr: 156, strain: 9.3,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
        let keep = [bout(3_000, 4_000)]
        let stale = Repository.staleAutoSavedWorkouts([bogus, real], qualifying: keep)
        XCTAssertEqual(stale.map(\.startTs), [1_000])
    }
}

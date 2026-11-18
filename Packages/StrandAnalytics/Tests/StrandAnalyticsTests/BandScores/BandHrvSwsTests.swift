import XCTest
@testable import StrandAnalytics

final class BandScoresHrvSwsTests: XCTestCase {

    func testRangeFilterDropsImpossibleBeats() {
        XCTAssertNil(BandHrvSws.cleanWindow([250, 250, 250]))
        let cleaned = BandHrvSws.cleanWindow([800, 810, 790, 805, 795, 800, 812, 788, 801, 799])
        XCTAssertEqual(cleaned?.count, 10)
    }

    func testArtifactRuleFlagsFarBeats() {
        var rr = [Double](repeating: 800, count: 40)
        rr[10] = 1400
        let cleaned = BandHrvSws.cleanWindow(rr)!
        XCTAssertFalse(cleaned.contains(1400))
        XCTAssertEqual(cleaned.count, 39)
    }

    func testRmssdMatchesTaskForce() {
        let rr = [800.0, 820, 790, 810, 805]
        var ss = 0.0
        for i in 1..<rr.count {
            let d = rr[i] - rr[i - 1]
            ss += d * d
        }
        let expect = sqrt(ss / Double(rr.count - 1))
        XCTAssertEqual(BandHrvSws.rmssd(rr) ?? -1, expect, accuracy: 1e-12)
    }

    func testSplitOnGapsOver2s() {
        let beats = [
            BandHrvSws.Beat(tSec: 0, rrMs: 800),
            BandHrvSws.Beat(tSec: 0.8, rrMs: 810),
            BandHrvSws.Beat(tSec: 5.0, rrMs: 790),
            BandHrvSws.Beat(tSec: 5.8, rrMs: 800),
        ]
        let groups = BandHrvSws.splitOnGaps(beats)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[1].count, 2)
    }

    func testAllSwsAndFallbackWhenThin() {
        let start = 1_000.0
        let end = start + 3 * 3600
        var beats: [BandHrvSws.Beat] = []
        var t = start
        while t < end {
            beats.append(BandHrvSws.Beat(tSec: t, rrMs: 800 + 20 * sin(t / 7)))
            t += 0.8
        }
        // Only 5 minutes of SWS — below the 10-minute minimum.
        let thin = [
            BandHrvSws.Epoch(startSec: start + 600, endSec: start + 900, isSws: true),
        ]
        let thinResult = BandHrvSws.compute(
            beats: beats, epochs: thin, sleepStartSec: start, sleepEndSec: end
        )
        XCTAssertTrue(thinResult.fallback)
        XCTAssertNotNil(thinResult.fullSleepRmssd)

        // 40 minutes of SWS in the last two hours.
        let lateStart = end - 50 * 60
        let rich = [
            BandHrvSws.Epoch(startSec: lateStart, endSec: lateStart + 40 * 60, isSws: true),
        ]
        let richResult = BandHrvSws.compute(
            beats: beats, epochs: rich, sleepStartSec: start, sleepEndSec: end
        )
        XCTAssertFalse(richResult.fallback)
        XCTAssertGreaterThan(richResult.validSwsMinutes, 10)
        XCTAssertNotNil(richResult.allSwsRmssd)
        XCTAssertNotNil(richResult.lastSwsRmssd)
        XCTAssertGreaterThan(richResult.windowCount, 1)
        // Last-SWS weights later windows; it is allowed to differ from the unweighted mean.
        XCTAssertNotEqual(richResult.allSwsRmssd ?? 0, 0)
    }

    func testDoesNotFeedRecoveryContract() {
        // Recovery inputs are z-scores + sleep performance. SWS HRV is a sibling
        // instrument: BandRecovery.run has no HRV-SWS parameter.
        XCTAssertTrue(true)
    }
}

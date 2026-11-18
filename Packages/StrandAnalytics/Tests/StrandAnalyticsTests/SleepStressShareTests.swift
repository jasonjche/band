import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepStressShareTests: XCTestCase {

    /// HIGH on the shared 0–3 scale. LOW is the squash of raw 0 (baseline ≈ 1.5).
    private var high: Double { DaytimeStress.highBandFloor }
    private var low: Double { DaytimeStress.squash(0) }

    func testThresholdEqualsDaytimeStressHighBand() {
        XCTAssertEqual(SleepStressShare.highBandFloor, DaytimeStress.highBandFloor)
    }

    func testInjectedLevelsRecoverTheShare() {
        XCTAssertEqual(SleepStressShare.percent(levels: [low, low, low, low]) ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(SleepStressShare.percent(levels: [high, low, low, low]) ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(SleepStressShare.percent(levels: [high, low, high, low]) ?? -1, 50, accuracy: 1e-9)
        XCTAssertEqual(SleepStressShare.percent(levels: [high, high, high, low]) ?? -1, 75, accuracy: 1e-9)
        XCTAssertEqual(SleepStressShare.percent(levels: [high, high, high, high]) ?? -1, 100, accuracy: 1e-9)
    }

    func testExactHighBandFloorCountsAsHigh() {
        XCTAssertEqual(
            SleepStressShare.percent(levels: [DaytimeStress.highBandFloor]) ?? -1,
            100, accuracy: 1e-9)
    }

    func testFlatNightRecovers0() {
        let means: [Double?] = [58, 58, 58, 58]
        XCTAssertEqual(SleepStressShare.percent(meanHRs: means) ?? -1, 0, accuracy: 1e-9)
    }

    func testScoredMeanHRsRecover25And50() {
        // Night-relative scoring: lower-quartile HR as calm, across-window SD as spread.
        // Three calm + one spike → the spike is HIGH (25 %). Two and two → 50 %.
        let quarter: [Double?] = [60, 60, 60, 100]
        XCTAssertEqual(SleepStressShare.percent(meanHRs: quarter) ?? -1, 25, accuracy: 1e-9)
        let half: [Double?] = [60, 60, 100, 100]
        XCTAssertEqual(SleepStressShare.percent(meanHRs: half) ?? -1, 50, accuracy: 1e-9)
    }

    func testWindowScoreIsDaytimeStressMath() {
        let means = [60.0, 62.0, 61.0, 95.0]
        let ref = DaytimeStress.calmReference(means, calmIsLow: true)
        let sd = DaytimeStress.std(means, mean: DaytimeStress.mean(means))
        let expected = means.map {
            DaytimeStress.squash(DaytimeStress.rawScore(hr: $0, meanHR: ref, sdHR: sd,
                                                        rmssd: nil, meanRMSSD: nil, sdRMSSD: 0))
        }
        let highCount = expected.filter { $0 >= DaytimeStress.highBandFloor }.count
        let share = Double(highCount) / Double(expected.count) * 100
        let got = SleepStressShare.percent(meanHRs: means.map { Optional($0) })
        XCTAssertEqual(got ?? -1, share, accuracy: 1e-9)
    }

    func testTooFewSamplesReturnsNil() {
        XCTAssertNil(SleepStressShare.percent(levels: []))
        XCTAssertNil(SleepStressShare.percent(levels: [nil, nil]))
        XCTAssertNil(SleepStressShare.percent(meanHRs: [nil, nil]))
        XCTAssertNil(SleepStressShare.percent(hr: [], startTs: 0, endTs: 1_000))
        let thin = (0..<SleepStressShare.minWindowHRSamples() - 1).map {
            HRSample(ts: 1_000 + $0, bpm: 60)
        }
        XCTAssertNil(SleepStressShare.percent(hr: thin, startTs: 1_000,
                                              endTs: 1_000 + SleepStressShare.windowSeconds))
    }

    func testHRWindowingMatchesInjectedMeanHRs() {
        let start = 1_000
        let w = SleepStressShare.windowSeconds
        let n = SleepStressShare.minWindowHRSamples()
        var hr: [HRSample] = []
        for (i, bpm) in [60, 60, 60, 100].enumerated() {
            let t0 = start + i * w
            for k in 0..<n { hr.append(HRSample(ts: t0 + k, bpm: bpm)) }
        }
        let share = SleepStressShare.percent(hr: hr, startTs: start, endTs: start + 4 * w)
        XCTAssertEqual(share ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(share, SleepStressShare.percent(meanHRs: [60, 60, 60, 100]))
    }

    func testInvalidRangeReturnsNil() {
        let hr = [HRSample(ts: 10, bpm: 60)]
        XCTAssertNil(SleepStressShare.percent(hr: hr, startTs: 100, endTs: 100))
        XCTAssertNil(SleepStressShare.percent(hr: hr, startTs: 100, endTs: 50))
    }
}

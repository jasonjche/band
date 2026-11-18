import XCTest
@testable import StrandAnalytics

final class BandStrainTargetTests: XCTestCase {

    func testNilRecoveryIsNil() {
        XCTAssertNil(BandStrainTarget.recommend(recovery: nil, recentStrain21: [8, 9, 10]))
        XCTAssertNil(BandStrainTarget.recommend(recovery: .nan, recentStrain21: Array(repeating: 8, count: 20)))
    }

    func testLabelsAtBandEdges() {
        XCTAssertEqual(BandStrainTarget.label(recovery: 0), .restore)
        XCTAssertEqual(BandStrainTarget.label(recovery: 33), .restore)
        XCTAssertEqual(BandStrainTarget.label(recovery: 33.5), .maintain)
        XCTAssertEqual(BandStrainTarget.label(recovery: 34), .maintain)
        XCTAssertEqual(BandStrainTarget.label(recovery: 66), .maintain)
        XCTAssertEqual(BandStrainTarget.label(recovery: 67), .push)
        XCTAssertEqual(BandStrainTarget.label(recovery: 100), .push)
    }

    func testEmptyAndShortHistoryUseGeneric() {
        let empty = BandStrainTarget.recommend(recovery: 50, recentStrain21: [])
        XCTAssertEqual(empty?.personalized, false)
        XCTAssertEqual(empty?.label, .maintain)

        let short = BandStrainTarget.recommend(recovery: 80, recentStrain21: Array(repeating: 6, count: 13))
        XCTAssertEqual(short?.personalized, false)
        XCTAssertEqual(short?.label, .push)

        let generic = BandStrainTarget.genericRange(recovery: 50)
        XCTAssertEqual(empty?.range.lowerBound ?? -1, generic.lowerBound, accuracy: 1e-12)
        XCTAssertEqual(empty?.range.upperBound ?? -1, generic.upperBound, accuracy: 1e-12)
    }

    func testFourteenDaysIsPersonal() {
        let got = BandStrainTarget.recommend(recovery: 50, recentStrain21: Array(repeating: 8, count: 14))
        XCTAssertEqual(got?.personalized, true)
        XCTAssertEqual(got?.label, .maintain)
    }

    func testGenericMatchesSmoothedNoopShape() {
        let r0 = BandStrainTarget.genericRange(recovery: 0)
        XCTAssertEqual(r0.lowerBound, 4.31, accuracy: 0.05)
        XCTAssertEqual(r0.upperBound, 10.31, accuracy: 0.05)

        let r100 = BandStrainTarget.genericRange(recovery: 100)
        XCTAssertEqual(r100.lowerBound, 12.69, accuracy: 0.05)
        XCTAssertEqual(r100.upperBound, 18.69, accuracy: 0.05)

        let r33 = BandStrainTarget.genericRange(recovery: 33)
        let r34 = BandStrainTarget.genericRange(recovery: 34)
        let r66 = BandStrainTarget.genericRange(recovery: 66)
        let r67 = BandStrainTarget.genericRange(recovery: 67)
        XCTAssertLessThan(r0.lowerBound, r33.lowerBound)
        XCTAssertLessThanOrEqual(r33.lowerBound, r34.lowerBound)
        XCTAssertLessThan(r34.lowerBound, r66.lowerBound)
        XCTAssertLessThanOrEqual(r66.lowerBound, r67.lowerBound)
        XCTAssertLessThan(r67.lowerBound, r100.lowerBound)
    }

    func testFlatLowHistoryDoesNotRecommendAHighPush() throws {
        let hist = Array(repeating: 5.0, count: 30)
        for recovery in [0.0, 33, 34, 66, 67, 100] {
            let got = try XCTUnwrap(BandStrainTarget.recommend(recovery: recovery, recentStrain21: hist))
            XCTAssertTrue(got.personalized)
            XCTAssertLessThan(got.range.upperBound, 8, "recovery \(recovery)")
            XCTAssertGreaterThan(got.range.lowerBound, 3, "recovery \(recovery)")
            XCTAssertEqual(got.range.upperBound - got.range.lowerBound, BandStrainTarget.minRangeWidth, accuracy: 1e-9)
        }
    }

    func testFlatHighHistoryKeepsRestoreNearCapacity() throws {
        let hist = Array(repeating: 15.0, count: 30)
        let restore = try XCTUnwrap(BandStrainTarget.recommend(recovery: 20, recentStrain21: hist))
        XCTAssertGreaterThan(restore.range.lowerBound, 12)
        XCTAssertLessThan(restore.range.upperBound, 18)
    }

    func testVariedHistoryRangeRisesWithRecovery() throws {
        var hist: [Double] = []
        for i in 0..<42 {
            hist.append(4.0 + Double(i) * (12.0 / 41.0))
        }
        let r0 = try XCTUnwrap(BandStrainTarget.recommend(recovery: 0, recentStrain21: hist))
        let r33 = try XCTUnwrap(BandStrainTarget.recommend(recovery: 33, recentStrain21: hist))
        let r50 = try XCTUnwrap(BandStrainTarget.recommend(recovery: 50, recentStrain21: hist))
        let r67 = try XCTUnwrap(BandStrainTarget.recommend(recovery: 67, recentStrain21: hist))
        let r100 = try XCTUnwrap(BandStrainTarget.recommend(recovery: 100, recentStrain21: hist))
        XCTAssertTrue(r0.personalized)
        XCTAssertEqual(r0.label, .restore)
        XCTAssertEqual(r33.label, .restore)
        XCTAssertEqual(r50.label, .maintain)
        XCTAssertEqual(r67.label, .push)
        XCTAssertEqual(r100.label, .push)
        XCTAssertLessThanOrEqual(r0.range.lowerBound, r33.range.lowerBound)
        XCTAssertLessThanOrEqual(r33.range.lowerBound, r50.range.lowerBound)
        XCTAssertLessThanOrEqual(r50.range.lowerBound, r67.range.lowerBound)
        XCTAssertLessThanOrEqual(r67.range.lowerBound, r100.range.lowerBound)
        XCTAssertLessThan(r0.range.upperBound, r100.range.upperBound)
        XCTAssertGreaterThanOrEqual(r0.range.lowerBound, 0)
        XCTAssertLessThanOrEqual(r100.range.upperBound, 21)
        XCTAssertLessThan(r0.range.upperBound, 10, "restore stays below a hard day")
        XCTAssertGreaterThan(r67.range.upperBound, r50.range.upperBound)
    }

    func testWindowKeepsTheMostRecentDays() throws {
        let old = Array(repeating: 5.0, count: 42)
        let recent = Array(repeating: 14.0, count: 42)
        let mixed = old + recent
        let fromRecent = try XCTUnwrap(BandStrainTarget.recommend(recovery: 50, recentStrain21: recent))
        let fromMixed = try XCTUnwrap(BandStrainTarget.recommend(recovery: 50, recentStrain21: mixed))
        XCTAssertEqual(fromMixed.range.lowerBound, fromRecent.range.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(fromMixed.range.upperBound, fromRecent.range.upperBound, accuracy: 1e-9)
    }

    func testRangeAlwaysClosedAndOnScale() throws {
        let hist: [Double] = [0, 1, 4, 8, 12, 16, 20, 21, 6, 7, 9, 11, 5, 13]
        for recovery in [0.0, 33, 34, 66, 67, 100] {
            let got = try XCTUnwrap(BandStrainTarget.recommend(recovery: recovery, recentStrain21: hist))
            XCTAssertGreaterThanOrEqual(got.range.lowerBound, 0)
            XCTAssertLessThanOrEqual(got.range.upperBound, 21)
            XCTAssertGreaterThanOrEqual(got.range.upperBound, got.range.lowerBound)
            XCTAssertGreaterThanOrEqual(got.range.upperBound - got.range.lowerBound, BandStrainTarget.minRangeWidth - 1e-9)
        }
    }

    func testLoadInverseRoundTripsThroughBandStrain() throws {
        let params = try XCTUnwrap(BandStrain.bundledParams())
        for s in [0.5, 4, 8.7, 14, 18.5] {
            let L = BandStrainTarget.load(strain21: s, params: params)
            let back = BandStrain.strain(load: L, params: params)
            XCTAssertEqual(back, s, accuracy: 1e-9, "strain \(s)")
        }
        XCTAssertEqual(BandStrainTarget.load(strain21: 0, params: params), 0, accuracy: 0)
    }

    func testPercentileEdges() {
        XCTAssertTrue(BandStrainTarget.percentile([Double](), 0.5).isNaN)
        XCTAssertEqual(BandStrainTarget.percentile([7.0], 0.1), 7, accuracy: 0)
        XCTAssertEqual(BandStrainTarget.percentile([1.0, 2, 3, 4], 0), 1, accuracy: 0)
        XCTAssertEqual(BandStrainTarget.percentile([1.0, 2, 3, 4], 1), 4, accuracy: 0)
        XCTAssertEqual(BandStrainTarget.percentile([1.0, 2, 3, 4], 0.5), 2.5, accuracy: 1e-12)
    }

    func testDeterministic() {
        let hist = [4.2, 6.1, 8.8, 12.3, 5.0, 9.1, 7.4, 11.2, 6.6, 10.0, 8.0, 13.5, 4.9, 15.1, 7.7]
        let a = BandStrainTarget.recommend(recovery: 71, recentStrain21: hist)
        let b = BandStrainTarget.recommend(recovery: 71, recentStrain21: hist)
        XCTAssertEqual(a, b)
    }
}

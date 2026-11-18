import XCTest
@testable import StrandAnalytics

final class ObservedHRMaxTests: XCTestCase {

    func testFewerThanTenValuesIsNil() {
        XCTAssertNil(ObservedHRMax.estimate([]))
        XCTAssertNil(ObservedHRMax.estimate(Array(repeating: 180, count: 9)))
        XCTAssertEqual(ObservedHRMax.estimate(Array(repeating: 180, count: 10)), 180)
    }

    func testASingle240SpikeIsIgnored() {
        let inRange = Array(repeating: 160, count: 10)
        XCTAssertEqual(ObservedHRMax.estimate(inRange), 160)
        XCTAssertEqual(ObservedHRMax.estimate(inRange + [240]), 160)
        XCTAssertNotEqual(ObservedHRMax.estimate(inRange + [240]), 240)
    }

    func testOutOfRangeValuesAreDropped() {
        let inRange = Array(repeating: 170, count: 10)
        let mixed = [100, 119, 226, 250, 0, 300] + inRange
        XCTAssertEqual(ObservedHRMax.estimate(mixed), 170)
        XCTAssertNil(ObservedHRMax.estimate([100, 119, 226, 250, 180, 190, 200, 210, 220]))
    }

    func testNearestRankPercentileOnAKnownList() {
        // 100 in-range values 120...219. index = ceil(0.99 × 100) - 1 = 98 → 218.
        let values = (0..<100).map { 120 + $0 }
        XCTAssertEqual(ObservedHRMax.estimate(values), 218)
    }

    /// WHOOP workout-export max-HR column (aggregates only): 202…198 each once,
    /// 197 three times. Confirmed cluster is 197; 198 sits 1 bpm above it.
    func testWhoopExportPeaksGive198() {
        let peaks = [202, 201, 200, 199, 198, 197, 197, 197, 196, 196]
        let rest = Array(repeating: 160, count: 20)
        XCTAssertEqual(ObservedHRMax.estimate(peaks + rest), 198)
    }

    func testIsolatedSpikeAboveTheRepeatedClusterIsIgnored() {
        let peaks = [208, 202, 201, 200, 198, 197, 197, 197, 196, 196]
        let rest = Array(repeating: 160, count: 20)
        XCTAssertEqual(ObservedHRMax.estimate(peaks + rest), 198)
        XCTAssertNotEqual(ObservedHRMax.estimate(peaks + rest), 208)
    }

    func testRepeatedPeakLiftsOneBpmWhenThatNeighbourExists() {
        let peaks = [208, 202, 201, 200, 199, 199, 198, 197, 197, 197, 196, 196]
        let rest = Array(repeating: 160, count: 20)
        XCTAssertEqual(ObservedHRMax.estimate(peaks + rest), 200)
    }
}

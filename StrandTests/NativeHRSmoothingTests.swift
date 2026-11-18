import XCTest
@testable import Strand

final class NativeHRSmoothingTests: XCTestCase {

    private func points(_ values: [Double], every seconds: TimeInterval = 20,
                        from start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [NativeHourPoint] {
        values.enumerated().map { i, value in
            NativeHourPoint(time: start.addingTimeInterval(TimeInterval(i) * seconds), value: value)
        }
    }

    func testShortSeriesIsUnchanged() {
        let raw = points([80, 90])
        XCTAssertEqual(NativeHRSmoothing.smooth(raw), raw)
    }

    func testSpikeIsPulledTowardNeighbours() {
        let raw = points(Array(repeating: 80.0, count: 10) + [180] + Array(repeating: 80.0, count: 10))
        let smoothed = NativeHRSmoothing.smooth(raw, window: 60)
        let peak = smoothed.map(\.value).max() ?? 0
        // The rolling median rejects a one-sample optical spike outright.
        XCTAssertEqual(peak, 80, accuracy: 1e-9)
        XCTAssertEqual(smoothed.map(\.time), raw.map(\.time))
    }

    func testGapsAreNotBridged() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var raw = points(Array(repeating: 90.0, count: 8), every: 20, from: start)
        raw += points(Array(repeating: 140.0, count: 8), every: 20,
                      from: start.addingTimeInterval(3600))
        let smoothed = NativeHRSmoothing.smooth(raw, window: 45)
        XCTAssertEqual(smoothed.count, raw.count)
        let firstRun = smoothed.prefix(8).map(\.value)
        let secondRun = smoothed.suffix(8).map(\.value)
        XCTAssertTrue(firstRun.allSatisfy { abs($0 - 90) < 1 })
        XCTAssertTrue(secondRun.allSatisfy { abs($0 - 140) < 1 })
    }

    func testGapLimitUsesTheLargerOfWindowAndTwiceMedianSpacing() {
        let raw = points([80, 82, 84, 86], every: 20)
        XCTAssertEqual(NativeHRSmoothing.gapLimit(in: raw, window: 45), 45)
        XCTAssertEqual(NativeHRSmoothing.gapLimit(in: raw, window: 10), 40)
        XCTAssertEqual(NativeHRSmoothing.defaultWindow, 120, accuracy: 1e-9)
        XCTAssertEqual(NativeHRSmoothing.dayWindow, 600, accuracy: 1e-9)
    }

    func testDaySmoothingAveragesAPerMinuteSpike() {
        var values = Array(repeating: 70.0, count: 21)
        values[10] = 170
        let raw = points(values, every: 60)
        let smoothed = NativeHRSmoothing.smoothDay(raw)
        XCTAssertEqual(smoothed.count, raw.count)
        let peak = smoothed.map(\.value).max() ?? 0
        XCTAssertLessThan(peak, 100)
        XCTAssertGreaterThan(smoothed.map(\.value).min() ?? 0, 60)
    }
}

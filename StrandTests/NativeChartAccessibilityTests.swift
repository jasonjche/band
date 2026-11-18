import XCTest
@testable import Strand

final class NativeChartAccessibilityTests: XCTestCase {
    func testYRangePadsAFlatSeries() {
        let range = NativeChartDescriptor.yRange(of: [2, 2, 2])
        XCTAssertEqual(range.lowerBound, 1.5, accuracy: 1e-9)
        XCTAssertEqual(range.upperBound, 2.5, accuracy: 1e-9)
    }

    func testDownsampleKeepsEndpointsSpacing() {
        let points = (0..<20).map {
            NativeChartDescriptor.Point(xLabel: "\($0)", xValue: Double($0), y: Double($0))
        }
        let sampled = NativeChartDescriptor.downsample(points, limit: 5)
        XCTAssertEqual(sampled.count, 5)
        XCTAssertEqual(sampled.first?.xValue, 0)
        XCTAssertEqual(sampled.last?.xValue, 16)
    }
}

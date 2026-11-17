import XCTest
import CoreGraphics
@testable import Strand

final class NativeChartScrubTests: XCTestCase {

    private func hour(_ offset: TimeInterval, _ value: Double) -> NativeHourPoint {
        NativeHourPoint(time: Date(timeIntervalSince1970: offset), value: value)
    }

    func testNearestHourSnapsToClosestSample() {
        let points = [hour(0, 60), hour(300, 70), hour(600, 80)]
        let hit = NativeChartScrubMath.nearestHour(to: Date(timeIntervalSince1970: 310), in: points)
        XCTAssertEqual(hit?.value ?? -1, 70, accuracy: 1e-9)
        XCTAssertNil(NativeChartScrubMath.nearestHour(to: Date(), in: []))
    }

    func testNearestHourReturnsNilAcrossAGap() {
        let points = [hour(0, 60), hour(300, 70), hour(3_600, 80)]
        let maxGap = NativeChartScrubMath.inferredMaxGap(in: points)
        XCTAssertNotNil(maxGap)
        let inHole = Date(timeIntervalSince1970: 1_800)
        XCTAssertNil(NativeChartScrubMath.nearestHour(to: inHole, in: points, maxGap: maxGap))
        XCTAssertEqual(
            NativeChartScrubMath.nearestHour(to: Date(timeIntervalSince1970: 290), in: points, maxGap: maxGap)?.value ?? -1,
            70,
            accuracy: 1e-9
        )
    }

    func testInferredMaxGapIsOneAndAHalfSmallestAdjacentGap() {
        let points = [hour(0, 1), hour(100, 1), hour(200, 1), hour(800, 1)]
        XCTAssertEqual(NativeChartScrubMath.inferredMaxGap(in: points) ?? -1, 150, accuracy: 1e-9)
        XCTAssertNil(NativeChartScrubMath.inferredMaxGap(in: [hour(0, 1)]))
    }

    func testNearestBucketSkipsEmptySlot() {
        let filled = NativeScopeBucket(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            value: 12,
            low: nil, high: nil, isPartial: false, sampleCount: 1, key: "2026-11-10"
        )
        let gap = NativeScopeBucket(
            start: Date(timeIntervalSince1970: 86_400),
            end: Date(timeIntervalSince1970: 172_800),
            value: nil,
            low: nil, high: nil, isPartial: false, sampleCount: 0, key: "2026-11-11"
        )
        XCTAssertEqual(
            NativeChartScrubMath.nearestBucket(to: Date(timeIntervalSince1970: 1_000), in: [filled, gap])?.key,
            "2026-11-10"
        )
        XCTAssertNil(NativeChartScrubMath.nearestBucket(to: Date(timeIntervalSince1970: 90_000), in: [filled, gap]))
        XCTAssertNil(NativeChartScrubMath.nearestBucket(to: Date(), in: []))
    }

    func testFinitePointIgnoresGaps() {
        let points = [
            NativeDayPoint(key: "2026-11-10", value: 7),
            NativeDayPoint(key: "2026-11-11", value: .nan),
        ]
        XCTAssertEqual(NativeChartScrubMath.finitePoint(key: "2026-11-10", in: points)?.value ?? -1, 7, accuracy: 1e-9)
        XCTAssertNil(NativeChartScrubMath.finitePoint(key: "2026-11-11", in: points))
        XCTAssertNil(NativeChartScrubMath.finitePoint(key: "2026-11-12", in: points))
    }

    func testBarOpacityDimsUnselectedWhileScrubbing() {
        XCTAssertEqual(NativeChartScrubMath.barOpacity(isSelected: true, hasSelection: true), 1, accuracy: 1e-9)
        XCTAssertEqual(NativeChartScrubMath.barOpacity(isSelected: false, hasSelection: true), 0.35, accuracy: 1e-9)
        XCTAssertEqual(NativeChartScrubMath.barOpacity(isSelected: false, hasSelection: false), 1, accuracy: 1e-9)
    }

    func testHorizontalScrubVersusTap() {
        XCTAssertTrue(NativeChartScrubMath.isHorizontalScrub(translation: CGSize(width: 20, height: 4)))
        XCTAssertFalse(NativeChartScrubMath.isHorizontalScrub(translation: CGSize(width: 4, height: 20)))
        XCTAssertFalse(NativeChartScrubMath.isHorizontalScrub(translation: CGSize(width: 4, height: 2)))
        XCTAssertTrue(NativeChartScrubMath.isTap(translation: CGSize(width: 2, height: 2)))
        XCTAssertFalse(NativeChartScrubMath.isTap(translation: CGSize(width: 20, height: 0)))
    }

    func testHypnogramSpanOpacityHighlightsSelection() {
        let awake = NativeSleepStageSpan(startTs: 0, endTs: 100, name: "Awake")
        let light = NativeSleepStageSpan(startTs: 100, endTs: 400, name: "Light")
        XCTAssertEqual(NativeSleepHypnogramMath.spanOpacity(span: awake, selected: nil, highlight: nil), 1, accuracy: 1e-9)
        XCTAssertEqual(NativeSleepHypnogramMath.spanOpacity(span: awake, selected: light, highlight: nil), 0.18, accuracy: 1e-9)
        XCTAssertEqual(NativeSleepHypnogramMath.spanOpacity(span: light, selected: light, highlight: nil), 1, accuracy: 1e-9)
        XCTAssertEqual(NativeSleepHypnogramMath.spanOpacity(span: light, selected: nil, highlight: .awake), 0.18, accuracy: 1e-9)
        XCTAssertEqual(NativeSleepHypnogramMath.spanOpacity(span: awake, selected: nil, highlight: .awake), 1, accuracy: 1e-9)
    }
}

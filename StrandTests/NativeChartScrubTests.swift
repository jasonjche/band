import XCTest
import CoreGraphics
import WhoopProtocol
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

    func testInferredMaxGapKeepsFiveMinuteBucketsWhenLiveTailIsCloser() {
        var points: [NativeHourPoint] = []
        for index in 0..<6 {
            points.append(hour(TimeInterval(index * 300), 60))
        }
        points.append(hour(5 * 300 + 90, 72))
        let maxGap = NativeChartScrubMath.inferredMaxGap(in: points) ?? -1
        XCTAssertEqual(maxGap, 450, accuracy: 1e-9)
        let betweenBuckets = Date(timeIntervalSince1970: 300 + 140)
        XCTAssertEqual(
            NativeChartScrubMath.nearestHour(to: betweenBuckets, in: points, maxGap: maxGap)?.time.timeIntervalSince1970 ?? -1,
            300,
            accuracy: 1e-9
        )
    }

    func testUnitCenterIsTheBarXSwiftChartsUses() {
        let start = Date(timeIntervalSince1970: 0)
        let end = Date(timeIntervalSince1970: 86_400)
        XCTAssertEqual(
            NativeChartScrubMath.unitCenter(start: start, end: end).timeIntervalSince1970,
            43_200,
            accuracy: 1e-9
        )
        let origin = CGPoint(x: 12, y: 16)
        let overlay = NativeChartScrubMath.overlayPoint(plotOrigin: origin, x: 40, y: 80)
        XCTAssertEqual(overlay.x, 52, accuracy: 1e-9)
        XCTAssertEqual(overlay.y, 96, accuracy: 1e-9)
    }

    func testDayBarsSnapToUnitCenterNotNextDayStart() {
        let filled = NativeScopeBucket(
            start: Date(timeIntervalSince1970: 0),
            end: Date(timeIntervalSince1970: 86_400),
            value: 12,
            low: nil, high: nil, isPartial: false, sampleCount: 1, key: "2026-11-10"
        )
        let next = NativeScopeBucket(
            start: Date(timeIntervalSince1970: 86_400),
            end: Date(timeIntervalSince1970: 172_800),
            value: 20,
            low: nil, high: nil, isPartial: false, sampleCount: 1, key: "2026-11-11"
        )
        let lateInFirstDay = Date(timeIntervalSince1970: 80_000)
        XCTAssertEqual(
            NativeChartScrubMath.nearestBucket(to: lateInFirstDay, in: [filled, next])?.key,
            "2026-11-10"
        )
        let bar = NativeChartScrubMath.snapBucket(date: lateInFirstDay, buckets: [filled, next], bars: true)
        XCTAssertEqual(bar?.key, "2026-11-10")
        XCTAssertEqual(bar?.time.timeIntervalSince1970 ?? -1, 43_200, accuracy: 1)
        let line = NativeChartScrubMath.snapBucket(date: lateInFirstDay, buckets: [filled, next], bars: false)
        XCTAssertEqual(line?.time.timeIntervalSince1970 ?? -1, 0, accuracy: 1)
    }

    func testHourlyStepBarsSnapToUnitCenterNotNextHourStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let ten = Int(start.timeIntervalSince1970) + 10 * 3600
        let eleven = Int(start.timeIntervalSince1970) + 11 * 3600
        let points = NativeResolvedSteps.hourPoints(
            appleHours: [(ts: ten, steps: 800), (ts: eleven, steps: 200)],
            dayStart: start,
            calendar: calendar,
            preferApple: true
        )
        XCTAssertEqual(points.count, 24)
        let finger = start.addingTimeInterval(10 * 3600 + 50 * 60)
        let hit = NativeChartScrubMath.nearestCentered(
            to: finger,
            in: points,
            duration: NativeChartScrubMath.hourDuration
        )
        XCTAssertEqual(hit?.time, points[10].time)
        XCTAssertEqual(hit?.value ?? -1, 800, accuracy: 0.1)
        XCTAssertEqual(
            NativeChartScrubMath.nearestHour(to: finger, in: points)?.time,
            points[11].time,
            "comparing to hour starts is the offset-bar bug"
        )
        let snapped = NativeChartScrubMath.snapHour(date: finger, points: points, calendar: calendar)
        let center = NativeChartScrubMath.selectionDate(forHour: points[10].time, calendar: calendar)
        XCTAssertEqual(snapped?.timeIntervalSince1970 ?? -1, center.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(
            NativeChartScrubMath.barOpacity(isSelected: true, hasSelection: true),
            1,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            NativeChartScrubMath.barOpacity(isSelected: false, hasSelection: true),
            0.35,
            accuracy: 1e-9
        )
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

    func testEmphasizedKeyPrefersScrubThenPageDayAndIgnoresAxisLabels() {
        let keys = NativeWeek.lastSevenKeys(ending: "2026-11-12")
        XCTAssertEqual(keys, [
            "2026-11-06", "2026-11-07", "2026-11-08", "2026-11-09",
            "2026-11-10", "2026-11-11", "2026-11-12",
        ])
        XCTAssertEqual(NativeChartDay.weekday("2026-11-12"), "Thu")
        XCTAssertEqual(NativeChartDay.weekday("2026-11-07"), "Sat")
        XCTAssertEqual(
            NativeChartScrubMath.emphasizedKey(selected: nil, highlight: "2026-11-12", keys: keys),
            "2026-11-12"
        )
        XCTAssertEqual(
            NativeChartScrubMath.highlightIndex(keys: keys, emphasized: "2026-11-12"),
            6
        )
        XCTAssertEqual(
            NativeChartScrubMath.highlightIndex(keys: keys, emphasized: "2026-11-07"),
            1
        )
        XCTAssertEqual(
            NativeChartScrubMath.emphasizedKey(selected: "7", highlight: "2026-11-12", keys: keys),
            "2026-11-12"
        )
        XCTAssertEqual(
            NativeChartScrubMath.emphasizedKey(selected: "2026-11-07", highlight: "2026-11-12", keys: keys),
            "2026-11-07"
        )
    }

    func testHRDisplaySmoothsTheLineAndLeavesRawStats() {
        let raw = (0..<24).map { index in
            NativeHourPoint(
                time: Date(timeIntervalSince1970: Double(index) * 10),
                value: index.isMultiple(of: 2) ? 60 : 120
            )
        }
        let line = NativeHRDisplay.line(raw)
        let rawMean = NativeScoreMath.mean(raw.map(\.value)) ?? -1
        XCTAssertEqual(rawMean, 90, accuracy: 1e-9)
        XCTAssertEqual(line.count, raw.count)
        XCTAssertNotEqual(line.map(\.value), raw.map(\.value))
        XCTAssertEqual(
            NativeScoreMath.mean(raw.map(\.value)) ?? -1,
            rawMean,
            accuracy: 1e-9,
            "stats stay on the unsmoothed series"
        )
    }

    func testOvernightHeartPointsKeepEvenSamplesForTheChart() {
        let samples = (0..<6).map { HRSample(ts: $0 * 10, bpm: 50 + $0) }
        let points = NativeOvernightHeart.points(from: samples, every: 2, cap: 8_000)
        XCTAssertEqual(points.map(\.value), [50, 52, 54])
        XCTAssertEqual(
            NativeScoreMath.mean(points.map(\.value)) ?? -1,
            52,
            accuracy: 1e-9
        )
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

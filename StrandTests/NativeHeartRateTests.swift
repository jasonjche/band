import XCTest
@testable import Strand

final class NativeHeartRateTests: XCTestCase {

    private func points(_ values: [Double], every seconds: TimeInterval = 60,
                        from start: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> [NativeHourPoint] {
        values.enumerated().map { i, value in
            NativeHourPoint(time: start.addingTimeInterval(TimeInterval(i) * seconds), value: value)
        }
    }

    func testDownsampleCapsAtBudgetAndPreservesSpan() {
        let raw = points((0..<1_000).map { 60 + Double($0 % 40) }, every: 60)
        XCTAssertGreaterThan(raw.count, NativeHeartRateMath.drawBudget)
        let drawn = NativeHeartRateMath.downsample(raw, maxPoints: 300)
        XCTAssertLessThanOrEqual(drawn.count, 300)
        XCTAssertGreaterThan(drawn.count, 100)
        XCTAssertLessThan(abs(drawn.first!.time.timeIntervalSince(raw.first!.time)), 600)
        let rawSpan = raw.last!.time.timeIntervalSince(raw.first!.time)
        let drawnSpan = drawn.last!.time.timeIntervalSince(drawn.first!.time)
        XCTAssertEqual(drawnSpan, rawSpan, accuracy: rawSpan * 0.05)
        XCTAssertEqual(NativeHeartRateMath.downsample(Array(raw.prefix(10)), maxPoints: 300).count, 10)
    }

    func testDownsampleMeanTracksTheSource() {
        let raw = points(Array(repeating: 72.0, count: 1_200) + Array(repeating: 140.0, count: 1_200), every: 10)
        let drawn = NativeHeartRateMath.downsample(raw, maxPoints: 200)
        XCTAssertLessThanOrEqual(drawn.count, 200)
        let firstHalf = drawn.prefix(drawn.count / 3).map(\.value)
        let secondHalf = drawn.suffix(drawn.count / 3).map(\.value)
        XCTAssertEqual(NativeScoreMath.mean(firstHalf) ?? 0, 72, accuracy: 2)
        XCTAssertEqual(NativeScoreMath.mean(secondHalf) ?? 0, 140, accuracy: 2)
    }

    func testFittedDomainPadsAndDoesNotStartAtZero() {
        let domain = NativeHeartRateMath.fittedDomain([62, 70, 78])
        XCTAssertLessThan(domain.lowerBound, 62)
        XCTAssertGreaterThan(domain.upperBound, 78)
        XCTAssertGreaterThan(domain.lowerBound, 20)
        let flat = NativeHeartRateMath.fittedDomain([70, 70, 70])
        XCTAssertLessThan(flat.lowerBound, 70)
        XCTAssertGreaterThan(flat.upperBound, 70)
        XCTAssertEqual(NativeHeartRateMath.fittedDomain([]), 40...180)
    }

    func testSparkKeepsTheLastFewHours() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let now = start.addingTimeInterval(8 * 3600)
        var values: [Double] = []
        for i in 0..<(8 * 60) { values.append(60 + Double(i % 20)) }
        let raw = points(values, every: 60, from: start)
        let spark = NativeHeartRateMath.spark(from: raw, now: now, span: 4 * 3600)
        XCTAssertFalse(spark.isEmpty)
        XCTAssertGreaterThanOrEqual(spark.first!.time, now.addingTimeInterval(-4 * 3600 - 60))
        XCTAssertLessThan(spark.first!.time, now.addingTimeInterval(-3 * 3600))
        XCTAssertLessThanOrEqual(spark.count, NativeHeartRateMath.drawBudget)
    }

    func testAppendLiveReplacesTheTailThenExtendsAfterAGap() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let series = points([70, 72, 74], every: 60, from: start)
        let replaced = NativeHeartRateMath.appendLive(series, bpm: 80, at: start.addingTimeInterval(120 + 10))
        XCTAssertEqual(replaced.count, 3)
        XCTAssertEqual(replaced.last?.value ?? 0, 80, accuracy: 1e-9)
        let extended = NativeHeartRateMath.appendLive(series, bpm: 90, at: start.addingTimeInterval(120 + 200))
        XCTAssertEqual(extended.count, 4)
        XCTAssertEqual(extended.last?.value ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(NativeHeartRateMath.appendLive([], bpm: 64, at: start).map(\.value), [64])
        XCTAssertEqual(NativeHeartRateMath.appendLive(series, bpm: nil, at: start).count, 3)
    }

    func testStatsUseExtremaNotTheBucketMean() {
        let stats = NativeHeartRateMath.stats(
            values: [80, 90, 100],
            extrema: [(min: 55, max: 90), (min: 88, max: 170)],
            restingBpm: 52
        )
        XCTAssertEqual(stats.minBpm ?? 0, 55, accuracy: 1e-9)
        XCTAssertEqual(stats.maxBpm ?? 0, 170, accuracy: 1e-9)
        XCTAssertEqual(stats.avgBpm ?? 0, 90, accuracy: 1e-9)
        XCTAssertEqual(stats.restingBpm, 52)
    }

    func testBucketSecondsKeepsADayUnderTheDrawBudget() {
        XCTAssertEqual(NativeHeartRateMath.bucketSeconds(span: 86_400, maxPoints: 300), 288)
        XCTAssertEqual(NativeHeartRateMath.bucketSeconds(span: 3_600, maxPoints: 300), 60)
        XCTAssertEqual(NativeHeartRateMath.bucketSeconds(span: 0), 60)
    }

    func testAppendLiveToModelKeepsAFittedDomain() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let model = NativeHeartRateMath.make(
            points: points([70, 72, 74], every: 60, from: start),
            minBpm: 70, maxBpm: 74, avgBpm: 72, restingBpm: 50,
            sleepStart: nil, sleepEnd: nil, dayStart: start,
            now: start.addingTimeInterval(180), viewingToday: true
        )
        let inside = NativeHeartRateMath.appendLive(to: model, bpm: 73, at: start.addingTimeInterval(190))
        XCTAssertEqual(inside.yDomain.lowerBound, model.yDomain.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(inside.plot.last?.value ?? 0, 73, accuracy: 1e-9)
        let outside = NativeHeartRateMath.appendLive(to: model, bpm: 160, at: start.addingTimeInterval(190))
        XCTAssertGreaterThan(outside.yDomain.upperBound, model.yDomain.upperBound)
    }

    func testMakeFitsThePlotAndMarksToday() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = points([60, 90, 80, 70], every: 300, from: start)
        let now = start.addingTimeInterval(1_200)
        let model = NativeHeartRateMath.make(
            points: raw,
            minBpm: 58,
            maxBpm: 110,
            avgBpm: 75,
            restingBpm: 51,
            sleepStart: start,
            sleepEnd: start.addingTimeInterval(600),
            dayStart: start,
            now: now,
            viewingToday: true
        )
        XCTAssertEqual(model.plot.count, 4)
        XCTAssertEqual(model.stats.minBpm ?? 0, 58, accuracy: 1e-9)
        XCTAssertEqual(model.stats.maxBpm ?? 0, 110, accuracy: 1e-9)
        XCTAssertEqual(model.stats.restingBpm, 51)
        XCTAssertTrue(model.showsNow)
        XCTAssertGreaterThan(model.yDomain.lowerBound, 20)
        XCTAssertGreaterThan(model.yDomain.upperBound, model.yDomain.lowerBound)
        let past = NativeHeartRateMath.make(
            points: raw, minBpm: nil, maxBpm: nil, avgBpm: nil, restingBpm: nil,
            sleepStart: nil, sleepEnd: nil, dayStart: start,
            now: start.addingTimeInterval(2 * 86_400), viewingToday: false
        )
        XCTAssertFalse(past.showsNow)
    }
}

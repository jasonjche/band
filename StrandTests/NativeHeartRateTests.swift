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

    func testMakeStatsStayOnRawWhileThePlotIsSmoothed() {
        var values = Array(repeating: 70.0, count: 21)
        values[10] = 170
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = points(values, every: 60, from: start)
        let model = NativeHeartRateMath.make(
            points: raw,
            minBpm: 49, maxBpm: 170, avgBpm: 80, restingBpm: 52,
            sleepStart: nil, sleepEnd: nil, dayStart: start,
            now: start.addingTimeInterval(1_200), viewingToday: true
        )
        XCTAssertEqual(model.stats.minBpm ?? 0, 49, accuracy: 1e-9)
        XCTAssertEqual(model.stats.maxBpm ?? 0, 170, accuracy: 1e-9)
        XCTAssertLessThan(model.plot.map(\.value).max() ?? 0, 100)
    }

    func testXAxisDatesAreRoundHours() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        let afternoon = NativeHeartRateMath.xAxisDates(
            dayStart: start,
            plotEnd: start.addingTimeInterval(16.4 * 3600),
            calendar: cal
        )
        XCTAssertEqual(afternoon.map { cal.component(.hour, from: $0) }, [0, 6, 12])
        XCTAssertTrue(afternoon.allSatisfy { cal.component(.minute, from: $0) == 0 })
        let full = NativeHeartRateMath.xAxisDates(
            dayStart: start,
            plotEnd: start.addingTimeInterval(86_400),
            calendar: cal
        )
        XCTAssertEqual(full.map { cal.component(.hour, from: $0) }, [0, 6, 12, 18])
        let morning = NativeHeartRateMath.xAxisDates(
            dayStart: start,
            plotEnd: start.addingTimeInterval(8 * 3600),
            calendar: cal
        )
        XCTAssertEqual(morning.map { cal.component(.hour, from: $0) }, [0, 3, 6])
    }

    func testHeroDateIsLatestUnlessScrubbing() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let time = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 16, minute: 22))!
        XCTAssertEqual(NativeHeartRateMath.heroDate(isScrubbing: false, time: time, calendar: cal), "Latest")
        XCTAssertEqual(NativeHeartRateMath.heroDate(isScrubbing: true, time: time, calendar: cal), "4:22 PM")
    }

    func testClippedPlotAndSleepStayInsideTheDomain() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let domain = start...start.addingTimeInterval(3_600)
        let raw = [
            NativeHourPoint(time: start.addingTimeInterval(-60), value: 50),
            NativeHourPoint(time: start.addingTimeInterval(120), value: 70),
            NativeHourPoint(time: start.addingTimeInterval(4_000), value: 90),
        ]
        XCTAssertEqual(NativeHeartRateMath.clippedPlot(raw, xDomain: domain).map(\.value), [70])
        XCTAssertEqual(
            NativeHeartRateMath.clippedPlot(raw, xDomain: domain, yDomain: 60...80).map(\.value),
            [70]
        )
        let sleep = NativeHeartRateMath.clippedSleep(
            start: start.addingTimeInterval(-600),
            end: start.addingTimeInterval(7_200),
            xDomain: domain
        )
        XCTAssertEqual(sleep?.0, domain.lowerBound)
        XCTAssertEqual(sleep?.1, domain.upperBound)
    }

    func testSparkDomainContainsTheMarks() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let raw = points([70, 72, 74], every: 60, from: start)
        let domain = NativeHeartRateMath.sparkXDomain(points: raw, now: start.addingTimeInterval(180))
        XCTAssertEqual(domain.lowerBound, raw.first?.time)
        XCTAssertEqual(domain.upperBound, raw.last?.time)
        XCTAssertEqual(NativeHeartRateMath.clippedPlot(raw, xDomain: domain).count, 3)
    }

    func testPlotModelRespectsBudgetPreservesGapsAndBucketRange() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let gapped = points([70, 71, 72], every: 60, from: start)
            + points([90, 91, 92], every: 60, from: start.addingTimeInterval(3 * 3600))
        XCTAssertEqual(NativeHeartRateMath.splitGaps(gapped).count, 2)
        XCTAssertEqual(NativeHeartRateMath.splitGaps(points([70, 72, 74], every: 60, from: start)).count, 1)

        var raw: [NativeHourPoint] = []
        raw.reserveCapacity(1_440)
        for i in 0..<(3 * 60) {
            raw.append(NativeHourPoint(
                time: start.addingTimeInterval(TimeInterval(i) * 60),
                value: 60 + Double(i % 21)
            ))
        }
        let evening = start.addingTimeInterval(8 * 3600)
        for i in 0..<(3 * 60) {
            raw.append(NativeHourPoint(
                time: evening.addingTimeInterval(TimeInterval(i) * 60),
                value: 100 + Double(i % 21)
            ))
        }
        let model = NativeHeartRateMath.make(
            points: raw,
            minBpm: 49, maxBpm: 170, avgBpm: 80, restingBpm: 52,
            sleepStart: start, sleepEnd: start.addingTimeInterval(6 * 3600),
            dayStart: start,
            now: start.addingTimeInterval(12 * 3600),
            viewingToday: true
        )
        XCTAssertLessThanOrEqual(model.plot.count, NativeHeartRateMath.drawBudget)
        XCTAssertLessThanOrEqual(model.domainPoints.count, NativeHeartRateMath.drawBudget)
        XCTAssertEqual(model.segments.count, 2)
        XCTAssertEqual(model.segments.reduce(0) { $0 + $1.count }, model.domainPoints.count)
        let morningEnd = start.addingTimeInterval(TimeInterval(3 * 60 - 1) * 60)
        let holeLo = morningEnd.addingTimeInterval(30 * 60)
        let holeHi = evening.addingTimeInterval(-30 * 60)
        XCTAssertTrue(model.plot.allSatisfy { $0.time < holeLo || $0.time > holeHi })
        XCTAssertEqual(model.xDomain, model.dayStart...model.plotEnd)
        XCTAssertEqual(
            model.sleepVisible?.start,
            NativeHeartRateMath.clippedSleep(
                start: model.sleepStart, end: model.sleepEnd, xDomain: model.xDomain
            )?.0
        )

        let dense = (0..<2_000).map { index -> NativeHourPoint in
            let value = index < 1_000 ? Double(40 + index % 10) : Double(140 + index % 10)
            return NativeHourPoint(time: start.addingTimeInterval(TimeInterval(index)), value: value)
        }
        let budget = 80
        let drawn = NativeHeartRateMath.downsample(dense, maxPoints: budget)
        XCTAssertLessThanOrEqual(drawn.count, budget)
        let first = dense.first!.time
        let width = dense.last!.time.timeIntervalSince(first) / Double(budget)
        var mins = [Double](repeating: .infinity, count: budget)
        var maxs = [Double](repeating: -.infinity, count: budget)
        for point in dense {
            let key = min(budget - 1, Int(point.time.timeIntervalSince(first) / width))
            mins[key] = min(mins[key], point.value)
            maxs[key] = max(maxs[key], point.value)
        }
        for point in drawn {
            let key = min(
                budget - 1,
                max(0, Int(((point.time.timeIntervalSince(first) - width / 2) / width).rounded()))
            )
            XCTAssertGreaterThanOrEqual(point.value, mins[key] - 1e-9)
            XCTAssertLessThanOrEqual(point.value, maxs[key] + 1e-9)
        }
    }
}

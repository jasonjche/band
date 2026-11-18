import XCTest
@testable import StrandAnalytics

final class HRVTrendTests: XCTestCase {

    private let start = "2024-01-01"

    func testConstantSeriesStaysWithinNormal() {
        let nights = series(count: 80, rmssd: 60)
        let last = HRVTrend.evaluate(nights: nights).last
        XCTAssertEqual(last?.state, .withinNormal)
        XCTAssertEqual(last?.trendNights, 7)
        XCTAssertEqual(last?.baselineNights, 60)
        XCTAssertEqual(last?.swc ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(last?.trendLn ?? 0, log(60), accuracy: 1e-12)
        XCTAssertEqual(last?.baselineLn ?? 0, log(60), accuracy: 1e-12)
    }

    func testSWCIsHalfBaselineSD() {
        // 60 nights of two alternating values so SD is known, then a matching
        // 7-day window so the state is judged.
        var values = [Double]()
        for i in 0..<60 { values.append(i % 2 == 0 ? 50 : 80) }
        let nights = zip(days(60), values).map { HRVTrend.Night(day: $0, rmssdMs: $1) }
        let result = HRVTrend.evaluate(nights: nights).last!
        let lns = values.map { log($0) }
        let mu = lns.reduce(0, +) / 60.0
        var ss = 0.0
        for v in lns { let d = v - mu; ss += d * d }
        let sd = sqrt(ss / 59.0)
        XCTAssertEqual(result.swc ?? -1, 0.5 * sd, accuracy: 1e-12)
        XCTAssertEqual(result.baselineLn ?? -1, mu, accuracy: 1e-12)
        XCTAssertEqual(result.bandLow ?? -1, mu - 0.5 * sd, accuracy: 1e-12)
        XCTAssertEqual(result.bandHigh ?? -1, mu + 0.5 * sd, accuracy: 1e-12)
    }

    func testSustainedDropIsTrendingBelow() {
        var nights = series(count: 60, rmssd: 70)
        nights += series(count: 7, rmssd: 35, start: "2024-03-01")
        let last = HRVTrend.evaluate(nights: nights).last
        XCTAssertEqual(last?.state, .trendingBelow)
        XCTAssertLessThan(last?.trendLn ?? 0, last?.bandLow ?? 0)
    }

    func testSustainedRiseIsTrendingAbove() {
        var nights = series(count: 60, rmssd: 40)
        nights += series(count: 7, rmssd: 80, start: "2024-03-01")
        let last = HRVTrend.evaluate(nights: nights).last
        XCTAssertEqual(last?.state, .trendingAbove)
        XCTAssertGreaterThan(last?.trendLn ?? 0, last?.bandHigh ?? 0)
    }

    func testMissingNightsAreSkippedNotZeroFilled() {
        var nights = series(count: 60, rmssd: 60)
        // Punch four holes in the last week. Remaining 3 valid nights still
        // meet minTrendNights; zero-filling would pull ln toward -inf / 0 ms.
        let last7 = Array(nights.suffix(7))
        for i in 0..<4 {
            nights[nights.count - 7 + i] = HRVTrend.Night(day: last7[i].day, rmssdMs: nil)
        }
        let skipped = HRVTrend.evaluate(nights: nights).last!
        XCTAssertEqual(skipped.trendNights, 3)
        XCTAssertEqual(skipped.state, .withinNormal)
        XCTAssertEqual(skipped.trendLn ?? 0, log(60), accuracy: 1e-12)

        var filled = series(count: 60, rmssd: 60)
        for i in 0..<4 {
            filled[filled.count - 7 + i] = HRVTrend.Night(day: last7[i].day, rmssdMs: 1.0001)
        }
        let zeroish = HRVTrend.evaluate(nights: filled).last!
        XCTAssertLessThan(zeroish.trendLn ?? 0, skipped.trendLn ?? 0)
    }

    func testFewerThanThreeTrendNightsIsBuilding() {
        var nights = series(count: 60, rmssd: 60)
        let last7 = Array(nights.suffix(7))
        for i in 0..<5 {
            nights[nights.count - 7 + i] = HRVTrend.Night(day: last7[i].day, rmssdMs: nil)
        }
        let last = HRVTrend.evaluate(nights: nights).last
        XCTAssertEqual(last?.trendNights, 2)
        XCTAssertEqual(last?.state, .building)
    }

    func testThinBaselineIsBuilding() {
        let nights = series(count: 20, rmssd: 60)
        let last = HRVTrend.evaluate(nights: nights).last
        XCTAssertEqual(last?.state, .building)
        XCTAssertLessThan(last?.baselineNights ?? 99, HRVTrend.minBaselineNights)
    }

    func testSevenDayCVIsDayToDayStability() {
        var values: [Double] = Array(repeating: 60, count: 53)
        values += [40, 80, 40, 80, 40, 80, 40]
        let nights = zip(days(60), values).map { HRVTrend.Night(day: $0, rmssdMs: $1) }
        let last = HRVTrend.evaluate(nights: nights).last!
        let week = values.suffix(7).map { log($0) }
        let cv = HRVTrend.coefficientOfVariation(Array(week))
        XCTAssertEqual(last.trendCV ?? -1, cv ?? -2, accuracy: 1e-12)
        XCTAssertGreaterThan(last.trendCV ?? 0, 0.05)
    }

    func testLnSkipsNonPositiveRmssd() {
        XCTAssertNil(HRVTrend.lnRmssd(nil))
        XCTAssertNil(HRVTrend.lnRmssd(0))
        XCTAssertNil(HRVTrend.lnRmssd(1))
        XCTAssertNil(HRVTrend.lnRmssd(-4))
        XCTAssertEqual(HRVTrend.lnRmssd(60) ?? 0, log(60), accuracy: 1e-12)
    }

    func testDuplicateDaysKeepLastAndSort() {
        let nights = [
            HRVTrend.Night(day: "2024-03-10", rmssdMs: 40),
            HRVTrend.Night(day: "2024-03-01", rmssdMs: 60),
            HRVTrend.Night(day: "2024-03-10", rmssdMs: 70),
        ]
        let eval = HRVTrend.evaluate(nights: nights)
        XCTAssertEqual(eval.map(\.day), ["2024-03-01", "2024-03-10"])
        XCTAssertEqual(eval.last?.rmssdMs, 70)
    }

    func testTrendMsIsExpOfLnMean() {
        let nights = series(count: 70, rmssd: 55)
        let last = HRVTrend.evaluate(nights: nights).last!
        XCTAssertEqual(last.trendMs ?? 0, 55, accuracy: 1e-9)
        XCTAssertEqual(last.baselineMs ?? 0, 55, accuracy: 1e-9)
    }

    private func days(_ count: Int, start: String? = nil) -> [String] {
        var key = start ?? self.start
        var out: [String] = []
        for _ in 0..<count {
            out.append(key)
            key = BandDayKey.addDays(key, 1) ?? key
        }
        return out
    }

    private func series(count: Int, rmssd: Double, start: String? = nil) -> [HRVTrend.Night] {
        days(count, start: start).map { HRVTrend.Night(day: $0, rmssdMs: rmssd) }
    }
}

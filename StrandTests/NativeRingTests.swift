import XCTest
@testable import Strand

final class NativeRingTests: XCTestCase {

    func testClampedFractionIsZeroToOne() {
        XCTAssertEqual(NativeRingMotion.clamped(nil), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(-0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(0), 0, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(0.42), 0.42, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(1), 1, accuracy: 1e-9)
        XCTAssertEqual(NativeRingMotion.clamped(1.4), 1, accuracy: 1e-9)
    }

    func testTargetTickSitsAtTheMidpoint() {
        XCTAssertEqual(NativeRingMotion.targetTick(from: 0.4...0.6), 0.5, accuracy: 1e-12)
        XCTAssertEqual(NativeRingMotion.targetTickSpan, 0.018, accuracy: 1e-12)
        XCTAssertEqual(NativeRingMotion.targetTick(from: 0.8...0.8), 0.8, accuracy: 1e-12)
    }
}

final class NativeChartTicksTests: XCTestCase {
    func testNiceStepsZeroBasedCounts() {
        XCTAssertEqual(
            NativeChartTicks.nice(min: 0, max: 11_000, targetCount: 4),
            [0, 5_000, 10_000, 15_000]
        )
        XCTAssertEqual(
            NativeChartTicks.nice(min: 0, max: 713, targetCount: 4),
            [0, 250, 500, 750]
        )
    }

    func testNiceHRVCoversDataWithRoundSteps() {
        XCTAssertEqual(
            NativeChartTicks.nice(min: 70, max: 110, targetCount: 4),
            [60, 80, 100, 120]
        )
    }

    func testNiceTopTickIsAtOrAboveMax() {
        let ticks = NativeChartTicks.nice(min: 0, max: 8_202, targetCount: 4)
        XCTAssertEqual(ticks.first, 0)
        XCTAssertGreaterThanOrEqual(ticks.last ?? 0, 8_202)
    }

    func testPercentTicksStayFixed() {
        XCTAssertEqual(NativeChartTicks.percent, [0, 50, 100])
    }

    func testHourDatesAreOnTheHour() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: 22, minute: 53))!
        let end = cal.date(from: DateComponents(year: 2026, month: 11, day: 17, hour: 7, minute: 13))!
        let ticks = NativeChartTicks.hourDates(from: start, to: end, targetCount: 4, calendar: cal)
        XCTAssertFalse(ticks.isEmpty)
        XCTAssertLessThanOrEqual(ticks.count, 5)
        for date in ticks {
            XCTAssertEqual(cal.component(.minute, from: date), 0)
            XCTAssertGreaterThanOrEqual(date, start)
            XCTAssertLessThanOrEqual(date, end)
        }
    }

    func testDomainFromTicks() {
        XCTAssertEqual(NativeChartTicks.domain(from: [0, 250, 500, 750], fallback: 0...1), 0...750)
        XCTAssertEqual(NativeChartTicks.domain(from: [], fallback: 40...90), 40...90)
    }
}

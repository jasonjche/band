import XCTest
import StrandAnalytics
import StrandDesign
@testable import Strand

/// Aggregation, typical-range, and period-trend math for Native metric charts.
final class NativeScopeMathTests: XCTestCase {

    private func calendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 1
        return calendar
    }

    private func point(_ key: String, _ value: Double) -> NativeDayPoint {
        NativeDayPoint(key: key, value: value)
    }

    func testTypicalRangeRequires14Days() {
        XCTAssertNil(NativeTypicalRange.band(values: Array(repeating: 50, count: 13)))
        XCTAssertNotNil(NativeTypicalRange.band(values: Array(repeating: 50, count: 14)))
        XCTAssertEqual(NativeTypicalRange.minDays, Baselines.minNightsTrust)
        XCTAssertEqual(NativeTypicalRange.window, 30)
    }

    func testTypicalRangeMatchesRollingMeanSD() {
        let values: [Double?] = (0..<30).map { Double(40 + $0) }
        let band = NativeTypicalRange.band(values: values, cfg: Baselines.hrvCfg)
        let state = Baselines.rollingMeanSD(values, cfg: Baselines.hrvCfg, window: 30)
        let sig = Baselines.sigma(state)
        XCTAssertEqual(band?.lowerBound ?? .nan, state.baseline - 2 * sig, accuracy: 1e-9)
        XCTAssertEqual(band?.upperBound ?? .nan, state.baseline + 2 * sig, accuracy: 1e-9)
        XCTAssertEqual(VitalBands.sigmaK, 2.0, accuracy: 1e-9)
    }

    func testSixMonthAggregatesByWeek() {
        let cal = calendar()
        var points: [NativeDayPoint] = []
        var cursor = NativeScopeSeries.date(from: "2026-05-10", calendar: cal)!
        let end = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        while cursor <= end {
            points.append(point(NativeScopeSeries.key(from: cursor, calendar: cal), 50))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: end, ending: end
        )
        XCTAssertEqual(series.latestWindow().count, 26)
        XCTAssertTrue(series.buckets.allSatisfy { $0.sampleCount <= 7 })
        XCTAssertGreaterThan(series.buckets.count, 20)
        XCTAssertLessThan(series.buckets.count, 40)
    }

    func testTrendPercentChangeAndCaption() {
        let cal = calendar()
        let points = (1...14).map { point(String(format: "2026-11-%02d", $0), Double($0 * 10)) }
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now
        )
        let visible = Array(series.buckets.suffix(7))
        let trend = series.trend(visible: visible, higherIsBetter: true)!
        XCTAssertEqual(trend.percentChange, (trend.currentMean - trend.previousMean) / trend.previousMean, accuracy: 1e-9)
        XCTAssertEqual(series.periodDeltaCaption(of: visible, higherIsBetter: true)?.contains("vs. prior week"), true)
        XCTAssertNil(series.periodDeltaCaption(of: Array(series.buckets.suffix(2)), higherIsBetter: true))
    }
}

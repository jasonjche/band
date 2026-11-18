import XCTest
@testable import Strand

/// 6M axes printed "May" and "Jun" on top of each other when the window opened in May's last week.
final class NativeScopeAxisTests: XCTestCase {
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return cal
    }

    private func weeklyStarts(from start: String, count: Int) -> [Date] {
        let first = NativeScopeSeries.date(from: start, calendar: calendar)!
        return (0..<count).map { calendar.date(byAdding: .day, value: 7 * $0, to: first)! }
    }

    func testSixMonthsDropsALeadingMonthOneWeekBeforeTheNext() {
        let starts = weeklyStarts(from: "2026-05-25", count: 26)
        let labels = NativeScopeAxis.monthLabelDates(starts, scope: .sixMonths, calendar: calendar)
        let months = labels.map { calendar.component(.month, from: $0) }
        XCTAssertEqual(months.first, 6, "May 25 sits one week before Jun 1; Jun wins")
        XCTAssertEqual(Set(months).count, months.count)
        let indices = labels.compactMap { starts.firstIndex(of: $0) }
        for (a, b) in zip(indices, indices.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, NativeScopeAxis.minGap(for: .sixMonths))
        }
    }

    func testSixMonthsKeepsEveryMonthWhenWindowStartsEarly() {
        let starts = weeklyStarts(from: "2026-06-01", count: 26)
        let labels = NativeScopeAxis.monthLabelDates(starts, scope: .sixMonths, calendar: calendar)
        XCTAssertEqual(labels.map { calendar.component(.month, from: $0) }, [6, 7, 8, 9, 10, 11])
    }

    func testYearKeepsEveryMonthlyBucket() {
        let first = NativeScopeSeries.date(from: "2025-12-01", calendar: calendar)!
        let starts = (0..<12).map { calendar.date(byAdding: .month, value: $0, to: first)! }
        XCTAssertEqual(NativeScopeAxis.monthLabelDates(starts, scope: .year, calendar: calendar).count, 12)
    }

    func testVisibleSelectionIgnoresLookbackBuckets() {
        func bucket(_ key: String, value: Double?) -> NativeScopeBucket {
            let start = NativeScopeSeries.date(from: key, calendar: calendar)!
            return NativeScopeBucket(
                start: start,
                end: calendar.date(byAdding: .day, value: 1, to: start)!,
                value: value,
                low: nil, high: nil, isPartial: false,
                sampleCount: value == nil ? 0 : 1,
                key: key
            )
        }
        let lookback = bucket("2026-11-11", value: 14.8)
        let visible = (12...18).map { bucket(String(format: "2026-11-%02d", $0), value: 15) }
        XCTAssertNil(NativeScopeVisible.selected(key: lookback.key, in: visible))
        XCTAssertEqual(NativeScopeVisible.selected(key: "2026-11-12", in: visible)?.key, "2026-11-12")
        let last = NativeScopePlotMath.LinePoint(
            date: visible.last!.start, value: 15, segment: 0, key: visible.last!.key
        )
        XCTAssertTrue(NativeScopeVisible.isTrailing(last, visible: visible))
        XCTAssertFalse(NativeScopeVisible.isTrailing(
            NativeScopePlotMath.LinePoint(date: lookback.start, value: 14.8, segment: 0, key: lookback.key),
            visible: visible
        ))
    }
}

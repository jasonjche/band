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
}

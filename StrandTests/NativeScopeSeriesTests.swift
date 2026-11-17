import XCTest
import SwiftUI
import StrandAnalytics
import StrandDesign
@testable import Strand

final class NativeScopeSeriesTests: XCTestCase {

    private func calendar(firstWeekday: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func point(_ key: String, _ value: Double?) -> NativeDayPoint {
        NativeDayPoint(key: key, value: value ?? .nan)
    }

    func testWeekStartsOnCalendarFirstWeekdaySunday() {
        let cal = calendar(firstWeekday: 1)
        // 2026-11-11 is Wednesday. Sunday-start week is Nov 8–14.
        let points = [
            point("2026-11-08", 10),
            point("2026-11-09", 20),
            point("2026-11-10", 30),
            point("2026-11-11", 40),
            point("2026-11-12", 50),
            point("2026-11-13", 60),
            point("2026-11-14", 70),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.count, 1)
        XCTAssertEqual(series.buckets[0].key, "2026-11-08")
        XCTAssertEqual(series.buckets[0].value ?? -1, 40, accuracy: 1e-9)
        XCTAssertFalse(series.buckets[0].isPartial)
    }

    func testWeekStartsOnCalendarFirstWeekdayMonday() {
        let cal = calendar(firstWeekday: 2)
        // Monday-start week containing Nov 11 is Nov 9–15.
        let points = (9...15).map { point(String(format: "2026-11-%02d", $0), Double($0)) }
        let now = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.count, 1)
        XCTAssertEqual(series.buckets[0].key, "2026-11-09")
        XCTAssertEqual(series.buckets[0].value ?? -1, 12, accuracy: 1e-9)
        XCTAssertFalse(series.buckets[0].isPartial)
    }

    func testMissingDaysAreSkippedNotZero() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-11-08", 10),
            point("2026-11-09", nil),
            point("2026-11-10", 30),
            point("2026-11-11", nil),
            point("2026-11-12", 50),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets[0].sampleCount, 3)
        XCTAssertEqual(series.buckets[0].value ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(series.aggregate ?? -1, 30, accuracy: 1e-9)
    }

    func testPartialCurrentWeekIsIncludedAndFlagged() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-11-08", 10),
            point("2026-11-09", 20),
            point("2026-11-10", 30),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-10", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.count, 1)
        XCTAssertTrue(series.buckets[0].isPartial)
        XCTAssertEqual(series.buckets[0].value ?? -1, 20, accuracy: 1e-9)
    }

    func testSixMonthRatesUseMeanAndAverageCaption() {
        let cal = calendar(firstWeekday: 1)
        var points: [NativeDayPoint] = []
        for day in 1...14 {
            points.append(point(String(format: "2026-11-%02d", day), Double(day)))
        }
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.caption, "Average")
        XCTAssertEqual(series.buckets.count, 2)
        XCTAssertEqual(series.kind, .rate)
    }

    func testSixMonthTotalsCaptionIsDailyAverage() {
        let cal = calendar(firstWeekday: 1)
        let points = (8...14).map { point(String(format: "2026-11-%02d", $0), 100) }
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .total, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.caption, "Daily Average")
        XCTAssertEqual(series.buckets[0].value ?? -1, 100, accuracy: 1e-9)
    }

    func testWeekScopeKeepsDailySlotsIncludingGaps() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-11-09", 66),
            point("2026-11-11", 70),
            point("2026-11-15", 58),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.map(\.key), [
            "2026-11-09", "2026-11-10", "2026-11-11", "2026-11-12",
            "2026-11-13", "2026-11-14", "2026-11-15",
        ])
        XCTAssertNil(series.buckets[1].value)
        XCTAssertEqual(series.aggregate ?? -1, (66 + 70 + 58) / 3, accuracy: 1e-9)
        XCTAssertEqual(
            series.heroDateText(of: series.buckets, calendar: cal),
            "Nov 9–15, 2026"
        )
    }

    func testMonthHeroUsesSpacedDashAcrossMonths() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-10-17", 10),
            point("2026-11-15", 20),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .month, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.count, 30)
        XCTAssertEqual(
            series.heroDateText(of: series.buckets, calendar: cal),
            "Oct 17 – Nov 15, 2026"
        )
    }

    func testSixMonthHeroIsMonthRange() {
        let cal = calendar(firstWeekday: 1)
        var points: [NativeDayPoint] = []
        var cursor = NativeScopeSeries.date(from: "2026-05-10", calendar: cal)!
        let end = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        while cursor <= end {
            points.append(point(NativeScopeSeries.key(from: cursor, calendar: cal), 50))
            cursor = cal.date(byAdding: .day, value: 7, to: cursor) ?? cursor
        }
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: end, ending: end
        )
        let window = series.latestWindow()
        XCTAssertEqual(window.count, 26)
        XCTAssertEqual(
            series.heroDateText(of: window, calendar: cal),
            "May – Nov 2026"
        )
    }

    func testYearScopeUsesMonthlyAggregates() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-01-02", 10),
            point("2026-01-20", 20),
            point("2026-02-10", 40),
        ]
        let now = NativeScopeSeries.date(from: "2026-02-10", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .year, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.buckets.count, 2)
        XCTAssertEqual(series.buckets[0].value ?? -1, 15, accuracy: 1e-9)
        XCTAssertEqual(series.buckets[1].value ?? -1, 40, accuracy: 1e-9)
    }

    func testTrendRequiresThreeValuesEachSide() {
        let cal = calendar(firstWeekday: 1)
        let points = (1...10).map { point(String(format: "2026-11-%02d", $0), Double($0 * 10)) }
        let now = NativeScopeSeries.date(from: "2026-11-10", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now
        )
        let visible = Array(series.buckets.suffix(7))
        let trend = series.trend(visible: visible, higherIsBetter: true)
        XCTAssertNotNil(trend)
        XCTAssertEqual(trend?.maxValue ?? -1, 100, accuracy: 1e-9)
        XCTAssertEqual(trend?.minValue ?? -1, 40, accuracy: 1e-9)

        let short = Array(series.buckets.suffix(2))
        XCTAssertNil(series.trend(visible: short, higherIsBetter: true))
    }

    func testTrendHidesWhenPreviousPeriodIsSparse() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-11-01", 10),
            point("2026-11-08", 20),
            point("2026-11-09", 30),
            point("2026-11-10", 40),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-10", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertNil(series.trend(visible: Array(series.buckets.suffix(7)), higherIsBetter: true))
    }

    func testHigherIsBetterTable() {
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("hrv"), true)
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("recovery"), true)
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("steps"), true)
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("rhr"), false)
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("resting_hr"), false)
        XCTAssertEqual(NativeMetricDirection.higherIsBetter("stress"), false)
        XCTAssertNil(NativeMetricDirection.higherIsBetter("resp_rate"))
        XCTAssertNil(NativeMetricDirection.higherIsBetter("strain"))
        XCTAssertNil(NativeMetricDirection.higherIsBetter("energy_kcal"))
        XCTAssertEqual(NativeScopeKindMap.kind(for: "steps"), .total)
        XCTAssertEqual(NativeScopeKindMap.kind(for: "hrv"), .rate)
        XCTAssertEqual(NativeScopeKindMap.kind(for: "strain"), .total)
    }

    func testDeltaArrowUsesHigherIsBetterTint() {
        let hrvUp = NativeMetricDirection.delta(current: 70, previous: 60, higherIsBetter: true)
        XCTAssertEqual(hrvUp.symbol, "arrow.up")
        XCTAssertEqual(hrvUp.tint, NativeTokens.positiveDelta)

        let rhrUp = NativeMetricDirection.delta(current: 58, previous: 50, higherIsBetter: false)
        XCTAssertEqual(rhrUp.symbol, "arrow.up")
        XCTAssertEqual(rhrUp.tint, NativeTokens.negativeDelta)

        let rhrDown = NativeMetricDirection.delta(current: 48, previous: 52, higherIsBetter: false)
        XCTAssertEqual(rhrDown.symbol, "arrow.down")
        XCTAssertEqual(rhrDown.tint, NativeTokens.positiveDelta)

        let flat = NativeMetricDirection.delta(current: 50, previous: 50.5, higherIsBetter: true)
        XCTAssertEqual(flat, .flat)
    }

    func testSelectionDateForWeeklyBucket() {
        let cal = calendar(firstWeekday: 1)
        let start = NativeScopeSeries.date(from: "2026-10-26", calendar: cal)!
        let end = NativeScopeSeries.date(from: "2026-11-02", calendar: cal)!
        let bucket = NativeScopeBucket(
            start: start, end: end, value: 12, low: nil, high: nil,
            isPartial: false, sampleCount: 7, key: "2026-10-26"
        )
        let series = NativeScopeSeries(scope: .sixMonths, kind: .rate, buckets: [bucket], caption: "Average")
        XCTAssertEqual(series.selectionDateText(for: bucket, calendar: cal), "Oct 26 – Nov 1")
    }

    func testTypicalRangeHiddenBelow14Days() {
        let values = Array(repeating: Optional(50.0), count: 13)
        XCTAssertNil(NativeTypicalRange.band(values: values, cfg: Baselines.hrvCfg))
        XCTAssertNil(NativeTypicalRange.band(values: values))
    }

    func testTypicalRangeIsSharedMedianMadBand() {
        var values: [Double?] = Array(repeating: 40, count: 20)
        values += Array(repeating: 60, count: 10)
        let band = NativeTypicalRange.band(values: values, cfg: Baselines.hrvCfg)
        let shared = TypicalVitalRange.range(
            history: values,
            sigmaFloor: TypicalVitalRange.Metric.hrv.sigmaFloor
        )
        XCTAssertNotNil(band)
        XCTAssertEqual(band?.lowerBound ?? -1, shared?.lowerBound ?? -1, accuracy: 1e-12)
        XCTAssertEqual(band?.upperBound ?? -1, shared?.upperBound ?? -1, accuracy: 1e-12)
        XCTAssertEqual(NativeTypicalRange.cfg(for: "hrv"), Baselines.hrvCfg)
        XCTAssertEqual(NativeTypicalRange.cfg(for: "rhr"), Baselines.restingHRCfg)
        XCTAssertEqual(NativeTypicalRange.cfg(for: "resp_rate"), Baselines.respCfg)
        XCTAssertEqual(NativeTypicalRange.cfg(for: "skin_temp"), Baselines.metricCfg["skin_temp"])
        XCTAssertNil(NativeTypicalRange.cfg(for: "steps"))
    }

    func testTypicalRangeCaption() {
        let text = NativeTypicalRange.caption(range: 40...55, format: { "\(Int($0.rounded()))" }, unit: "ms")
        XCTAssertEqual(text, "Typical range 40–55 ms")
        let bare = NativeTypicalRange.caption(range: 40...55, format: { "\(Int($0.rounded()))" }, unit: nil)
        XCTAssertEqual(bare, "Typical range 40–55")
    }

    func testMakeAttachesTypicalFromDailyValues() {
        let cal = calendar(firstWeekday: 1)
        let points = (1...20).map { point(String(format: "2026-11-%02d", $0), 50 + Double($0)) }
        let now = NativeScopeSeries.date(from: "2026-11-20", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now,
            cfg: Baselines.hrvCfg
        )
        XCTAssertNotNil(series.typical)
        XCTAssertTrue(series.showsTrendLine)
        let day = NativeScopeSeries.make(
            points: points, scope: .day, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertFalse(day.showsTrendLine)
    }

    func testSixMonthDoesNotPlotDailyMarks() {
        let cal = calendar(firstWeekday: 1)
        var points: [NativeDayPoint] = []
        var cursor = NativeScopeSeries.date(from: "2026-05-17", calendar: cal)!
        let end = NativeScopeSeries.date(from: "2026-11-15", calendar: cal)!
        while cursor <= end {
            points.append(point(NativeScopeSeries.key(from: cursor, calendar: cal), 50))
            cursor = cal.date(byAdding: .day, value: 1, to: cursor) ?? cursor
        }
        let series = NativeScopeSeries.make(
            points: points, scope: .sixMonths, kind: .rate, calendar: cal, now: end, ending: end
        )
        XCTAssertEqual(series.latestWindow().count, 26)
        XCTAssertLessThan(series.buckets.count, points.count / 4)
        XCTAssertGreaterThan(series.buckets.first?.sampleCount ?? 0, 1)
    }

    func testPeriodDeltaCaptionUsesPriorWindowName() {
        let cal = calendar(firstWeekday: 1)
        let points = (1...14).map { point(String(format: "2026-11-%02d", $0), Double($0 * 10)) }
        let now = NativeScopeSeries.date(from: "2026-11-14", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .rate, calendar: cal, now: now, ending: now
        )
        let visible = Array(series.buckets.suffix(7))
        let trend = series.trend(visible: visible, higherIsBetter: true)
        XCTAssertNotNil(trend)
        XCTAssertGreaterThan(trend?.percentChange ?? 0, 0)
        XCTAssertEqual(series.priorPeriodName(), "vs. prior week")
        let caption = series.periodDeltaCaption(of: visible, higherIsBetter: true)
        XCTAssertNotNil(caption)
        XCTAssertTrue(caption?.contains("vs. prior week") == true)
        let month = NativeScopeSeries.make(
            points: points, scope: .month, kind: .rate, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(month.priorPeriodName(), "vs. prior month")
        XCTAssertEqual(
            NativeScopeSeries(scope: .sixMonths, kind: .rate, buckets: [], caption: "Average").priorPeriodName(),
            "vs. prior 6 months"
        )
    }

    func testIntradayTimeFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        cal.locale = Locale(identifier: "en_US_POSIX")
        let date = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 15, minute: 40))!
        XCTAssertEqual(NativeScopeFormat.time(date, calendar: cal), "3:40 PM")
        let noon = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 12))!
        XCTAssertEqual(NativeScopeFormat.hourClock(noon, calendar: cal), "12 PM")
    }

    func testDayTotalsCaptionIsTotal() {
        XCTAssertEqual(NativeScopeSeries.caption(scope: .day, kind: .total), "Total")
        XCTAssertEqual(NativeScopeSeries.caption(scope: .week, kind: .total), "Average")
        XCTAssertEqual(NativeScopeSeries.caption(scope: .day, kind: .rate), "Average")
    }

    func testCountTicksAreNiceThousands() {
        XCTAssertEqual(NativeCountTicks.niceCeiling(8_202), 10_000, accuracy: 0.1)
        XCTAssertEqual(NativeCountTicks.values(ceiling: 8_202), [0, 5_000, 10_000])
        XCTAssertEqual(NativeCountFormat.compact(0), "0")
        XCTAssertEqual(NativeCountFormat.compact(5_000), "5k")
        XCTAssertEqual(NativeCountFormat.compact(10_000), "10k")
        XCTAssertEqual(NativeCountFormat.integer(8_202), "8,202")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = cal.date(from: DateComponents(year: 2026, month: 11, day: 17))!
        XCTAssertEqual(NativeCountTicks.hourLabelDates(dayStart: start, calendar: cal).count, 4)
    }

    func testStepMadBandGoesNegativeWithoutDisplayGuard() {
        var values: [Double?] = Array(repeating: 4_000, count: 15)
        values += Array(repeating: 20_000, count: 15)
        let band = NativeTypicalRange.band(values: values)
        XCTAssertNotNil(band)
        XCTAssertLessThan(band?.lowerBound ?? 0, 0)
        XCTAssertNil(NativeTypicalRange.display(band, kind: .total))
        XCTAssertEqual(NativeTypicalRange.display(band, kind: .rate)?.lowerBound ?? -1, 0, accuracy: 1e-9)
    }

    func testTotalsDoNotAttachTypicalRange() {
        let cal = calendar(firstWeekday: 1)
        let points = (1...20).map { day -> NativeDayPoint in
            let steps = day == 18 ? 50_000.0 : 8_000.0
            return point(String(format: "2026-11-%02d", day), steps)
        }
        let now = NativeScopeSeries.date(from: "2026-11-20", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .total, calendar: cal, now: now, ending: now
        )
        XCTAssertNil(series.typical)
        XCTAssertNil(NativeTypicalRange.display((-6_273)...35_137, kind: .total))
        XCTAssertEqual(NativeTypicalRange.display((-5)...40, kind: .rate)?.lowerBound ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(
            NativeTypicalRange.caption(range: (-6_273)...35_137, format: { NativeCountFormat.integer($0) }, unit: "steps"),
            "Typical range 0–35,137 steps"
        )
    }

    func testWeekWindowPadsToVisibleCountWithSparseTotals() {
        let cal = calendar(firstWeekday: 1)
        let points = [
            point("2026-11-16", 300),
            point("2026-11-17", 364),
        ]
        let now = NativeScopeSeries.date(from: "2026-11-17", calendar: cal)!
        let series = NativeScopeSeries.make(
            points: points, scope: .week, kind: .total, calendar: cal, now: now, ending: now
        )
        XCTAssertEqual(series.latestWindow().count, 7)
        XCTAssertEqual(series.buckets.count, 7)
        XCTAssertEqual(series.known.count, 2)
        XCTAssertNil(series.typical)
        XCTAssertEqual(series.aggregate(of: series.latestWindow()) ?? -1, 332, accuracy: 0.5)
        XCTAssertEqual(
            series.heroDateText(of: series.latestWindow(), calendar: cal),
            "Nov 11–17, 2026"
        )
    }

    func testLineSegmentsJoinShortGapsAndBreakLongOnes() {
        let cal = calendar(firstWeekday: 1)
        func bucket(_ key: String, _ value: Double?) -> NativeScopeBucket {
            let start = NativeScopeSeries.date(from: key, calendar: cal)!
            return NativeScopeBucket(
                start: start,
                end: cal.date(byAdding: .day, value: 1, to: start)!,
                value: value,
                low: nil, high: nil, isPartial: false,
                sampleCount: value == nil ? 0 : 1,
                key: key
            )
        }
        let buckets = [
            bucket("2026-10-01", 52),
            bucket("2026-10-02", nil),
            bucket("2026-10-04", 51),
            bucket("2026-10-20", 52),
        ]
        let segments = NativeScopePlotMath.lineSegments(buckets)
        XCTAssertEqual(segments.map(\.segment), [0, 0, 1])
        XCTAssertEqual(segments.map(\.key), ["2026-10-01", "2026-10-04", "2026-10-20"])
        XCTAssertEqual(NativeScopePlotMath.barUnit(scope: .week), .day)
        XCTAssertEqual(NativeScopePlotMath.barUnit(scope: .sixMonths), .weekOfYear)
        XCTAssertTrue(NativeScopePlotMath.showsVertices(scope: .week, knownCount: 2))
        let clipped = NativeScopePlotMath.clippedTypical((-6_273)...35_137, yDomain: 0...10_000)
        XCTAssertEqual(clipped?.lowerBound ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(clipped?.upperBound ?? -1, 10_000, accuracy: 1e-9)
        XCTAssertNil(NativeScopePlotMath.clippedTypical(40...55, yDomain: 80...100))
    }

    func testSummarySentenceMatchesTrendView() {
        let text = NativeScopeSummary.sentence(
            title: "HRV",
            scope: .month,
            kind: .rate,
            current: 46,
            previous: 49,
            format: { "\(Int($0.rounded()))" },
            higherIsBetter: true
        )
        XCTAssertEqual(
            text,
            "Your average HRV this month (46) was below your previous 30-day average of 49."
        )
        let even = NativeScopeSummary.sentence(
            title: "VO₂ Max",
            scope: .week,
            kind: .rate,
            current: 52,
            previous: 51.5,
            format: { String(format: "%.1f", $0) },
            higherIsBetter: true
        )
        XCTAssertEqual(
            even,
            "Your average VO₂ Max this week (52.0) was about the same as your previous week average of 51.5."
        )
        XCTAssertEqual(NativeScopeSummary.periodPhrase(.month), "this month")
        XCTAssertEqual(NativeScopeSummary.priorPhrase(.month), "30-day")
    }

    func testLineYTicksAreRoundNumbers() {
        let ticks = NativeScopeYTicks.values(in: 14...78)
        XCTAssertGreaterThanOrEqual(ticks.count, 2)
        XCTAssertEqual(ticks.first ?? -1, 20, accuracy: 0.01)
        XCTAssertTrue(ticks.allSatisfy { abs($0.rounded() - $0) < 0.01 })
        let domain = NativeScopeYTicks.niceDomain([46, 52, 48], fallback: 0...1)
        XCTAssertLessThanOrEqual(domain.lowerBound, 46)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 52)
    }
}

import XCTest
@testable import Strand
import StrandAnalytics

/// Equivalence: chart payloads moved out of `body` match the previous in-view getters.
final class NativeChartPerfModelTests: XCTestCase {

    func testEpochDayMatchesFormatterStartOfLocalDayOrderAndSpan() {
        let keys = [
            "1970-01-01", "2023-12-31", "2024-02-28", "2024-02-29", "2024-03-01",
            "2026-10-16", "2026-11-01", "2026-11-15", "2026-11-16"
        ]
        let formatterDates = keys.map { formatterStartOfLocalDay($0) }
        let newDates = keys.map { NativeDayLogic.startOfLocalDay($0) }
        let days = keys.map { NativeDayLogic.epochDay($0) }
        for index in keys.indices {
            XCTAssertEqual(newDates[index], formatterDates[index], keys[index])
            XCTAssertNotNil(days[index], keys[index])
        }
        for index in 0..<(keys.count - 1) {
            let oldSpan = Calendar.current.dateComponents(
                [.day], from: formatterDates[index]!, to: formatterDates[index + 1]!
            ).day
            XCTAssertEqual(oldSpan, days[index + 1]! - days[index]!, keys[index])
            XCTAssertEqual(
                formatterDates[index]! < formatterDates[index + 1]!,
                days[index]! < days[index + 1]!
            )
        }
        XCTAssertEqual(NativeDayLogic.epochDay(year: 1970, month: 1, day: 1), 0)
        XCTAssertNil(NativeDayLogic.civilDate("2026-1-1"))
        XCTAssertNil(NativeDayLogic.epochDay("not-a-day"))
    }

    func testWindowedEpochFilterMatchesStartOfLocalDayFilter() {
        let points: [HealthspanEngine.TrendPoint] = [
            .init(day: "2026-05-16", bandAge: 26.0, chronoAge: 29.5, pace: 1.1),
            .init(day: "2026-10-01", bandAge: 26.4, chronoAge: 29.9, pace: 1.0),
            .init(day: "2026-11-01", bandAge: 26.6, chronoAge: 30.0, pace: 0.9),
            .init(day: "2026-11-15", bandAge: 26.8, chronoAge: 30.0, pace: 0.8)
        ]
        for scope in NativeHealthspanTrendScope.allCases {
            XCTAssertEqual(
                NativeHealthspanTrendScope.windowed(points, scope: scope).map(\.day),
                windowedWithStartOfLocalDay(points, scope: scope).map(\.day),
                scope.rawValue
            )
        }
    }

    func testHealthspanTrendModelMatchesPreviousBodyGetters() {
        let points: [HealthspanEngine.TrendPoint] = (0..<26).map { offset in
            let day = String(format: "2026-%02d-%02d", 6 + offset / 4, 1 + (offset % 28))
            return .init(
                day: day,
                bandAge: 26 + Double(offset) * 0.05,
                chronoAge: 30,
                pace: 0.8 + Double(offset) * 0.01
            )
        }
        let model = NativeHealthspanTrendModel.make(points: points, kind: .bandAge, scope: .sixMonths)
        let old = oldHealthspanPlot(points: points, scope: .sixMonths)
        XCTAssertEqual(model.inWindow.map(\.id), old.plot.filter { NativePlotAxis.inTimeDomain($0.day, old.xDomain) }.map(\.id))
        XCTAssertEqual(model.steppedBandAge.map(\.id), old.stepped.map(\.id))
        XCTAssertEqual(model.steppedBandAge.map(\.bandAge), old.stepped.map(\.bandAge))
        XCTAssertEqual(model.xDomain.lowerBound, old.xDomain.lowerBound)
        XCTAssertEqual(model.xDomain.upperBound, old.xDomain.upperBound)
        XCTAssertEqual(model.ageDomain.lowerBound, old.ageDomain.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(model.ageDomain.upperBound, old.ageDomain.upperBound, accuracy: 1e-9)
        XCTAssertEqual(model.paceDomain.lowerBound, old.paceDomain.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(model.paceDomain.upperBound, old.paceDomain.upperBound, accuracy: 1e-9)
        XCTAssertEqual(model.ageYTicks.map(\.value), NativePlotAxis.yTicks(in: old.ageDomain))
        XCTAssertEqual(
            model.monthTicks.map(\.date),
            NativePlotAxis.monthTicks(start: old.xDomain.lowerBound, end: old.xDomain.upperBound)
        )
        XCTAssertEqual(
            NativeHealthspanTrendModel.steppedBandAge(old.plot).map(\.bandAge),
            old.stepped.map(\.bandAge)
        )
    }

    func testOvernightPlotModelMatchesPreviousBodyGetters() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<180).map { index in
            NativeHourPoint(
                time: start.addingTimeInterval(TimeInterval(index) * 60),
                value: 58 + Double(index % 17)
            )
        }
        let model = NativeOvernightPlotModel.make(points: points)
        let oldPlot = NativeStressMonitorMath.drawPoints(
            NativeHRSmoothing.smooth(points),
            budget: NativeHRDisplay.plotBudget
        )
        XCTAssertEqual(model.plotPoints, oldPlot)
        XCTAssertEqual(model.plotPoints, NativeHRDisplay.line(points))
        let oldX: ClosedRange<Date>? = {
            guard let first = oldPlot.map(\.time).min(),
                  let last = oldPlot.map(\.time).max(),
                  last > first
            else { return nil }
            return first...last
        }()
        XCTAssertEqual(model.xDomain, oldX)
        let vals = oldPlot.map(\.value).filter(\.isFinite)
        let oldTicks = NativeChartTicks.nice(min: vals.min() ?? 40, max: vals.max() ?? 90, targetCount: 4)
        XCTAssertEqual(model.axisTicks, oldTicks)
        XCTAssertEqual(model.yDomain, NativeChartTicks.domain(from: oldTicks, fallback: 40...90))
        let oldDomain = oldPlot.filter {
            guard let x = oldX else { return true }
            return $0.time >= x.lowerBound && $0.time <= x.upperBound
                && $0.value >= model.yDomain.lowerBound && $0.value <= model.yDomain.upperBound
        }
        XCTAssertEqual(model.domainPoints, oldDomain)
        XCTAssertEqual(NativeOvernightMemo.model(for: points).plotPoints, model.plotPoints)
        XCTAssertEqual(NativeOvernightMemo.model(for: points).axisTicks, model.axisTicks)
    }

    func testHypnogramLayoutMatchesPreviousXRange() {
        let nightStart = Date(timeIntervalSince1970: 1_000_000)
        let nightEnd = nightStart.addingTimeInterval(8 * 3600)
        let spans = [
            NativeSleepStageSpan(startTs: 1_000_000, endTs: 1_000_000 + 1800, name: "Awake"),
            NativeSleepStageSpan(startTs: 1_000_000 + 1800, endTs: 1_000_000 + 8 * 3600, name: "Light")
        ]
        let layout = NativeSleepHypnogramLayout.make(spans: spans, nightStart: nightStart, nightEnd: nightEnd)
        XCTAssertEqual(layout.spans.count, 2)
        let width: CGFloat = 400
        let height: CGFloat = 132
        for (draw, span) in zip(layout.spans, spans) {
            let old = NativeSleepHypnogramMath.xRange(
                start: span.startTs, end: span.endTs,
                nightStart: layout.startTs, nightEnd: layout.endTs,
                width: Double(width)
            )
            XCTAssertEqual(Double(draw.unitLo) * Double(width), old?.x ?? -1, accuracy: 1e-9)
            XCTAssertEqual(Double(draw.unitHi - draw.unitLo) * Double(width), old?.width ?? -1, accuracy: 1e-9)
            let laneH = height / 4
            XCTAssertEqual(CGFloat(draw.unitY) * height, CGFloat(draw.lane) * laneH + laneH * 0.22, accuracy: 1e-9)
            XCTAssertEqual(CGFloat(draw.unitH) * height, laneH * 0.55, accuracy: 1e-9)
            let bar = NativeSleepHypnogramLayout.barRect(span: draw, plotWidth: width, plotHeight: height)
            XCTAssertEqual(bar.origin.x, 48 + CGFloat(draw.unitLo) * width, accuracy: 1e-9)
            XCTAssertEqual(bar.size.width, max(CGFloat(draw.unitHi - draw.unitLo) * width, 1), accuracy: 1e-9)
            XCTAssertEqual(bar.origin.y, CGFloat(draw.unitY) * height, accuracy: 1e-9)
            XCTAssertEqual(bar.size.height, max(CGFloat(draw.unitH) * height, 6), accuracy: 1e-9)
        }
        XCTAssertEqual(layout.axisTimes, NativeSleepHypnogramMath.axisTimes(start: nightStart, end: nightEnd))
        XCTAssertEqual(layout.nightStartLabel, NativeSleepClock.clock(nightStart))
    }

    func testStressDayPlotModelMatchesPreviousClipAndSegments() {
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let now = dayStart.addingTimeInterval(12 * 3600)
        let hours = (0..<120).map { index in
            NativeHourPoint(time: dayStart.addingTimeInterval(TimeInterval(index) * 60), value: Double(index % 3))
        }
        let sleepStart = dayStart.addingTimeInterval(-2 * 3600)
        let sleepEnd = dayStart.addingTimeInterval(6 * 3600)
        let workouts = [(start: dayStart.addingTimeInterval(8 * 3600), end: dayStart.addingTimeInterval(9 * 3600))]
        let model = NativeStressDayPlotModel.make(
            score: 1.4,
            hours: hours,
            sleepStart: sleepStart,
            sleepEnd: sleepEnd,
            workouts: workouts,
            workoutSymbols: ["figure.run"],
            dayStart: dayStart,
            now: now
        )
        let plotEnd = NativeStressMonitorMath.plotEnd(dayStart: dayStart, now: now)
        let clipped = NativeScopePlotMath.clippedHours(hours, start: dayStart, end: plotEnd)
        XCTAssertEqual(model.hours, clipped)
        XCTAssertEqual(
            model.hourSegments,
            NativeStressDayPlotModel.downsampleSegments(NativeStressMonitorMath.segments(clipped))
        )
        XCTAssertEqual(
            NativeStressDayPlotModel.downsampleSegments(NativeStressMonitorMath.segments(clipped)),
            NativeStressMonitorMath.segments(clipped)
        )
        let oldSleep = NativeStressLaneIcon.clip(sleepStart, sleepEnd, plotStart: dayStart, plotEnd: plotEnd)
        XCTAssertEqual(model.sleepVisible?.start, oldSleep?.start)
        XCTAssertEqual(model.sleepVisible?.end, oldSleep?.end)
        XCTAssertEqual(model.plotEnd, plotEnd)
        XCTAssertEqual(model.xDomain, NativeScopePlotMath.paddedXDomain(start: dayStart, end: plotEnd))
        XCTAssertEqual(
            model.hourLabels,
            NativeCountTicks.roundHourLabels(dayStart: dayStart, plotEnd: plotEnd, calendar: .current)
        )
    }

    func testChartDayCachedLabelsMatchFreshFormatters() {
        let keys = ["2026-11-09", "2026-11-15", "2026-01-01"]
        let posix = Locale(identifier: "en_US_POSIX")
        let gmt = TimeZone(secondsFromGMT: 0)!
        func formatter(_ format: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = posix
            formatter.timeZone = gmt
            formatter.dateFormat = format
            return formatter
        }
        let parser = formatter("yyyy-MM-dd")
        let weekday = formatter("EEE")
        let day = formatter("d")
        let long = formatter("EEE, MMM d")
        for key in keys {
            let date = parser.date(from: key)
            XCTAssertEqual(NativeChartDay.date(from: key), date)
            XCTAssertEqual(NativeChartDay.weekday(key), date.map { weekday.string(from: $0) } ?? key)
            XCTAssertEqual(NativeChartDay.dayOfMonth(key), date.map { day.string(from: $0) } ?? key)
            XCTAssertEqual(NativeChartDay.longLabel(key), date.map { long.string(from: $0) } ?? key)
            XCTAssertEqual(NativeChartDay.weekday(key), NativeChartDay.weekday(key))
        }
    }

    func testDaySelectionParsesOncePerStoredKey() {
        let now = Date()
        let day = Calendar.current.startOfDay(for: now)
        let stored = NativeDayLogic.persistSteppedDay(day, now: now, launchId: NativeDayLogic.launchId)
        let first = NativeDaySelection.date(from: stored)
        let second = NativeDaySelection.date(from: stored)
        XCTAssertEqual(first, second)
        XCTAssertEqual(NativeDaySelection.resolvedKey(from: stored), NativeDayLogic.resolvedDayKey(stored: stored))
        XCTAssertEqual(Calendar.current.startOfDay(for: first), Calendar.current.startOfDay(for: day))
    }

    func testWeekBarsTicksMatchPreviousInlineGetters() {
        let known = [12.0, 18.0, 7.0]
        let ticks = NativeScoreWeekBarsMath.axisTicks(maxY: 21, yTicks: nil, compactYAxis: false)
        let oldTicks = NativeChartTicks.nice(min: 0, max: max(21, 1), targetCount: 4)
        XCTAssertEqual(ticks, oldTicks)
        XCTAssertEqual(
            NativeScoreWeekBarsMath.plotCeiling(ticks: ticks, known: known, maxY: 21),
            max(ticks.last ?? 21, known.max() ?? 0, 1)
        )
        XCTAssertEqual(
            NativeScoreWeekBarsMath.axisTicks(maxY: 100, yTicks: [0, 50, 100], compactYAxis: true),
            [0, 50, 100]
        )
    }

    func testRangeBarProgressMatchesMarkerMath() {
        XCTAssertEqual(
            NativeHealthspanFormat.markerProgress(value: 70, scaleMin: 40, scaleMax: 100),
            0.5,
            accuracy: 1e-9
        )
        let width: CGFloat = 200
        let x6 = CGFloat(NativeHealthspanFormat.markerProgress(value: 70, scaleMin: 40, scaleMax: 100)) * width
        XCTAssertEqual(x6, 100, accuracy: 1e-6)
        let frames = NativeHealthspanRangeBarMath.segmentFrames(width: width)
        XCTAssertEqual(frames.count, 8)
        let spacing: CGFloat = 2
        let segmentWidth = (width - spacing * 7) / 8
        for (index, frame) in frames.enumerated() {
            XCTAssertEqual(frame.origin.x, CGFloat(index) * (segmentWidth + spacing), accuracy: 1e-6)
            XCTAssertEqual(frame.size.width, segmentWidth, accuracy: 1e-6)
            XCTAssertEqual(frame.size.height, 8, accuracy: 1e-9)
        }
        XCTAssertEqual(NativeHealthspanRangeBarMath.band(index: 0, higherIsBetter: true), 0)
        XCTAssertEqual(NativeHealthspanRangeBarMath.band(index: 3, higherIsBetter: true), 1)
        XCTAssertEqual(NativeHealthspanRangeBarMath.band(index: 7, higherIsBetter: true), 2)
        XCTAssertEqual(NativeHealthspanRangeBarMath.band(index: 0, higherIsBetter: false), 2)
        XCTAssertEqual(NativeHealthspanRangeBarMath.band(index: 7, higherIsBetter: false), 0)
    }

    func testStressDayPlotDownsamplesDrawnMinutesTo300() {
        let dayStart = Date(timeIntervalSince1970: 1_700_000_000)
        let hours = (0..<1_440).map { index in
            NativeHourPoint(time: dayStart.addingTimeInterval(TimeInterval(index) * 60), value: Double(index % 3))
        }
        let segments = NativeStressMonitorMath.segments(hours)
        let drawn = NativeStressDayPlotModel.downsampleSegments(segments)
        XCTAssertLessThanOrEqual(drawn.reduce(0) { $0 + $1.count }, NativeStressDayPlotModel.drawBudget)
        XCTAssertEqual(drawn.first?.first, hours.first)
        XCTAssertEqual(drawn.last?.last, hours.last)
        XCTAssertEqual(NativeStressDayPlotModel.drawBudget, 300)
    }

    func testScopeFormatAlignedMatchesFreshFormatter() {
        let calendar = Calendar.current
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func fresh(_ format: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            return formatter.string(from: date)
        }
        XCTAssertEqual(NativeScopeFormat.time(date, calendar: calendar), fresh("h:mm a"))
        XCTAssertEqual(NativeScopeFormat.hourClock(date, calendar: calendar), fresh("h a"))
        XCTAssertEqual(NativeScopeFormat.monthDay(date, calendar: calendar), fresh("MMM d"))
        XCTAssertEqual(NativeScopeFormat.weekdayDate(date, calendar: calendar), fresh("EEE, MMM d"))
        _ = NativeScopeFormat.time(date, calendar: calendar)
        XCTAssertGreaterThanOrEqual(NativeScopeFormat.formatterCacheCountForTests(), 1)
    }

    func testSleepDualLineModelMatchesPreviousBodyGetters() throws {
        let slept: [NativeDayPoint] = (0..<7).map { offset in
            NativeDayPoint(key: String(format: "2026-11-%02d", 9 + offset), value: Double(360 + offset * 12))
        }
        let needed: [NativeDayPoint] = slept.map {
            NativeDayPoint(key: $0.key, value: 480)
        }
        let typical: ClosedRange<Double> = 400...500
        let model = NativeSleepDualLineModel.make(slept: slept, needed: needed, typical: typical)
        let knownSlept = slept.filter { $0.value.isFinite }
        let knownNeeded = needed.filter { $0.value.isFinite }
        let values = (knownSlept + knownNeeded).map(\.value) + [typical.lowerBound, typical.upperBound]
        let ticks = NativeChartTicks.nice(min: values.min() ?? 0, max: values.max() ?? 480, targetCount: 4)
        let yDomain = NativeChartTicks.domain(from: ticks, fallback: 0...480)
        XCTAssertEqual(model.axisTicks, ticks)
        XCTAssertEqual(model.yDomain.lowerBound, yDomain.lowerBound, accuracy: 1e-9)
        XCTAssertEqual(model.yDomain.upperBound, yDomain.upperBound, accuracy: 1e-9)
        XCTAssertEqual(model.sleptLine.map(\.key), NativeChartDay.linePoints(slept).filter {
            $0.value >= yDomain.lowerBound && $0.value <= yDomain.upperBound
        }.map(\.key))
        XCTAssertEqual(model.neededLine.map(\.value), NativeChartDay.linePoints(needed).filter {
            $0.value >= yDomain.lowerBound && $0.value <= yDomain.upperBound
        }.map(\.value))
        XCTAssertEqual(model.averageSlept, NativeScoreMath.mean(knownSlept.map(\.value)))
        XCTAssertEqual(
            try XCTUnwrap(model.typicalClipped?.lowerBound),
            max(typical.lowerBound, yDomain.lowerBound),
            accuracy: 1e-9
        )
    }

    func testSleepStressPlotModelMatchesPreviousBodyGetters() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = (0..<180).map { index in
            NativeHourPoint(time: start.addingTimeInterval(TimeInterval(index) * 60), value: Double(index % 4) * 0.7)
        }
        let model = NativeSleepStressPlotModel.make(points: points)
        let oldX: ClosedRange<Date>? = {
            guard let first = points.map(\.time).min(), let last = points.map(\.time).max(), last > first else {
                return nil
            }
            return first...last
        }()
        XCTAssertEqual(model.xDomain, oldX)
        let oldDomain = points.filter {
            guard let x = oldX else { return $0.value >= 0 && $0.value <= 3 }
            return $0.time >= x.lowerBound && $0.time <= x.upperBound && $0.value >= 0 && $0.value <= 3
        }
        XCTAssertEqual(model.domainPoints, oldDomain)
        XCTAssertEqual(model.average, NativeScoreMath.mean(points.map(\.value)) ?? 0, accuracy: 1e-9)
        XCTAssertEqual(
            model.hourLabels,
            oldX.map { NativeChartTicks.hourDates(from: $0.lowerBound, to: $0.upperBound) } ?? []
        )
    }

    func testTimeInBedPlotModelMatchesFittedPlot() {
        let points: [NativeDayPoint] = [
            NativeDayPoint(key: "2026-11-10", value: 480, low: 180, high: 660),
            NativeDayPoint(key: "2026-11-11", value: 500, low: 200, high: 700)
        ]
        let model = NativeSleepTimeInBedPlotModel.make(points: points)
        XCTAssertEqual(
            model.window,
            NativeSleepClock.fittedPlot(beds: points.compactMap(\.low), wakes: points.compactMap(\.high))
        )
        XCTAssertEqual(model.average, NativeScoreMath.mean(points.map(\.value)))
    }

    func testRestorativePlotModelMatchesPreviousStackGetters() {
        let rem: [NativeDayPoint] = (0..<7).map { offset in
            NativeDayPoint(key: String(format: "2026-11-%02d", 9 + offset), value: Double(80 + offset))
        }
        let deep: [NativeDayPoint] = rem.map { NativeDayPoint(key: $0.key, value: 70) }
        let model = NativeSleepRestorativePlotModel.make(deep: deep, rem: rem)
        let totals = NativeWeek.sumSeries(deep, rem)
        let known = totals.filter { $0.value.isFinite }
        let hi = max(known.map(\.value).max() ?? 0, 120)
        let ticks = NativeChartTicks.nice(min: 0, max: hi, targetCount: 4)
        XCTAssertEqual(model.totals.map(\.value), totals.map(\.value))
        XCTAssertEqual(model.axisTicks, ticks)
        XCTAssertEqual(model.ceiling, max(ticks.last ?? 120, 1), accuracy: 1e-9)
        XCTAssertEqual(model.slices.filter { $0.series == "REM" }.map(\.value), rem.map(\.value))
        XCTAssertEqual(NativeSleepRestorativePlotModel.stackOrder(), ["REM", "Deep"])
    }

    // MARK: - Old algorithms (pre-move)

    private func formatterStartOfLocalDay(_ key: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: key) else { return nil }
        return Calendar.current.startOfDay(for: date)
    }

    private func windowedWithStartOfLocalDay(
        _ points: [HealthspanEngine.TrendPoint],
        scope: NativeHealthspanTrendScope
    ) -> [HealthspanEngine.TrendPoint] {
        guard let last = points.last, let end = formatterStartOfLocalDay(last.day) else { return points }
        let start = Calendar.current.date(byAdding: .day, value: -scope.days, to: end) ?? end
        return points.filter { point in
            guard let day = formatterStartOfLocalDay(point.day) else { return false }
            return day >= start
        }
    }

    private struct OldHealthspanPlot {
        var plot: [NativeHealthspanTrendModel.PlotPoint]
        var stepped: [NativeHealthspanTrendModel.PlotPoint]
        var xDomain: ClosedRange<Date>
        var ageDomain: ClosedRange<Double>
        var paceDomain: ClosedRange<Double>
    }

    private func oldHealthspanPlot(
        points: [HealthspanEngine.TrendPoint],
        scope: NativeHealthspanTrendScope
    ) -> OldHealthspanPlot {
        let plot: [NativeHealthspanTrendModel.PlotPoint] = windowedWithStartOfLocalDay(points, scope: scope)
            .enumerated()
            .compactMap { index, point in
                guard let day = formatterStartOfLocalDay(point.day) else { return nil }
                return .init(
                    id: "\(point.day)-\(index)",
                    day: day,
                    bandAge: point.bandAge,
                    chronoAge: point.chronoAge,
                    pace: point.pace
                )
            }
        let stepped = NativeHealthspanTrendModel.steppedBandAge(plot)
        let xDomain: ClosedRange<Date> = {
            guard let first = plot.first, let last = plot.last, last.day >= first.day else {
                let now = Date()
                return now...now.addingTimeInterval(86_400)
            }
            return first.day...last.day
        }()
        return OldHealthspanPlot(
            plot: plot,
            stepped: stepped,
            xDomain: xDomain,
            ageDomain: NativePlotAxis.yDomain(plot.flatMap { [$0.bandAge, $0.chronoAge] }, fallback: 20...40),
            paceDomain: NativePlotAxis.yDomain(plot.compactMap(\.pace) + [1], fallback: 0...2)
        )
    }
}

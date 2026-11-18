import XCTest
import WhoopStore
@testable import Strand

final class NativeAddActivityChartTests: XCTestCase {

    private func gmt() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func dayStart() -> Date {
        gmt().date(from: DateComponents(year: 2024, month: 6, day: 15))!
    }

    private func at(_ hours: Int, _ minutes: Int = 0, _ seconds: Int = 0) -> Date {
        dayStart().addingTimeInterval(TimeInterval(hours * 3600 + minutes * 60 + seconds))
    }

    private func sample(hour: Int, minute: Int, bpm: Double, maxBpm: Double? = nil) -> NativeAddActivityChartLogic.Sample {
        let ts = Int(at(hour, minute).timeIntervalSince1970)
        return NativeAddActivityChartLogic.Sample(ts: ts, bpm: bpm, maxBpm: maxBpm)
    }

    private func row(start: Date, end: Date, sport: String = "Running") -> WorkoutRow {
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(end.timeIntervalSince1970)
        return WorkoutRow(
            startTs: startTs, endTs: endTs, sport: sport, source: "manual",
            durationS: Double(endTs - startTs), energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }

    // MARK: - Snap

    func testSnapToMinuteRoundsNearestAwayFromZero() {
        XCTAssertEqual(NativeAddActivityChartLogic.snapToMinute(at(8, 0, 29)), at(8, 0))
        XCTAssertEqual(NativeAddActivityChartLogic.snapToMinute(at(8, 0, 30)), at(8, 1))
        XCTAssertEqual(NativeAddActivityChartLogic.snapToMinute(at(8, 1, 30)), at(8, 2))
        XCTAssertEqual(NativeAddActivityChartLogic.snapToMinute(at(8, 0, 0)), at(8, 0))
    }

    // MARK: - Clamp / keep duration

    func testClampedWindowKeepsDurationAndSnapsStart() {
        let now = at(20)
        let result = NativeAddActivityChartLogic.clampedWindow(
            start: at(8, 0, 20),
            duration: 45 * 60,
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(result.start, at(8, 0))
        XCTAssertEqual(result.end, at(8, 45))
    }

    func testClampedWindowPinsStartToDayStart() {
        let now = at(20)
        let result = NativeAddActivityChartLogic.clampedWindow(
            start: at(0).addingTimeInterval(-10 * 60),
            duration: 30 * 60,
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(result.start, dayStart())
        XCTAssertEqual(result.end, at(0, 30))
    }

    func testClampedWindowDoesNotEndAfterNow() {
        let now = at(10)
        let result = NativeAddActivityChartLogic.clampedWindow(
            start: at(12),
            duration: 45 * 60,
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(result.start, at(9, 15))
        XCTAssertEqual(result.end, at(10))
        XCTAssertLessThanOrEqual(result.end, now)
    }

    func testClampedWindowDoesNotLeaveTheDay() {
        let now = at(23, 50).addingTimeInterval(86_400)
        let result = NativeAddActivityChartLogic.clampedWindow(
            start: at(23, 30),
            duration: 45 * 60,
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        let dayEnd = NativeAddActivityChartLogic.dayBounds(for: dayStart(), calendar: gmt()).end
        XCTAssertEqual(result.start, at(23, 15))
        XCTAssertEqual(result.end, dayEnd)
        XCTAssertLessThanOrEqual(result.end, dayEnd)
    }

    func testClampedWindowShrinksWhenDurationCannotFit() {
        let now = at(0, 20)
        let result = NativeAddActivityChartLogic.clampedWindow(
            start: at(0),
            duration: 45 * 60,
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(result.start, dayStart())
        XCTAssertEqual(result.end, now)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 20 * 60)
    }

    func testDayBoundsAreStartOfDayToNextMidnight() {
        let bounds = NativeAddActivityChartLogic.dayBounds(for: at(15, 42), calendar: gmt())
        XCTAssertEqual(bounds.start, dayStart())
        XCTAssertEqual(bounds.end, dayStart().addingTimeInterval(86_400))
    }

    func testClampedStartMovesOnlyTheStartEdge() {
        let now = at(20)
        let result = NativeAddActivityChartLogic.clampedStart(
            at(8, 10), keepingEnd: at(8, 45), dayStart: dayStart(), now: now, calendar: gmt()
        )
        XCTAssertEqual(result.start, at(8, 10))
        XCTAssertEqual(result.end, at(8, 45))
    }

    func testClampedStartStopsSixtySecondsBeforeEnd() {
        let now = at(20)
        let result = NativeAddActivityChartLogic.clampedStart(
            at(8, 50), keepingEnd: at(8, 45), dayStart: dayStart(), now: now, calendar: gmt()
        )
        XCTAssertEqual(result.start, at(8, 44))
        XCTAssertEqual(result.end, at(8, 45))
    }

    func testClampedEndMovesOnlyTheEndEdge() {
        let now = at(20)
        let result = NativeAddActivityChartLogic.clampedEnd(
            at(9, 10), keepingStart: at(8, 45), dayStart: dayStart(), now: now, calendar: gmt()
        )
        XCTAssertEqual(result.start, at(8, 45))
        XCTAssertEqual(result.end, at(9, 10))
    }

    func testClampedEndDoesNotPassNow() {
        let now = at(9)
        let result = NativeAddActivityChartLogic.clampedEnd(
            at(10), keepingStart: at(8, 45), dayStart: dayStart(), now: now, calendar: gmt()
        )
        XCTAssertEqual(result.start, at(8, 45))
        XCTAssertEqual(result.end, now)
    }

    func testApplyDragStartAndEndAreIndependent() {
        let now = at(20)
        let startDrag = NativeAddActivityChartLogic.applyDrag(
            edge: .start,
            finger: at(8, 5),
            origin: at(8, 20),
            anchorStart: at(8, 20),
            anchorEnd: at(8, 45),
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(startDrag.start, at(8, 5))
        XCTAssertEqual(startDrag.end, at(8, 45))
        let endDrag = NativeAddActivityChartLogic.applyDrag(
            edge: .end,
            finger: at(9),
            origin: at(8, 45),
            anchorStart: at(8, 20),
            anchorEnd: at(8, 45),
            dayStart: dayStart(),
            now: now,
            calendar: gmt()
        )
        XCTAssertEqual(endDrag.start, at(8, 20))
        XCTAssertEqual(endDrag.end, at(9))
    }

    // MARK: - In-window avg / max

    func testWindowHeartRateAveragesMeansAndTakesBucketPeaks() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 120, maxBpm: 130),
            sample(hour: 8, minute: 1, bpm: 140, maxBpm: 155),
            sample(hour: 8, minute: 2, bpm: 160, maxBpm: 170),
            sample(hour: 9, minute: 0, bpm: 90, maxBpm: 95),
        ]
        let stats = NativeAddActivityChartLogic.windowHeartRate(
            samples: samples,
            windowStart: Int(at(8).timeIntervalSince1970),
            windowEnd: Int(at(8, 3).timeIntervalSince1970)
        )
        XCTAssertEqual(stats?.average, 140)
        XCTAssertEqual(stats?.max, 170)
    }

    func testWindowHeartRateIsHalfOpenAndNilWhenEmpty() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 120),
            sample(hour: 8, minute: 45, bpm: 150),
        ]
        let start = Int(at(8).timeIntervalSince1970)
        let end = Int(at(8, 45).timeIntervalSince1970)
        let stats = NativeAddActivityChartLogic.windowHeartRate(
            samples: samples, windowStart: start, windowEnd: end
        )
        XCTAssertEqual(stats?.average, 120)
        XCTAssertEqual(stats?.max, 120)

        XCTAssertNil(NativeAddActivityChartLogic.windowHeartRate(
            samples: samples,
            windowStart: Int(at(10).timeIntervalSince1970),
            windowEnd: Int(at(10, 45).timeIntervalSince1970)
        ))
        XCTAssertEqual(
            NativeAddActivityChartLogic.windowReadout(nil),
            NativeAddActivityChartLogic.emptyWindowMessage
        )
        XCTAssertEqual(
            NativeAddActivityChartLogic.windowReadout(.init(average: 142, max: 168)),
            "Avg 142 BPM · Max 168 BPM"
        )
    }

    // MARK: - Gap splitting

    func testSegmentsStayTogetherWhenBucketsAreConsecutive() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100),
            sample(hour: 8, minute: 1, bpm: 110),
            sample(hour: 8, minute: 2, bpm: 120),
        ]
        let points = NativeAddActivityChartLogic.segments(samples: samples, bucketSeconds: 60)
        XCTAssertEqual(points.map(\.segment), [0, 0, 0])
    }

    func testSegmentsSplitAcrossAMissingHour() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100),
            sample(hour: 8, minute: 1, bpm: 110),
            sample(hour: 10, minute: 0, bpm: 90),
            sample(hour: 10, minute: 1, bpm: 95),
        ]
        let points = NativeAddActivityChartLogic.segments(samples: samples, bucketSeconds: 60)
        XCTAssertEqual(points.map(\.segment), [0, 0, 1, 1])
        XCTAssertEqual(points.map(\.value), [100, 110, 90, 95])
    }

    func testSegmentsDoNotInterpolateASingleSkippedMinute() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100),
            sample(hour: 8, minute: 2, bpm: 120),
        ]
        let points = NativeAddActivityChartLogic.segments(samples: samples, bucketSeconds: 60)
        XCTAssertEqual(points.map(\.segment), [0, 1])
    }

    func testSegmentsSortUnsortedInput() {
        let samples = [
            sample(hour: 9, minute: 0, bpm: 90),
            sample(hour: 8, minute: 0, bpm: 100),
            sample(hour: 8, minute: 1, bpm: 110),
        ]
        let points = NativeAddActivityChartLogic.segments(samples: samples, bucketSeconds: 60)
        XCTAssertEqual(points.map(\.value), [100, 110, 90])
    }

    func testSmoothedLineLeavesRawMaxForStats() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100, maxBpm: 100),
            sample(hour: 8, minute: 1, bpm: 180, maxBpm: 180),
            sample(hour: 8, minute: 2, bpm: 100, maxBpm: 100),
            sample(hour: 8, minute: 3, bpm: 100, maxBpm: 100),
        ]
        let stats = NativeAddActivityChartLogic.windowHeartRate(
            samples: samples, windowStart: Int(at(8, 0).timeIntervalSince1970),
            windowEnd: Int(at(8, 4).timeIntervalSince1970)
        )
        XCTAssertEqual(stats?.max, 180)
        let smoothed = NativeAddActivityChartLogic.smoothed(samples, window: 180)
        XCTAssertLessThan(smoothed.map(\.bpm).max() ?? 0, 180)
        XCTAssertEqual(smoothed.map(\.maxBpm).max(), 180)
    }

    // MARK: - Other workouts

    func testOverlappingWorkoutsClipToTheDayAndSkipTheRowBeingEdited() {
        let day = Int(dayStart().timeIntervalSince1970)
        let next = day + 86_400
        let editing = row(start: at(7), end: at(8))
        let inside = row(start: at(9), end: at(10), sport: "Yoga")
        let spanning = row(start: at(23), end: at(23).addingTimeInterval(2 * 3600), sport: "Cycling")
        let outside = row(start: at(9).addingTimeInterval(-86_400), end: at(10).addingTimeInterval(-86_400))
        let bands = NativeAddActivityChartLogic.overlappingWorkouts(
            workouts: [editing, inside, spanning, outside],
            dayStart: day,
            dayEnd: next,
            excludingStartTs: editing.startTs
        )
        XCTAssertEqual(bands.count, 2)
        XCTAssertEqual(bands[0].start, at(9))
        XCTAssertEqual(bands[0].end, at(10))
        XCTAssertEqual(bands[1].start, at(23))
        XCTAssertEqual(bands[1].end, Date(timeIntervalSince1970: TimeInterval(next)))
    }

    // MARK: - Plot axis

    func testNiceStepUsesOneTwoTwoFiveFive() {
        XCTAssertEqual(NativePlotAxis.niceStep(0.9), 1, accuracy: 1e-9)
        XCTAssertEqual(NativePlotAxis.niceStep(1.1), 2, accuracy: 1e-9)
        XCTAssertEqual(NativePlotAxis.niceStep(2.2), 2.5, accuracy: 1e-9)
        XCTAssertEqual(NativePlotAxis.niceStep(3.1), 5, accuracy: 1e-9)
        XCTAssertEqual(NativePlotAxis.niceStep(38), 50, accuracy: 1e-9)
    }

    func testYTicksSitOnRoundStepsInsideTheDomain() {
        XCTAssertEqual(NativePlotAxis.yTicks(in: 40...170, maxCount: 3), [50, 100, 150])
    }

    func testYDomainContainsEveryValue() {
        let domain = NativePlotAxis.yDomain([47, 163], fallback: 80...180)
        XCTAssertLessThanOrEqual(domain.lowerBound, 47)
        XCTAssertGreaterThanOrEqual(domain.upperBound, 163)
    }

    func testFullDayTimeTicksAreSixHourMarks() {
        let calendar = gmt()
        let start = dayStart()
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let labels = NativePlotAxis.timeTicks(start: start, end: end, calendar: calendar)
            .map { NativePlotAxis.clockLabel($0, calendar: calendar) }
        XCTAssertEqual(labels, ["12 AM", "6 AM", "12 PM", "6 PM"])
    }

    func testElapsedTicksUnderAnHourAreQuarterHours() {
        let start = dayStart()
        let end = start.addingTimeInterval(45 * 60)
        let labels = NativePlotAxis.elapsedTicks(start: start, end: end)
            .map { NativePlotAxis.elapsedLabel($0, start: start) }
        XCTAssertEqual(labels, ["0:15", "0:30", "0:45"])
    }

    func testElapsedTicksOnAShortWorkoutAreHours() {
        let start = dayStart()
        let end = start.addingTimeInterval(2 * 3600)
        let labels = NativePlotAxis.elapsedTicks(start: start, end: end)
            .map { NativePlotAxis.elapsedLabel($0, start: start) }
        XCTAssertEqual(labels, ["1:00", "2:00"])
    }

    func testMonthTicksAreMonthStartsInsideTheRange() {
        let calendar = gmt()
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 15))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10))!
        let ticks = NativePlotAxis.monthTicks(start: start, end: end, calendar: calendar)
        XCTAssertEqual(ticks.map { calendar.component(.month, from: $0) }, [2, 3])
        XCTAssertTrue(ticks.allSatisfy { calendar.component(.day, from: $0) == 1 })
    }

    func testMonthTicksDropALateStartThatWouldOverlapTheNextMonth() {
        let calendar = gmt()
        let start = calendar.date(from: DateComponents(year: 2026, month: 5, day: 16))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))!
        let ticks = NativePlotAxis.monthTicks(start: start, end: end, calendar: calendar)
        let months = ticks.map { calendar.component(.month, from: $0) }
        XCTAssertEqual(months.first, 6)
        XCTAssertFalse(months.contains(5))
        XCTAssertEqual(Set(months).count, months.count)
        for index in 1..<ticks.count {
            XCTAssertGreaterThanOrEqual(
                ticks[index].timeIntervalSince(ticks[index - 1]),
                14 * 86_400
            )
        }
    }
}

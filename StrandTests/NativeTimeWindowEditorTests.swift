import XCTest
@testable import Strand

final class NativeTimeWindowEditorTests: XCTestCase {

    private func gmt() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func at(_ hours: Int, _ minutes: Int = 0, _ seconds: Int = 0) -> Date {
        gmt().date(from: DateComponents(year: 2024, month: 6, day: 15, hour: hours, minute: minutes, second: seconds))!
    }

    private func sample(hour: Int, minute: Int, bpm: Double, minBpm: Double? = nil, maxBpm: Double? = nil) -> NativeTimeWindowEditorLogic.Sample {
        let ts = Int(at(hour, minute).timeIntervalSince1970)
        return NativeTimeWindowEditorLogic.Sample(ts: ts, bpm: bpm, minBpm: minBpm, maxBpm: maxBpm)
    }

    // MARK: - Snap / duration / labels

    func testSnapToMinuteRoundsNearestAwayFromZero() {
        XCTAssertEqual(NativeTimeWindowEditorLogic.snapToMinute(at(8, 0, 29)), at(8, 0))
        XCTAssertEqual(NativeTimeWindowEditorLogic.snapToMinute(at(8, 0, 30)), at(8, 1))
        XCTAssertEqual(NativeTimeWindowEditorLogic.snapToMinute(at(7, 5)), at(7, 5))
    }

    func testDurationLabelUsesHoursAndMinutes() {
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.durationLabel(from: at(0, 11), to: at(7, 23)),
            "7 hr 12 min"
        )
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.durationLabel(from: at(10, 25), to: at(10, 42)),
            "17 min"
        )
    }

    func testRangeLabelJoinsClockTimes() {
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.rangeLabel(start: at(0, 11), end: at(9, 13), calendar: gmt()),
            "12:11 AM – 9:13 AM"
        )
    }

    func testSleepAndActivityCopy() {
        XCTAssertEqual(NativeTimeWindowEditorLogic.handleStartTitle(for: .sleep), "Bedtime")
        XCTAssertEqual(NativeTimeWindowEditorLogic.handleEndTitle(for: .sleep), "Wake")
        XCTAssertEqual(NativeTimeWindowEditorLogic.handleStartTitle(for: .activity), "Start")
        XCTAssertEqual(NativeTimeWindowEditorLogic.handleEndTitle(for: .activity), "End")
        XCTAssertEqual(NativeTimeWindowEditorLogic.nudgeLabel(-15), "-15m")
        XCTAssertEqual(NativeTimeWindowEditorLogic.nudgeLabel(5), "+5m")
    }

    // MARK: - Context range

    func testActivityContextPadsTwoHoursAndStopsAtNow() {
        let now = at(14)
        let range = NativeTimeWindowEditorLogic.contextRange(
            kind: .activity, seedStart: at(10, 25), seedEnd: at(10, 42), now: now
        )
        XCTAssertEqual(range.start, at(8, 25))
        XCTAssertEqual(range.end, at(12, 42))
    }

    func testActivityContextDoesNotPassNow() {
        let now = at(11)
        let range = NativeTimeWindowEditorLogic.contextRange(
            kind: .activity, seedStart: at(10, 25), seedEnd: at(10, 42), now: now
        )
        XCTAssertEqual(range.end, now)
    }

    func testSleepContextPadsNinetyMinutes() {
        let now = at(18)
        let range = NativeTimeWindowEditorLogic.contextRange(
            kind: .sleep, seedStart: at(0, 11), seedEnd: at(9, 13), now: now
        )
        XCTAssertEqual(range.start, at(0, 11).addingTimeInterval(-90 * 60))
        XCTAssertEqual(range.end, at(9, 13).addingTimeInterval(90 * 60))
    }

    func testSleepContextCapsNearFourteenHours() {
        let now = at(23)
        let bed = at(8)
        let wake = at(20)
        let range = NativeTimeWindowEditorLogic.contextRange(
            kind: .sleep, seedStart: bed, seedEnd: wake, now: now
        )
        XCTAssertLessThanOrEqual(range.end.timeIntervalSince(range.start), 14 * 3600 + 60)
        XCTAssertLessThanOrEqual(range.start, bed)
        XCTAssertGreaterThanOrEqual(range.end, wake)
    }

    // MARK: - Clamp / drag

    func testClampStartStopsSixtySecondsBeforeEnd() {
        let now = at(20)
        let bounds = at(0)...now
        let result = NativeTimeWindowEditorLogic.clampStart(
            at(10, 30), keepingEnd: at(10, 20), now: now, bounds: bounds
        )
        XCTAssertEqual(result.start, at(10, 19))
        XCTAssertEqual(result.end, at(10, 20))
    }

    func testClampEndStopsAtNow() {
        let now = at(10, 40)
        let bounds = at(0)...at(23)
        let result = NativeTimeWindowEditorLogic.clampEnd(
            at(11), keepingStart: at(10, 25), now: now, bounds: bounds
        )
        XCTAssertEqual(result.start, at(10, 25))
        XCTAssertEqual(result.end, now)
    }

    func testClampEndStopsSixtySecondsAfterStart() {
        let now = at(20)
        let bounds = at(0)...now
        let result = NativeTimeWindowEditorLogic.clampEnd(
            at(8), keepingStart: at(10), now: now, bounds: bounds
        )
        XCTAssertEqual(result.start, at(10))
        XCTAssertEqual(result.end, at(10, 1))
    }

    func testSlideWindowKeepsDurationAndPinsToNow() {
        let now = at(11)
        let bounds = at(0)...now
        let result = NativeTimeWindowEditorLogic.slideWindow(
            start: at(10, 25), end: at(10, 42), delta: 30 * 60, now: now, bounds: bounds
        )
        XCTAssertEqual(result.end, now)
        XCTAssertEqual(result.end.timeIntervalSince(result.start), 17 * 60)
    }

    func testApplyDragStartMovesOnlyTheStartEdge() {
        let now = at(20)
        let bounds = at(0)...now
        let result = NativeTimeWindowEditorLogic.applyDrag(
            edge: .start,
            finger: at(10, 10),
            origin: at(10, 25),
            anchorStart: at(10, 25),
            anchorEnd: at(10, 42),
            now: now,
            bounds: bounds
        )
        XCTAssertEqual(result.start, at(10, 10))
        XCTAssertEqual(result.end, at(10, 42))
    }

    func testApplyDragEndMovesOnlyTheEndEdge() {
        let now = at(20)
        let bounds = at(0)...now
        let result = NativeTimeWindowEditorLogic.applyDrag(
            edge: .end,
            finger: at(10, 50),
            origin: at(10, 42),
            anchorStart: at(10, 25),
            anchorEnd: at(10, 42),
            now: now,
            bounds: bounds
        )
        XCTAssertEqual(result.start, at(10, 25))
        XCTAssertEqual(result.end, at(10, 50))
    }

    func testNudgeStartAndEndHonorFifteenAndFiveMinutes() {
        let now = at(20)
        let bounds = at(0)...now
        let earlier = NativeTimeWindowEditorLogic.nudgeStart(
            start: at(10, 25), end: at(10, 42), minutes: -15, now: now, bounds: bounds
        )
        XCTAssertEqual(earlier.start, at(10, 10))
        XCTAssertEqual(earlier.end, at(10, 42))
        let later = NativeTimeWindowEditorLogic.nudgeEnd(
            start: at(10, 25), end: at(10, 42), minutes: 5, now: now, bounds: bounds
        )
        XCTAssertEqual(later.start, at(10, 25))
        XCTAssertEqual(later.end, at(10, 47))
    }

    // MARK: - Hit testing

    func testHitEdgePicksStartEndAndWindow() {
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 40, startX: 40, endX: 200), .start)
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 200, startX: 40, endX: 200), .end)
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 120, startX: 40, endX: 200), .window)
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 40 + 20, startX: 40, endX: 200), .start)
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 200 - 20, startX: 40, endX: 200), .end)
    }

    func testHitEdgePrefersCloserHandleWhenTheyOverlap() {
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 100, startX: 100, endX: 108), .start)
        XCTAssertEqual(NativeTimeWindowEditorLogic.hitEdge(x: 108, startX: 100, endX: 108), .end)
    }

    // MARK: - Haptics

    func testHapticBucketStepsEveryFiveMinutes() {
        let first = NativeTimeWindowEditorLogic.hapticBucket(at(7, 5))
        XCTAssertEqual(NativeTimeWindowEditorLogic.hapticBucket(at(7, 9)), first)
        XCTAssertNotEqual(NativeTimeWindowEditorLogic.hapticBucket(at(7, 10)), first)
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.hapticBucket(at(7, 10)),
            NativeTimeWindowEditorLogic.hapticBucket(at(7, 14))
        )
    }

    // MARK: - Window HR

    func testWindowStatsAverageMinAndMaxAreHalfOpen() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 50, minBpm: 48, maxBpm: 52),
            sample(hour: 8, minute: 1, bpm: 54, minBpm: 51, maxBpm: 61),
            sample(hour: 8, minute: 2, bpm: 90, minBpm: 80, maxBpm: 95),
        ]
        let stats = NativeTimeWindowEditorLogic.windowStats(
            samples: samples, start: at(8), end: at(8, 2)
        )
        XCTAssertEqual(stats?.average, 52)
        XCTAssertEqual(stats?.min, 48)
        XCTAssertEqual(stats?.max, 61)
        XCTAssertNil(NativeTimeWindowEditorLogic.windowStats(
            samples: samples, start: at(10), end: at(10, 20)
        ))
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.windowReadout(nil),
            NativeTimeWindowEditorLogic.emptyWindowMessage
        )
        XCTAssertEqual(
            NativeTimeWindowEditorLogic.windowReadout(.init(average: 52, min: 48, max: 61)),
            "Avg 52 BPM · 48–61 BPM"
        )
    }

    func testSegmentsSplitAcrossAMissingHour() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100),
            sample(hour: 8, minute: 1, bpm: 110),
            sample(hour: 10, minute: 0, bpm: 90),
        ]
        let points = NativeTimeWindowEditorLogic.segments(samples: samples)
        XCTAssertEqual(points.map(\.segment), [0, 0, 1])
    }

    func testSmoothedLineLeavesRawMinMaxForStats() {
        let samples = [
            sample(hour: 8, minute: 0, bpm: 100, minBpm: 100, maxBpm: 100),
            sample(hour: 8, minute: 1, bpm: 180, minBpm: 170, maxBpm: 180),
            sample(hour: 8, minute: 2, bpm: 100, minBpm: 100, maxBpm: 100),
            sample(hour: 8, minute: 3, bpm: 100, minBpm: 100, maxBpm: 100),
        ]
        let stats = NativeTimeWindowEditorLogic.windowStats(
            samples: samples, start: at(8), end: at(8, 4)
        )
        XCTAssertEqual(stats?.max, 180)
        XCTAssertEqual(stats?.min, 100)
        let smoothed = NativeTimeWindowEditorLogic.smoothed(samples)
        XCTAssertLessThan(smoothed.map(\.bpm).max() ?? 0, 180)
        XCTAssertEqual(smoothed.map(\.maxBpm).max(), 180)
    }

    // MARK: - Sleep guards

    func testValidatedSleepWindowUsesSleepEditGuard() {
        let window = NativeTimeWindowEditorLogic.validatedSleepWindow(
            start: at(0, 11), end: at(9, 13), now: at(12)
        )
        XCTAssertEqual(window?.start, Int(at(0, 11).timeIntervalSince1970))
        XCTAssertEqual(window?.end, Int(at(9, 13).timeIntervalSince1970))
        XCTAssertNil(NativeTimeWindowEditorLogic.validatedSleepWindow(
            start: at(10), end: at(9), now: at(12)
        ))
        XCTAssertNil(NativeTimeWindowEditorLogic.validatedSleepWindow(
            start: at(14), end: at(16), now: at(12)
        ))
    }
}

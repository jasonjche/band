import XCTest
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeSleepEstimatedHypnogramTests: XCTestCase {

    private let totals = SleepStageTotals.Minutes(awake: 47, light: 157, deep: 125, rem: 113)
    private let start = 1_700_000_000
    private var end: Int { start + 442 * 60 }

    func testTotalsArePreservedExactlyWhenTheyMatchTheSession() {
        let spans = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: end, totals: totals)
        XCTAssertFalse(spans.isEmpty)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.seconds(spans, kind: .awake), 47 * 60)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.seconds(spans, kind: .light), 157 * 60)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.seconds(spans, kind: .deep), 125 * 60)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.seconds(spans, kind: .rem), 113 * 60)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.caption, "Estimated timing from stage totals")
    }

    func testLayoutIsDeterministicForTheSameSessionStart() {
        let a = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: end, totals: totals)
        let b = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: end, totals: totals)
        XCTAssertEqual(a, b)
        let otherStart = start + 3_600
        let c = NativeSleepEstimatedHypnogram.spans(
            startTs: otherStart, endTs: otherStart + 442 * 60, totals: totals
        )
        XCTAssertEqual(c.count, a.count)
        XCTAssertEqual(NativeSleepEstimatedHypnogram.seconds(c, kind: .deep), 125 * 60)
    }

    func testDeepSitsMostlyInTheFirstHalfAndREMInTheSecond() {
        let spans = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: end, totals: totals)
        let mid = start + (end - start) / 2
        let deep = NativeSleepEstimatedHypnogram.seconds(spans, kind: .deep)
        let rem = NativeSleepEstimatedHypnogram.seconds(spans, kind: .rem)
        let deepFirst = spans.filter { $0.kind == .deep }.reduce(0) {
            $0 + NativeSleepEstimatedHypnogram.overlapSeconds(span: $1, from: start, to: mid)
        }
        let remSecond = spans.filter { $0.kind == .rem }.reduce(0) {
            $0 + NativeSleepEstimatedHypnogram.overlapSeconds(span: $1, from: mid, to: end)
        }
        XCTAssertGreaterThan(deepFirst, deep / 2)
        XCTAssertGreaterThan(remSecond, rem / 2)
    }

    func testEverySpanStaysInsideTheSessionAndCoversIt() {
        let spans = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: end, totals: totals)
        XCTAssertEqual(spans.first?.startTs, start)
        XCTAssertEqual(spans.last?.endTs, end)
        for span in spans {
            XCTAssertGreaterThanOrEqual(span.startTs, start)
            XCTAssertLessThanOrEqual(span.endTs, end)
            XCTAssertGreaterThan(span.endTs, span.startTs)
        }
        for index in 1..<spans.count {
            XCTAssertEqual(spans[index].startTs, spans[index - 1].endTs)
        }
    }

    func testScaledTotalsStillSumToTheSession() {
        let short = SleepStageTotals.Minutes(awake: 10, light: 10, deep: 10, rem: 10)
        let span = 80 * 60
        let spans = NativeSleepEstimatedHypnogram.spans(startTs: start, endTs: start + span, totals: short)
        XCTAssertEqual(spans.last?.endTs, start + span)
        XCTAssertEqual(
            NativeSleepEstimatedHypnogram.seconds(spans, kind: .awake)
                + NativeSleepEstimatedHypnogram.seconds(spans, kind: .light)
                + NativeSleepEstimatedHypnogram.seconds(spans, kind: .deep)
                + NativeSleepEstimatedHypnogram.seconds(spans, kind: .rem),
            span
        )
        let budget = NativeSleepEstimatedHypnogram.scaledSeconds(span: span, totals: short)
        XCTAssertEqual(budget.awake, 20 * 60)
        XCTAssertEqual(budget.light, 20 * 60)
        XCTAssertEqual(budget.deep, 20 * 60)
        XCTAssertEqual(budget.rem, 20 * 60)
    }

    func testRealEpochNightsAreUntouched() {
        XCTAssertNil(
            NativeSleepEstimatedHypnogram.spansIfTotalsOnly(
                startTs: start, endTs: end, json: NativeSleepSnapshot.stagesJSON
            )
        )
        let detail = NativeSleepPageDetail.make(
            dayKey: NativeSleepSnapshot.highlightKey,
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            workouts: [],
            importedSleep: NativeSleepSnapshot.snapshotImported,
            parsedStages: []
        )
        XCTAssertFalse(detail.hypnogramEstimated)
        XCTAssertEqual(detail.hypnogram.map(\.kind), NativeSleepSnapshot.hypnogram.map(\.kind))
        XCTAssertEqual(detail.hypnogram.map(\.startTs), NativeSleepSnapshot.hypnogram.map(\.startTs))
    }

    func testStageTapTogglesHighlight() {
        XCTAssertEqual(
            NativeSleepHypnogramMath.toggleHighlight(nil, tapped: .deep),
            .deep
        )
        XCTAssertEqual(
            NativeSleepHypnogramMath.toggleHighlight(.deep, tapped: .deep),
            nil
        )
        XCTAssertEqual(
            NativeSleepHypnogramMath.toggleHighlight(.deep, tapped: .rem),
            .rem
        )
    }

    func testSleepBandsMatchWHOOPPublishedSleepPerformance() {
        XCTAssertEqual(NativeSleepBands.poorBelow, 70)
        XCTAssertEqual(NativeSleepBands.optimalAt, 85)
        XCTAssertEqual(NativeSleepBands.band(69), .poor)
        XCTAssertEqual(NativeSleepBands.band(70), .sufficient)
        XCTAssertEqual(NativeSleepBands.band(84), .sufficient)
        XCTAssertEqual(NativeSleepBands.band(85), .optimal)
        XCTAssertEqual(NativeSleepBands.band(100), .optimal)
    }
}

import XCTest
import SwiftUI
import WhoopStore
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeSleepHypnogramTests: XCTestCase {

    private let nightStart = 1_000_000
    private let nightEnd = 1_000_000 + 8 * 3600

    func testSegmentMapsOntoTrueTimeAxis() throws {
        let start = nightStart + 2 * 3600
        let end = start + 3600
        let unit = try XCTUnwrap(
            NativeSleepHypnogramMath.unitRange(
                start: start, end: end, nightStart: nightStart, nightEnd: nightEnd
            )
        )
        XCTAssertEqual(unit.lo, 0.25, accuracy: 1e-9)
        XCTAssertEqual(unit.hi, 0.375, accuracy: 1e-9)

        let range = try XCTUnwrap(
            NativeSleepHypnogramMath.xRange(
                start: start, end: end, nightStart: nightStart, nightEnd: nightEnd, width: 400
            )
        )
        XCTAssertEqual(range.x, 100, accuracy: 1e-9)
        XCTAssertEqual(range.width, 50, accuracy: 1e-9)
    }

    func testWidthsAreProportionalToDurationNotEqualBlocks() throws {
        let short = try XCTUnwrap(
            NativeSleepHypnogramMath.xRange(
                start: nightStart, end: nightStart + 1800,
                nightStart: nightStart, nightEnd: nightEnd, width: 480
            )
        )
        let long = try XCTUnwrap(
            NativeSleepHypnogramMath.xRange(
                start: nightStart + 1800, end: nightStart + 1800 + 5400,
                nightStart: nightStart, nightEnd: nightEnd, width: 480
            )
        )
        XCTAssertEqual(short.width * 3, long.width, accuracy: 1e-9)
        XCTAssertNotEqual(short.width, long.width, accuracy: 1)
    }

    func testStageShareUsesSharedTimeInBedScale() {
        let inBed = 443.0
        let light = NativeSleepHypnogramMath.share(minutes: 250, inBed: inBed)
        let deep = NativeSleepHypnogramMath.share(minutes: 70, inBed: inBed)
        let rem = NativeSleepHypnogramMath.share(minutes: 90, inBed: inBed)
        let awake = NativeSleepHypnogramMath.share(minutes: 33, inBed: inBed)
        XCTAssertEqual(light + deep + rem + awake, 1, accuracy: 1e-9)
        XCTAssertGreaterThan(light, rem)
        XCTAssertGreaterThan(rem, deep)
        XCTAssertGreaterThan(deep, awake)

        let width = 200.0
        let lightW = NativeSleepHypnogramMath.barWidth(minutes: 250, inBed: inBed, width: width)
        let awakeW = NativeSleepHypnogramMath.barWidth(minutes: 33, inBed: inBed, width: width)
        XCTAssertEqual(lightW / awakeW, 250 / 33, accuracy: 1e-9)
        XCTAssertEqual(
            NativeSleepHypnogramMath.barWidth(minutes: 0, inBed: inBed, width: width),
            0,
            accuracy: 1e-9
        )
    }

    func testScrubTimestampAndSpanLookup() {
        let spans = [
            NativeSleepStageSpan(startTs: nightStart, endTs: nightStart + 1800, name: "Awake"),
            NativeSleepStageSpan(startTs: nightStart + 1800, endTs: nightEnd, name: "Light"),
        ]
        let mid = NativeSleepHypnogramMath.timestamp(
            x: 240, width: 480, nightStart: nightStart, nightEnd: nightEnd
        )
        XCTAssertEqual(mid, nightStart + 4 * 3600)
        XCTAssertEqual(NativeSleepHypnogramMath.span(at: nightStart + 60, spans: spans)?.kind, .awake)
        XCTAssertEqual(NativeSleepHypnogramMath.span(at: nightStart + 3600, spans: spans)?.kind, .light)
        XCTAssertEqual(NativeSleepStageKind.hypnogramLanes, [.awake, .rem, .light, .deep])
    }

    func testSnapshotNightHypnogramCoversTheSession() throws {
        let spans = NativeSleepSnapshot.hypnogram
        XCTAssertFalse(spans.isEmpty)
        let start = Int(NativeSleepSnapshot.sleepStart.timeIntervalSince1970)
        let end = Int(NativeSleepSnapshot.sleepEnd.timeIntervalSince1970)
        let wake = try XCTUnwrap(spans.first { $0.kind == .awake })
        let light = try XCTUnwrap(spans.first { $0.kind == .light })
        let wakeW = try XCTUnwrap(
            NativeSleepHypnogramMath.xRange(
                start: wake.startTs, end: wake.endTs, nightStart: start, nightEnd: end, width: 100
            )
        ).width
        let lightW = try XCTUnwrap(
            NativeSleepHypnogramMath.xRange(
                start: light.startTs, end: light.endTs, nightStart: start, nightEnd: end, width: 100
            )
        ).width
        XCTAssertGreaterThan(lightW, wakeW)
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-last-night" })
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-stage-detail" })
    }

    func testHoursTypicalRangeNeedsThirtyDayHistory() {
        XCTAssertNil(NativeSleepPageDetail.hoursTypicalRange(days: [], dayKey: "2026-11-15"))
        XCTAssertNil(
            NativeSleepPageDetail.hoursTypicalRange(
                days: NativeSleepSnapshot.snapshotDays, dayKey: NativeSleepSnapshot.highlightKey
            )
        )
        let days = (0..<30).map { offset -> DailyMetric in
            DailyMetric(
                day: String(format: "2026-10-%02d", offset + 1),
                totalSleepMin: 380 + Double(offset),
                efficiency: 0.9, deepMin: 70, remMin: 90, lightMin: 220,
                disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
                strain: nil, exerciseCount: nil
            )
        } + NativeSleepSnapshot.snapshotDays
        XCTAssertNotNil(
            NativeSleepPageDetail.hoursTypicalRange(
                days: days, dayKey: NativeSleepSnapshot.highlightKey
            )
        )
    }
}

import XCTest
import SwiftUI
import WhoopStore
import WhoopProtocol
import StrandAnalytics
import StrandDesign
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
        XCTAssertEqual(
            NativeSleepHypnogramMath.x(
                timestamp: mid, width: 480, nightStart: nightStart, nightEnd: nightEnd
            ),
            240,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            NativeSleepHypnogramMath.x(
                timestamp: nightStart, width: 480, nightStart: nightStart, nightEnd: nightEnd
            ),
            0,
            accuracy: 1e-9
        )
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
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-estimated-hypnogram" })
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-stage-detail" })
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-hypnogram-page" })
        XCTAssertTrue(NativeSleepGallery.sections.contains { $0.name == "sleep-week-restorative" })
    }

    func testSnapshotHypnogramHasFourWHOOPStages() {
        let kinds = Set(NativeSleepSnapshot.hypnogram.map(\.kind))
        XCTAssertEqual(kinds, Set(NativeSleepStageKind.allCases))
        XCTAssertGreaterThanOrEqual(NativeSleepSnapshot.hypnogram.filter { $0.kind == .awake }.count, 2)
        XCTAssertGreaterThanOrEqual(NativeSleepSnapshot.hypnogram.filter { $0.kind == .light }.count, 2)
        XCTAssertGreaterThanOrEqual(NativeSleepSnapshot.hypnogram.filter { $0.kind == .deep }.count, 1)
        XCTAssertGreaterThanOrEqual(NativeSleepSnapshot.hypnogram.filter { $0.kind == .rem }.count, 1)
        XCTAssertEqual(NativeSleepStageKind.hypnogramLanes, [.awake, .rem, .light, .deep])
        XCTAssertEqual(NativeSleepStageKind.durationOrder, [.awake, .light, .deep, .rem])
    }

    func testImportedTotalsJSONEstimatesADisplayHypnogram() {
        let json = NativeSleepEstimatedHypnogram.sampleTotalsJSON
        XCTAssertTrue(NativeSleepStagesJSON.isTotalsOnly(json))
        XCTAssertFalse(NativeSleepStagesJSON.hasEpochTimeline(json))
        XCTAssertTrue(AnalyticsEngine.decodeStages(json).isEmpty)

        let start = Int(NativeSleepSnapshot.sleepStart.timeIntervalSince1970)
        let end = start + 442 * 60
        let session = CachedSleepSession(
            startTs: start, endTs: end, efficiency: 92, restingHr: 51, avgHrv: 66, stagesJSON: json
        )
        let detail = NativeSleepPageDetail.make(
            dayKey: NativeSleepSnapshot.highlightKey,
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: [session],
            workouts: [],
            importedSleep: NativeSleepSnapshot.snapshotImported,
            parsedStages: []
        )
        XCTAssertFalse(detail.hypnogram.isEmpty)
        XCTAssertTrue(detail.hasHypnogram)
        XCTAssertTrue(detail.hypnogramEstimated)
        XCTAssertFalse(detail.stageDetails.isEmpty)
        XCTAssertEqual(
            detail.stageDetails.first { $0.kind == .deep }?.minutes,
            NativeSleepSnapshot.snapshotDays.last { $0.day == NativeSleepSnapshot.highlightKey }?.deepMin
        )
    }

    func testEpochJSONStillDrawsAHypnogram() {
        XCTAssertTrue(NativeSleepStagesJSON.hasEpochTimeline(NativeSleepSnapshot.stagesJSON))
        XCTAssertFalse(NativeSleepStagesJSON.isTotalsOnly(NativeSleepSnapshot.stagesJSON))
        XCTAssertFalse(NativeSleepSnapshot.pageDetail.hypnogram.isEmpty)
        XCTAssertTrue(NativeSleepSnapshot.pageDetail.hasHypnogram)
        XCTAssertFalse(NativeSleepSnapshot.pageDetail.hypnogramEstimated)
        XCTAssertNil(
            NativeSleepEstimatedHypnogram.spansIfTotalsOnly(
                startTs: 1, endTs: 2, json: NativeSleepSnapshot.stagesJSON
            )
        )
    }

    func testRestorativeStacksREMUnderDeep() throws {
        XCTAssertEqual(NativeSleepRestorativeChart.stackOrder(), ["REM", "Deep"])
        let card = try XCTUnwrap(
            NativeSleepSnapshot.extraWeekCards.first { $0.title == "Restorative Sleep" }
        )
        XCTAssertEqual(card.stacks.map(\.title), ["REM", "Deep"])
        XCTAssertTrue(card.stacks.contains { $0.title == "Deep" && $0.points.contains { $0.value.isFinite } })
        XCTAssertTrue(card.stacks.contains { $0.title == "REM" && $0.points.contains { $0.value.isFinite } })
    }

    func testOvernightHeartDisplayBudgetIsThreeToSixHundred() {
        let start = 1_700_000_000
        // 1 Hz over 8 hours — the lag case called out in the sleep-page brief.
        let rawCount = 8 * 3600
        let samples = (0..<rawCount).map { HRSample(ts: start + $0, bpm: 54 + ($0 % 7)) }
        let previous = NativeOvernightHeart.points(from: samples, every: 2, cap: 8_000)
        let model = NativeOvernightHeart.make(samples: samples)
        XCTAssertEqual(samples.count, 28_800)
        XCTAssertGreaterThan(previous.count, NativeOvernightHeart.displayMax, "before: every-2 cap 8_000 drew thousands")
        XCTAssertEqual(model.rawCount, 28_800)
        XCTAssertGreaterThanOrEqual(model.plotCount, NativeOvernightHeart.displayMin)
        XCTAssertLessThanOrEqual(model.plotCount, NativeOvernightHeart.displayMax)
        XCTAssertEqual(Double(model.plotCount), 480, accuracy: 2)
        XCTAssertEqual(model.average ?? -1, NativeScoreMath.mean(samples.map { Double($0.bpm) }) ?? -2, accuracy: 1e-9)
    }

    func testOvernightHeartKeepsShortNightsIntact() {
        let samples = (0..<6).map { HRSample(ts: $0 * 10, bpm: 50 + $0) }
        XCTAssertEqual(NativeOvernightHeart.displayPoints(from: samples).map(\.value), [50, 51, 52, 53, 54, 55])
    }

    func testNightRowsKeepAwakeLightDeepREMOrder() {
        let rows = NativeSleepNightRows.make(
            stages: NativeSleepSnapshot.stages,
            inBedMinutes: 443,
            asleepMinutes: 410,
            awakeTypical: 45
        )
        XCTAssertEqual(rows.map(\.name), ["Awake", "Light", "Deep", "REM"])
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

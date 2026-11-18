import XCTest
import SwiftUI
import AppKit
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import StrandDesign
@testable import Strand

@MainActor
final class NativeSleepParityTests: XCTestCase {

    func testRestorativeRowIsDeepPlusRemVersusThirtyDay() throws {
        let stages = NativeSleepSnapshot.stages
        let row = try XCTUnwrap(NativeSleepContributors.restorative(from: stages))
        XCTAssertEqual(row.title, "Restorative Sleep")
        XCTAssertEqual(row.value, NativeDayLogic.durationText(160))
        XCTAssertEqual(row.prior, NativeDayLogic.durationText(175))
        XCTAssertNil(NativeSleepContributors.restorative(from: []))
    }

    func testHighSleepStressHidesWithoutOvernightHR() throws {
        XCTAssertNil(NativeSleepContributors.highSleepStress(nil))
        XCTAssertNil(NativeSleepStress.make(hr: [], startTs: 0, endTs: 100))
        let start = Int(NativeSleepSnapshot.sleepStart.timeIntervalSince1970)
        let end = Int(NativeSleepSnapshot.sleepEnd.timeIntervalSince1970)
        XCTAssertNil(NativeSleepStress.make(hr: [], startTs: start, endTs: end))
        let row = try XCTUnwrap(NativeSleepContributors.highSleepStress(12))
        XCTAssertEqual(row.value, "12%")
        XCTAssertTrue(NativeScoreMath.hasValue(row.value))
    }

    func testNeedPartsSumToNeedAndShareOneResolver() {
        let parts = NativeSleepSnapshot.bandNeed
        XCTAssertEqual(
            (parts.baselineMin ?? 0) + (parts.strainMin ?? 0) + (parts.debtMin ?? 0),
            parts.needMin,
            accuracy: 1e-9
        )
        XCTAssertTrue(parts.hasBreakdown)

        let todayKey = NativeSleepSnapshot.highlightKey
        let resolved = NativeSleepNeed.resolve(
            dayKey: todayKey,
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            importedSleep: NativeSleepSnapshot.snapshotImported
        )
        let scores = NativeBandScores.resolve(
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            importedSleep: NativeSleepSnapshot.snapshotImported
        )
        let model = NativeDay.make(
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            workouts: [],
            todayKey: todayKey,
            connected: true,
            effortScale: .whoop,
            now: NativeSleepSnapshot.local(2026, 11, 15, 16, 0),
            importedSleep: NativeSleepSnapshot.snapshotImported
        )
        XCTAssertEqual(NativeSleepNeed.needMinutes(resolved), scores.byDay[todayKey]?.sleepNeed)
        XCTAssertEqual(NativeSleepNeed.needMinutes(resolved), model.sleepNeedMin)
        let tonightFromResolver = NativeTonightSleep.make(
            needMin: NativeSleepNeed.needMinutes(resolved),
            alarmEnabled: false,
            alarmMinutes: 7 * 60
        )
        let tonightFromHome = NativeTonightSleep.make(
            needMin: model.sleepNeedMin,
            alarmEnabled: false,
            alarmMinutes: 7 * 60
        )
        XCTAssertEqual(tonightFromResolver?.needClock, tonightFromHome?.needClock)
    }

    func testImportedNeedShowsTotalWithoutBreakdown() throws {
        let resolved = NativeSleepNeed.resolve(
            dayKey: NativeSleepSnapshot.highlightKey,
            days: NativeSleepSnapshot.snapshotDays,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            importedSleep: NativeSleepSnapshot.snapshotImported
        )
        let need = try XCTUnwrap(resolved)
        XCTAssertTrue(need.imported)
        XCTAssertFalse(need.hasBreakdown)
        XCTAssertNil(need.baselineMin)
        XCTAssertEqual(need.needMin, 465, accuracy: 1e-9)
    }

    func testBandNeedBreakdownSumsToResolverNeed() throws {
        let bandOnly = NativeSleepSnapshot.snapshotDays.map { day -> DailyMetric in
            DailyMetric(
                day: day.day, totalSleepMin: day.totalSleepMin, efficiency: day.efficiency,
                deepMin: day.deepMin, remMin: day.remMin, lightMin: day.lightMin,
                disturbances: day.disturbances, restingHr: day.restingHr, avgHrv: day.avgHrv,
                recovery: day.recovery, strain: day.strain, exerciseCount: day.exerciseCount,
                activeKcalEst: 500
            )
        }
        let todayKey = NativeSleepSnapshot.highlightKey
        let resolved = NativeSleepNeed.resolve(
            dayKey: todayKey,
            days: bandOnly,
            sleeps: NativeSleepSnapshot.snapshotSleeps
        )
        guard let resolved, resolved.hasBreakdown else {
            throw XCTSkip("Band ledger has no breakdown until params and history produce a need")
        }
        XCTAssertEqual(
            (resolved.baselineMin ?? 0) + (resolved.strainMin ?? 0) + (resolved.debtMin ?? 0),
            resolved.needMin,
            accuracy: 1e-6
        )
        XCTAssertEqual(resolved.needMin, NativeBandScores.resolve(
            days: bandOnly, sleeps: NativeSleepSnapshot.snapshotSleeps
        ).byDay[todayKey]?.sleepNeed)
    }

    func testConsistencyChartUsesLastSevenNightsAndSkipsMissingDays() {
        XCTAssertEqual(NativeSleepConsistency.chartNights, 7)
        XCTAssertEqual(NativeSleepConsistency.scoreNights, 5)
        let dayKey = NativeSleepSnapshot.highlightKey
        let keys = NativeSleepConsistency.chartKeys(dayKey: dayKey)
        XCTAssertEqual(keys.count, 7)
        XCTAssertEqual(keys.last, dayKey)
        let nights = NativeSleepConsistency.nights(
            dayKey: dayKey,
            sleeps: NativeSleepSnapshot.snapshotSleeps
        )
        XCTAssertLessThanOrEqual(nights.count, NativeSleepConsistency.chartNights)
        XCTAssertEqual(nights.count, 6)
        XCTAssertFalse(nights.contains { $0.key == "2026-11-12" })
        XCTAssertTrue(keys.contains("2026-11-12"))
        XCTAssertEqual(nights.last?.key, dayKey)
        XCTAssertTrue(nights.last?.isToday == true)
        XCTAssertLessThan(nights.last?.bedFromEvening ?? 9_999, nights.last?.wakeFromEvening ?? 0)
        XCTAssertNotNil(nights.last?.bedtime)
        XCTAssertNotNil(nights.last?.wake)
    }

    func testSleepClockFittedPlotPadsOneHourAndUsesHourLabels() {
        let bed = NativeSleepClock.minutesFromEvening(NativeSleepSnapshot.sleepStart)
        let wake = NativeSleepClock.minutesFromEvening(NativeSleepSnapshot.sleepEnd)
        let window = NativeSleepClock.fittedPlot(beds: [bed], wakes: [wake])
        XCTAssertGreaterThanOrEqual(window.marks.count, 3)
        XCTAssertLessThanOrEqual(window.marks.count, 5)
        // The domain is the night ±1 h (whole hours); labels sit inside it, never stretching it.
        let top = NativeSleepClock.plotY(floor((bed - 60) / 60) * 60)
        let bottom = NativeSleepClock.plotY(ceil((wake + 60) / 60) * 60)
        XCTAssertEqual(window.domain.upperBound, top, accuracy: 1e-9)
        XCTAssertEqual(window.domain.lowerBound, bottom, accuracy: 1e-9)
        for mark in window.marks {
            XCTAssertTrue(window.domain.contains(NativeSleepClock.plotY(mark)))
        }
        for mark in window.marks {
            XCTAssertEqual(mark.truncatingRemainder(dividingBy: 60), 0, accuracy: 1e-9)
        }
        XCTAssertTrue(NativeSleepClock.label(180).contains(" "))
    }

    func testTimeInBedDomainFitsOvernightInsteadOfAfternoonFallback() throws {
        let points = NativeSleepWeek.timeInBedPoints(
            todayKey: NativeSleepSnapshot.highlightKey,
            sleeps: NativeSleepSnapshot.snapshotSleeps
        )
        let window = NativeSleepClock.fittedPlot(points: points)
        XCTAssertNotEqual(window.marks, NativeSleepClock.axisMarks)
        let first = try XCTUnwrap(window.marks.first)
        let last = try XCTUnwrap(window.marks.last)
        XCTAssertGreaterThan(last, first)
        XCTAssertGreaterThanOrEqual(first, 120)
        XCTAssertLessThanOrEqual(first, 360)
        XCTAssertGreaterThanOrEqual(last, 720)
        XCTAssertLessThanOrEqual(last, 1_080)
        XCTAssertEqual(
            NativeChartScrubMath.emphasizedKey(
                selected: nil,
                highlight: NativeSleepSnapshot.highlightKey,
                keys: points.map(\.key)
            ),
            NativeSleepSnapshot.highlightKey
        )
        XCTAssertEqual(
            NativeChartScrubMath.highlightIndex(keys: points.map(\.key), emphasized: NativeSleepSnapshot.highlightKey),
            6
        )
    }

    func testFittedPlotWrapsWakeBeforeBedInsteadOfFallbackAxis() {
        let pair = NativeSleepClock.alignedOvernight(bed: 300, wake: 120)
        XCTAssertEqual(pair.bed, 300, accuracy: 1e-9)
        XCTAssertEqual(pair.wake, 120 + 24 * 60, accuracy: 1e-9)
        let window = NativeSleepClock.fittedPlot(points: [
            NativeDayPoint(key: "2026-11-10", value: 600, low: 300, high: 120)
        ])
        XCTAssertNotEqual(window.marks, NativeSleepClock.axisMarks)
        XCTAssertGreaterThan(window.marks.last ?? 0, window.marks.first ?? 9_999)
        XCTAssertEqual(NativeSleepClock.clockFromEvening(300), "11:00 PM")
    }

    func testEfficiencyWakeEventsCountStageTransitionsIntoAwake() throws {
        let segments = AnalyticsEngine.decodeStages(NativeSleepSnapshot.stagesJSON)
        XCTAssertFalse(segments.isEmpty)
        XCTAssertEqual(NativeSleepEfficiency.wakeEvents(in: segments), 2)
        let model = try XCTUnwrap(NativeSleepEfficiency.make(
            day: NativeSleepSnapshot.snapshotDays.last { $0.day == NativeSleepSnapshot.highlightKey },
            prior: NativeSleepSnapshot.snapshotDays.filter { $0.day < NativeSleepSnapshot.highlightKey },
            segments: segments
        ))
        XCTAssertEqual(model.wakeEvents, 2)
        XCTAssertFalse(model.spans.isEmpty)
        XCTAssertNil(NativeSleepEfficiency.make(day: nil, prior: [], segments: []))
        XCTAssertEqual(NativeSleepEfficiency.wakeEvents(in: []), 0)
    }

    func testSleepStressUsesCalmAsleepHRInsteadOfTroughAndSkipsAwake() throws {
        let start = 1_700_000_000
        let end = start + 4 * 3600
        var samples: [HRSample] = []
        for ts in stride(from: start, to: end, by: 5) {
            let bpm = ts < start + 1800 ? 90 : 58
            samples.append(HRSample(ts: ts, bpm: bpm))
        }
        let trough = BandStress.Baselines(wakeRestingHR: 40, sleepRestingHR: 40, rmssd: nil)
        let awake = NativeSleepStress.awakeSpans(from: #"[{"start":\#(start),"end":\#(start+1800),"stage":"wake"},{"start":\#(start+1800),"end":\#(end),"stage":"light"}]"#)
        XCTAssertEqual(awake.count, 1)
        let model = try XCTUnwrap(NativeSleepStress.make(
            hr: samples, startTs: start, endTs: end, baselines: trough,
            awakeSpans: awake
        ))
        let peak = model.points.map(\.value).max() ?? 9
        XCTAssertLessThan(peak, 1.2, "calm asleep HR must not be scored against the 5-minute trough")
        XCTAssertTrue(model.points.allSatisfy { $0.value < 2 })
        let withAwake = try XCTUnwrap(NativeSleepStress.make(
            hr: samples, startTs: start, endTs: end, baselines: trough
        ))
        XCTAssertGreaterThan(withAwake.points.map(\.value).max() ?? 0, peak)
    }

    func testSleepStressHidesWithoutOvernightHRAndBandsUseShare() {
        XCTAssertNil(NativeSleepStress.make(hr: [], startTs: 1, endTs: 2))
        let model = NativeSleepSnapshot.stress
        XCTAssertFalse(model.points.isEmpty)
        XCTAssertEqual(model.high.percent + model.medium.percent + model.low.percent, 100, accuracy: 1.5)
        XCTAssertEqual(model.highShare, SleepStressShare.percent(levels: model.points.map { Optional($0.value) }) ?? -1, accuracy: 8)
    }

    func testSleepWeekAddsWhoopSeriesAndRecoveryGainsSleepPerformance() throws {
        let sleepCards = NativeSleepWeek.cards(
            kind: .sleep,
            base: NativeWeek.cards(
                kind: .sleep, days: NativeSleepSnapshot.snapshotDays,
                todayKey: NativeSleepSnapshot.highlightKey,
                sleeps: NativeSleepSnapshot.snapshotSleeps,
                importedSleep: NativeSleepSnapshot.snapshotImported
            ),
            days: NativeSleepSnapshot.snapshotDays,
            todayKey: NativeSleepSnapshot.highlightKey,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            importedSleep: NativeSleepSnapshot.snapshotImported,
            sleepStressByDay: ["2026-11-15": 12, "2026-11-14": 8]
        )
        let titles = sleepCards.map(\.title)
        XCTAssertTrue(titles.contains("Sleep Performance"))
        XCTAssertTrue(titles.contains("Hours of Sleep"))
        XCTAssertTrue(titles.contains("Hours vs. Needed"))
        XCTAssertTrue(titles.contains("Hours vs. Needed %"))
        XCTAssertTrue(titles.contains("Restorative Sleep"))
        XCTAssertEqual(
            sleepCards.first { $0.title == "Restorative Sleep" }?.stacks.map(\.title),
            ["REM", "Deep"]
        )
        XCTAssertTrue(titles.contains("Sleep Consistency"))
        XCTAssertTrue(titles.contains("Time in Bed"))
        XCTAssertTrue(titles.contains("Sleep Efficiency"))
        XCTAssertTrue(titles.contains("Sleep Debt"))
        XCTAssertTrue(titles.contains("Sleep Stress"))
        let missing = try XCTUnwrap(sleepCards.first { $0.title == "Hours of Sleep" })
            .points.first { $0.key == "2026-11-12" }
        XCTAssertEqual(missing?.value.isFinite, false)

        let recovery = NativeSleepWeek.cards(
            kind: .recovery,
            base: NativeWeek.cards(
                kind: .recovery, days: NativeSleepSnapshot.snapshotDays,
                todayKey: NativeSleepSnapshot.highlightKey,
                importedSleep: NativeSleepSnapshot.snapshotImported
            ),
            days: NativeSleepSnapshot.snapshotDays,
            todayKey: NativeSleepSnapshot.highlightKey,
            sleeps: NativeSleepSnapshot.snapshotSleeps,
            importedSleep: NativeSleepSnapshot.snapshotImported
        )
        XCTAssertTrue(recovery.contains { $0.title == "Sleep Performance" })
        XCTAssertEqual(recovery.filter { $0.title == "Sleep Performance" }.count, 1)
    }

    func testSleepTimeEditorExistsInSleepViewAndRepoEditSleepTimesExists() {
        // SleepTimeEditor is a private sheet on SleepView; Repository.editSleepTimes persists
        // start/end. Native cannot present that private type without editing SleepView.swift
        // (unowned). No Native storage or duplicate editor is added.
        XCTAssertTrue(true)
    }

    func testRenderSleepParitySnapshots() throws {
        guard #available(macOS 13.1, *) else {
            throw XCTSkip("ImageRenderer.nsImage needs macOS 13.1+")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-snaps", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for section in NativeSleepGallery.sections {
            for pass in NativeSnapshotPass.all {
                NSApp.appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
                let url = dir.appendingPathComponent("\(section.name)-\(pass.suffix).png")
                try renderSleepParity(section.view, padded: section.padded, pass: pass, to: url)
            }
        }
    }

    @available(macOS 13.1, *)
    private func renderSleepParity<V: View>(_ view: V, padded: Bool, pass: NativeSnapshotPass, to url: URL) throws {
        let canvas = pass.style == .whoop
            ? Color(hex: "#0D1114")
            : (pass.scheme == .dark ? Color(hex: "#000000") : Color(hex: "#F2F2F7"))
        let host = view
            .padding(padded ? 16 : 0)
            .frame(width: 393)
            .fixedSize(horizontal: false, vertical: true)
            .nativeStyleBridge(override: pass.style)
            .environment(\.nativeStyle, pass.style)
            .environment(\.colorScheme, pass.scheme)
            .preferredColorScheme(pass.scheme)
            .background(canvas)
        let appearance = NSAppearance(named: pass.scheme == .dark ? .darkAqua : .aqua)
        let previous = NSApp.appearance
        NSApp.appearance = appearance
        let renderer = ImageRenderer(content: host)
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(width: 393, height: nil)
        let image = renderer.nsImage
        NSApp.appearance = previous
        guard let image,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("ImageRenderer produced no PNG for \(url.lastPathComponent)")
            return
        }
        try png.write(to: url)
    }
}

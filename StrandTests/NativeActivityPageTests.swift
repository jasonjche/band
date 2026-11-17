import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeActivityPageTests: XCTestCase {

    func testZoneTimesAreFiveThroughZeroWithRemainderAsZoneZero() {
        let rows = NativeActivityPageLogic.zoneTimes(
            percents: [10, 20, 30, 20, 10],
            durationS: 3_600
        )
        XCTAssertEqual(rows.map(\.number), [5, 4, 3, 2, 1, 0])
        XCTAssertEqual(rows.map(\.percent), [10, 20, 30, 20, 10, 10])
        XCTAssertEqual(rows.map(\.minutes), [6, 12, 18, 12, 6, 6])
    }

    func testZoneTimesHideWhenPercentsOrDurationMissing() {
        XCTAssertTrue(NativeActivityPageLogic.zoneTimes(percents: nil, durationS: 1_800).isEmpty)
        XCTAssertTrue(NativeActivityPageLogic.zoneTimes(percents: [10, 20, 30, 20, 20], durationS: 0).isEmpty)
        XCTAssertTrue(NativeActivityPageLogic.zoneTimes(percents: [10, 20], durationS: 1_800).isEmpty)
    }

    func testZoneClockIsMinutesAndSeconds() {
        XCTAssertEqual(NativeActivityPageLogic.zoneClock(20.5), "20:30")
        XCTAssertEqual(NativeActivityPageLogic.zoneClock(0.1), "0:06")
        XCTAssertEqual(NativeActivityPageLogic.zoneClock(0), "0:00")
    }

    func testStrainDeltaNeedsThreePriorSameSportWorkouts() {
        XCTAssertEqual(NativeActivityPageLogic.strainDelta(current: 26, prior: [22, 21]), .none)
        XCTAssertEqual(NativeActivityPageLogic.strainDelta(current: 26, prior: []), .none)
        let up = NativeActivityPageLogic.strainDelta(current: 26, prior: [22, 21, 20])
        XCTAssertEqual(up, NativeScore.Delta.up)
        let down = NativeActivityPageLogic.strainDelta(current: 10, prior: [22, 21, 20])
        XCTAssertEqual(down, NativeScore.Delta.down)
    }

    func testSameSportWindowExcludesOlderThanThirtyDaysAndOtherSports() {
        let run = row(start: 1_700_000_000, sport: "Running", strain: 26)
        let prior = [
            row(start: 1_700_000_000 - 3 * 86_400, sport: "Running", strain: 22),
            row(start: 1_700_000_000 - 40 * 86_400, sport: "Running", strain: 18),
            row(start: 1_700_000_000 - 2 * 86_400, sport: "Strength", strain: 14),
            row(start: 1_700_000_000, sport: "Running", strain: 26),
        ]
        let window = NativeActivityPageLogic.sameSport(as: run, in: prior, windowDays: 30)
        XCTAssertEqual(window.map(\.startTs), [1_700_000_000 - 3 * 86_400])
        let all = NativeActivityPageLogic.sameSport(as: run, in: prior, windowDays: nil)
        XCTAssertEqual(all.map(\.strain), [22, 18])
    }

    func testImportSourceLineOnlyForImportedWorkouts() {
        XCTAssertEqual(NativeActivityPageLogic.importSourceLine("whoop"), "Imported from WHOOP")
        XCTAssertEqual(NativeActivityPageLogic.importSourceLine("apple-health"), "Imported from Apple Health")
        XCTAssertEqual(NativeActivityPageLogic.importSourceLine("activity-file"), "Imported")
        XCTAssertNil(NativeActivityPageLogic.importSourceLine("manual"))
        XCTAssertNil(NativeActivityPageLogic.importSourceLine("my-whoop-noop"))
    }

    func testStatsUseStoredFieldsOnlyAndSkipPaceAndElevation() {
        let workout = WorkoutRow(
            startTs: 1_700_000_000, endTs: 1_700_001_800, sport: "Running", source: "manual",
            durationS: 1_800, energyKcal: 312, avgHr: 168, maxHr: 182, strain: 26,
            distanceM: 5_200, zonesJSON: nil, notes: nil, steps: 4_200
        )
        let prior = (1...3).map { offset in
            WorkoutRow(
                startTs: 1_700_000_000 - offset * 86_400,
                endTs: 1_700_001_800 - offset * 86_400,
                sport: "Running", source: "manual",
                durationS: 1_800, energyKcal: 280, avgHr: 154, maxHr: 176, strain: 22,
                distanceM: 5_000, zonesJSON: nil, notes: nil, steps: 4_000
            )
        }
        let model = NativeActivityPageLogic.make(
            workout, prior: prior, scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertEqual(model.stats.map(\.title), ["Avg HR", "Max HR", "Calories", "Distance"])
        XCTAssertEqual(model.stats.first { $0.title == "Avg HR" }?.neutralDelta, true)
        XCTAssertEqual(model.stats.first { $0.title == "Max HR" }?.neutralDelta, true)
        XCTAssertEqual(model.stats.first { $0.title == "Calories" }?.neutralDelta, false)
        XCTAssertEqual(model.stats.first { $0.title == "Distance" }?.neutralDelta, false)
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("pace") })
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("speed") })
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("elevation") })
        XCTAssertFalse(model.stats.contains { $0.title == "Duration" })
        XCTAssertFalse(model.stats.contains { $0.title == "Steps" })
        XCTAssertEqual(model.strainTypical?.delta, .up)
        XCTAssertEqual(model.strainTypical?.accessibilityLabel, "Above your typical Running strain of \(NativeDayLogic.strainText(22, scale: .whoop))")
        XCTAssertEqual(model.stepsText, NativeScoreMath.count(Double(4_200)) as String)
        XCTAssertEqual(model.stepsTypical?.delta, .up)
        XCTAssertEqual(model.stepsTypical?.accessibilityLabel, "Above your typical Running steps of \(NativeScoreMath.count(Double(4_000)) as String)")
        XCTAssertTrue(model.isManual)
        XCTAssertTrue(model.hasStrain)
        XCTAssertNil(model.sourceLine)
        XCTAssertTrue(model.zones.isEmpty)
        XCTAssertEqual(model.stats.first { $0.title == "Avg HR" }?.value, "168")
        XCTAssertEqual(model.stats.first { $0.title == "Avg HR" }?.unit, "BPM")
    }

    func testHeartRateRecoveryRowUsesOneMinuteDropAndHidesWhenMissing() {
        let workout = WorkoutRow(
            startTs: 1_700_000_000, endTs: 1_700_001_800, sport: "Running", source: "whoop",
            durationS: 1_800, energyKcal: nil, avgHr: 168, maxHr: 182, strain: 26,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        let hidden = NativeActivityPageLogic.make(
            workout, prior: [], scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertFalse(hidden.stats.contains { $0.title == "HR Recovery" })

        let shown = NativeActivityPageLogic.make(
            workout, prior: [], scale: .whoop, zoneSet: nil, percents: nil,
            heartRateRecovery: 32, priorHeartRateRecovery: [28, 30, 34]
        )
        let row = shown.stats.first { $0.title == "HR Recovery" }
        XCTAssertEqual(row?.value, "32")
        XCTAssertEqual(row?.unit, "BPM")
        XCTAssertEqual(row?.heartFamily, true)
        XCTAssertEqual(row?.neutralDelta, true)
        XCTAssertNotNil(row?.typical)
    }

    func testZonePercentsComeFromSamplesAndHideWhenEmpty() {
        let set = HRZones.zones(maxHR: 190)
        XCTAssertNil(NativeActivityPageLogic.zonePercents(from: [], zoneSet: set))
        let samples = (0..<600).map { HRSample(ts: 1_700_000_000 + $0, bpm: 100) }
        let percents = NativeActivityPageLogic.zonePercents(from: samples, zoneSet: set)
        XCTAssertEqual(percents?.count, 5)
        XCTAssertEqual(percents?[0] ?? 0, 100, accuracy: 0.01)
        let rows = NativeActivityPageLogic.zoneTimes(percents: percents, durationS: 600)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertEqual(rows.first { $0.number == 1 }?.percent ?? 0, 100, accuracy: 0.01)
    }

    func testBpmRangeUsesProfileZonesAndZoneZeroIsBelowZoneOne() {
        let set = HRZones.zones(maxHR: 190)
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 5, set: set), "171+ BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 0, set: set), "< 95 BPM")
        XCTAssertNil(NativeActivityPageLogic.bpmRange(zone: 2, set: nil))
    }

    func testWhoopHRRBoundsDriveDisplayedBpmRanges() {
        let set = HRZones.zones(maxHR: 198, restingHR: 63)
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 0, set: set), "< 117 BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 1, set: set), "117–144 BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 2, set: set), "145–157 BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 3, set: set), "158–171 BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 4, set: set), "172–184 BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 5, set: set), "185+ BPM")
    }

    func testStrainTypicalChipHidesWithoutThreePriorSameSportWorkouts() {
        let workout = row(start: 1_700_000_000, sport: "Running", strain: 10)
        let two = [
            row(start: 1_700_000_000 - 86_400, sport: "Running", strain: 22),
            row(start: 1_700_000_000 - 2 * 86_400, sport: "Running", strain: 21),
        ]
        let hidden = NativeActivityPageLogic.make(
            workout, prior: two, scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertNil(hidden.strainTypical)
        XCTAssertEqual(NativeActivityPageLogic.strainDelta(current: 10, prior: [22, 21]), .none)

        let three = two + [row(start: 1_700_000_000 - 3 * 86_400, sport: "Running", strain: 20)]
        let shown = NativeActivityPageLogic.make(
            workout, prior: three, scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertEqual(shown.strainTypical?.delta, .down)
        XCTAssertEqual(
            shown.strainTypical?.accessibilityLabel,
            "Below your typical Running strain of \(NativeDayLogic.strainText(21, scale: .whoop))"
        )
    }

    func testToggleZoneSelectsAndClears() {
        XCTAssertEqual(NativeActivityPageLogic.toggleZone(nil, tapped: 4), 4)
        XCTAssertEqual(NativeActivityPageLogic.toggleZone(4, tapped: 4), nil)
        XCTAssertEqual(NativeActivityPageLogic.toggleZone(4, tapped: 2), 2)
    }

    func testZoneRunsKeepOnlyTheSelectedZone() {
        let set = HRZones.zones(maxHR: 198, restingHR: 63)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let points = [100.0, 150.0, 180.0, 150.0].enumerated().map { index, bpm in
            NativeHourPoint(time: start.addingTimeInterval(Double(index) * 20), value: bpm)
        }
        let runs = NativeActivityPageLogic.zoneRuns(points, zone: 4, zoneSet: set)
        XCTAssertEqual(runs.flatMap { $0 }.map(\.value), [180])
        XCTAssertTrue(NativeActivityPageLogic.zoneRuns(points, zone: 5, zoneSet: set).isEmpty)
        XCTAssertEqual(NativeActivityPageLogic.zoneRuns(points, zone: 0, zoneSet: set).flatMap { $0 }.map(\.value), [100])
    }

    func testStepsHeroHidesTypicalChipWithoutThreePriorWorkoutsWithSteps() {
        let workout = WorkoutRow(
            startTs: 1_700_000_000, endTs: 1_700_001_800, sport: "Running", source: "whoop",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: 13.6,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: 3_942
        )
        let two = (1...2).map { offset in
            WorkoutRow(
                startTs: 1_700_000_000 - offset * 86_400,
                endTs: 1_700_001_800 - offset * 86_400,
                sport: "Running", source: "whoop",
                durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: 12,
                distanceM: nil, zonesJSON: nil, notes: nil, steps: 5_000
            )
        }
        let hidden = NativeActivityPageLogic.make(
            workout, prior: two, scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertEqual(hidden.stepsText, NativeScoreMath.count(Double(3_942)) as String)
        XCTAssertNil(hidden.stepsTypical)
    }

    private func row(start: Int, sport: String, strain: Double) -> WorkoutRow {
        WorkoutRow(
            startTs: start, endTs: start + 1_800, sport: sport, source: "whoop",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: strain,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }
}

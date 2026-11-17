import XCTest
import WhoopStore
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
        XCTAssertEqual(model.stats.map(\.title), ["Average HR", "Max HR", "Calories", "Distance", "Steps"])
        XCTAssertEqual(model.stats.first { $0.title == "Average HR" }?.neutralDelta, true)
        XCTAssertEqual(model.stats.first { $0.title == "Max HR" }?.neutralDelta, true)
        XCTAssertEqual(model.stats.first { $0.title == "Calories" }?.neutralDelta, false)
        XCTAssertEqual(model.stats.first { $0.title == "Distance" }?.neutralDelta, false)
        XCTAssertEqual(model.stats.first { $0.title == "Steps" }?.neutralDelta, false)
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("pace") })
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("speed") })
        XCTAssertFalse(model.stats.contains { $0.title.localizedCaseInsensitiveContains("elevation") })
        XCTAssertFalse(model.stats.contains { $0.title == "Duration" })
        XCTAssertEqual(model.strainDelta, .up)
        XCTAssertTrue(model.isManual)
        XCTAssertTrue(model.hasStrain)
        XCTAssertNil(model.sourceLine)
        XCTAssertTrue(model.zones.isEmpty)
    }

    func testBpmRangeUsesProfileZonesAndZoneZeroIsBelowZoneOne() {
        let set = HRZones.zones(maxHR: 190)
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 5, set: set), "171+ BPM")
        XCTAssertEqual(NativeActivityPageLogic.bpmRange(zone: 0, set: set), "< 95 BPM")
        XCTAssertNil(NativeActivityPageLogic.bpmRange(zone: 2, set: nil))
    }

    private func row(start: Int, sport: String, strain: Double) -> WorkoutRow {
        WorkoutRow(
            startTs: start, endTs: start + 1_800, sport: sport, source: "whoop",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: strain,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }
}

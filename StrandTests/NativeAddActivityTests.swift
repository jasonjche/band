import XCTest
import WhoopStore
@testable import Strand

@MainActor
final class NativeAddActivityTests: XCTestCase {

    func testRecentSportsRankByCountThenRecency() {
        let now = 1_700_000_000
        let rows = [
            row(sport: "Running", start: now - 400),
            row(sport: "Running", start: now - 300),
            row(sport: "Running", start: now - 200),
            row(sport: "Strength", start: now - 100),
            row(sport: "Strength", start: now - 50),
            row(sport: "Yoga", start: now - 10),
            row(sport: "Cycling", start: now - 20),
            row(sport: "Yoga", start: now),
        ]
        let recent = NativeAddActivityLogic.recentSports(from: rows, limit: 5)
        XCTAssertEqual(recent.map(\.name), ["Running", "Yoga", "Strength", "Cycling"])
    }

    func testRecentSportsCapAtFiveAndIgnoreUnknownNames() {
        let now = 1_700_000_000
        let rows = [
            row(sport: "Running", start: now),
            row(sport: "Walking", start: now),
            row(sport: "Hiking", start: now),
            row(sport: "Cycling", start: now),
            row(sport: "Yoga", start: now),
            row(sport: "Boxing", start: now),
            row(sport: "NotARealSport", start: now),
        ]
        let recent = NativeAddActivityLogic.recentSports(from: rows, limit: 5)
        XCTAssertEqual(recent.map(\.name), ["Boxing", "Cycling", "Hiking", "Running", "Walking"])
        XCTAssertFalse(recent.map(\.name).contains("NotARealSport"))
        XCTAssertFalse(recent.map(\.name).contains("Yoga"))
    }

    func testSearchFiltersCatalogueCaseInsensitivelyAndKeepsAlphabeticalOrder() {
        let all = NativeAddActivityLogic.filteredSports(query: "")
        XCTAssertEqual(all.count, WorkoutCatalog.all.count)
        let names = all.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        let run = NativeAddActivityLogic.filteredSports(query: "run").map(\.name)
        XCTAssertTrue(run.contains("Running"))
        XCTAssertTrue(run.contains("Treadmill run"))
        XCTAssertFalse(run.contains("Yoga"))
        XCTAssertEqual(run, run.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })

        XCTAssertTrue(NativeAddActivityLogic.filteredSports(query: "  PADEl ").map(\.name).contains("Padel"))
        XCTAssertTrue(NativeAddActivityLogic.filteredSports(query: "zzzz").isEmpty)
    }

    func testGroupedSportsPutsRecoveryInItsOwnSection() {
        let groups = NativeAddActivityLogic.groupedSports(query: "")
        XCTAssertTrue(groups.strain.contains { $0.name == "Running" })
        XCTAssertTrue(groups.strain.contains { $0.name == "Yoga" })
        XCTAssertTrue(groups.strain.contains { $0.name == "Pilates" })
        XCTAssertFalse(groups.strain.contains { $0.name == "Sauna" })
        XCTAssertEqual(Set(groups.recovery.map(\.name)).isSuperset(of: [
            "Breathwork", "Ice Bath", "Meditation", "Massage Therapy",
            "Restorative Yoga", "Sauna", "Stretching",
        ]), true)
        let sauna = NativeAddActivityLogic.groupedSports(query: "sauna")
        XCTAssertTrue(sauna.strain.isEmpty)
        XCTAssertEqual(sauna.recovery.map(\.name), ["Sauna"])
    }

    func testSelectedSportMatchesCatalogueKey() {
        let running = WorkoutCatalog.sport(named: "Running")!
        XCTAssertTrue(NativeAddActivityLogic.isSelected(running, selected: "Running"))
        XCTAssertTrue(NativeAddActivityLogic.isSelected(running, selected: "running"))
        XCTAssertFalse(NativeAddActivityLogic.isSelected(running, selected: "Yoga"))
        XCTAssertFalse(NativeAddActivityLogic.isSelected(running, selected: nil))
    }

    func testActiveWorkoutPersistsAndResumesFromDefaults() {
        let suite = "NativeActiveWorkoutTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("suite")
        }
        defaults.removePersistentDomain(forName: suite)
        XCTAssertNil(NativeActiveWorkoutState.load(defaults))

        let state = NativeActiveWorkoutState(sport: "Running", startTs: 1_700_000_000)
        NativeActiveWorkoutState.persist(state, in: defaults)
        XCTAssertEqual(NativeActiveWorkoutState.load(defaults), state)

        NativeActiveWorkoutState.clear(defaults)
        XCTAssertNil(NativeActiveWorkoutState.load(defaults))
        defaults.removePersistentDomain(forName: suite)
    }

    func testUnderOneMinuteIsDiscarded() {
        XCTAssertTrue(NativeActiveWorkoutState.shouldDiscard(elapsed: 0))
        XCTAssertTrue(NativeActiveWorkoutState.shouldDiscard(elapsed: 59.9))
        XCTAssertFalse(NativeActiveWorkoutState.shouldDiscard(elapsed: 60))
        XCTAssertFalse(NativeActiveWorkoutState.shouldDiscard(elapsed: 90))
    }

    func testElapsedClockAndDurationLabel() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(NativeActiveWorkoutState.elapsedClock(from: start, to: start), "0:00:00")
        XCTAssertEqual(
            NativeActiveWorkoutState.elapsedClock(from: start, to: start.addingTimeInterval(62)),
            "0:01:02"
        )
        XCTAssertEqual(
            NativeActiveWorkoutState.elapsedClock(from: start, to: start.addingTimeInterval(3661)),
            "1:01:01"
        )
        XCTAssertEqual(
            NativeAddActivityLogic.durationLabel(from: start, to: start.addingTimeInterval(45 * 60)),
            "45 min"
        )
        XCTAssertEqual(
            NativeAddActivityLogic.durationLabel(from: start, to: start.addingTimeInterval(90 * 60)),
            "1 hr 30 min"
        )
    }

    func testAwaitingHeartRateWhenWindowHasNoHrYet() {
        XCTAssertTrue(NativeActivityPageLogic.awaitingHeartRate(hrPointCount: 0, zoneCount: 0, heartStatCount: 0))
        XCTAssertFalse(NativeActivityPageLogic.awaitingHeartRate(hrPointCount: 4, zoneCount: 0, heartStatCount: 0))
        XCTAssertFalse(NativeActivityPageLogic.awaitingHeartRate(hrPointCount: 0, zoneCount: 6, heartStatCount: 0))
        XCTAssertFalse(NativeActivityPageLogic.awaitingHeartRate(hrPointCount: 0, zoneCount: 0, heartStatCount: 1))
    }

    func testManualActivityWithoutStrainFlagsHasStrainFalse() {
        let workout = WorkoutRow(
            startTs: 1_700_000_000, endTs: 1_700_000_120, sport: "Running", source: "manual",
            durationS: 120, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
        let model = NativeActivityPageLogic.make(
            workout, prior: [], scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertFalse(model.hasStrain)
        XCTAssertTrue(model.zones.isEmpty)
        XCTAssertTrue(model.stats.isEmpty)
        XCTAssertTrue(model.isManual)
    }

    private func row(sport: String, start: Int) -> WorkoutRow {
        WorkoutRow(
            startTs: start, endTs: start + 1_800, sport: sport, source: "manual",
            durationS: 1_800, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil, steps: nil
        )
    }
}

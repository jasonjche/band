import XCTest
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

@MainActor
final class NativeLiveActivityTests: XCTestCase {

    func testLiveStrainEqualsSavedActivityStrain() throws {
        let samples = constHR(150, seconds: 20 * 60)
        let live = NativeLiveActivityLogic.strain(samples: samples, maxHR: 190, restingHR: 60)
        let analytics = LiveActivityScoring.effort100(samples: samples, maxHR: 190, restingHR: 60)
        XCTAssertEqual(live, analytics)
        XCTAssertEqual(live, NativeStrain.score(samples, maxHR: 190, restingHR: 60))

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let row = try XCTUnwrap(NativeLiveActivityLogic.makeRow(
            sport: "Running",
            startTs: Int(start.timeIntervalSince1970),
            end: start.addingTimeInterval(20 * 60),
            elapsed: 20 * 60,
            samples: samples,
            maxHR: 190,
            restingHR: 60,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
            route: nil
        ))
        XCTAssertEqual(NativeStrain.workout(row), live)

        let model = NativeActivityPageLogic.make(
            row, prior: [], scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertEqual(model.strainText, NativeDayLogic.strainText(live, scale: .whoop))
        XCTAssertEqual(model.strainText, NativeLiveActivityLogic.strainText(live))
        XCTAssertTrue(model.hasStrain)
    }

    func testRecoveryLiveHidesStrainLikeActivityPage() throws {
        XCTAssertFalse(NativeLiveActivityLogic.showsStrain("Sauna"))
        XCTAssertFalse(NativeLiveActivityLogic.showsStrain("Ice Bath"))
        XCTAssertTrue(NativeLiveActivityLogic.showsStrain("Running"))
        XCTAssertTrue(NativeLiveActivityLogic.showsStrain("Yoga"))

        let samples = constHR(95, seconds: 15 * 60)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let row = try XCTUnwrap(NativeLiveActivityLogic.makeRow(
            sport: "Sauna",
            startTs: Int(start.timeIntervalSince1970),
            end: start.addingTimeInterval(15 * 60),
            elapsed: 15 * 60,
            samples: samples,
            maxHR: 190,
            restingHR: 60,
            profile: UserProfile(),
            route: nil
        ))
        XCTAssertNil(row.strain)
        let model = NativeActivityPageLogic.make(
            row, prior: [], scale: .whoop, zoneSet: nil, percents: nil
        )
        XCTAssertTrue(model.isRecovery)
        XCTAssertFalse(model.hasStrain)
    }

    func testTrackRouteDefaultsOnForGpsSports() {
        XCTAssertTrue(NativeLiveActivityLogic.showsTrackRoute("Running"))
        XCTAssertTrue(NativeLiveActivityLogic.showsTrackRoute("Walking"))
        XCTAssertTrue(NativeLiveActivityLogic.showsTrackRoute("Cycling"))
        XCTAssertTrue(NativeLiveActivityLogic.defaultTrackRoute("Running"))
        XCTAssertFalse(NativeLiveActivityLogic.showsTrackRoute("Yoga"))
        XCTAssertFalse(NativeLiveActivityLogic.showsTrackRoute("Sauna"))
        XCTAssertFalse(NativeLiveActivityLogic.defaultTrackRoute("Strength"))
        XCTAssertTrue(NativeLiveActivityLogic.showsDistancePace("Running"))
        XCTAssertTrue(NativeLiveActivityLogic.showsDistancePace("Walking"))
        XCTAssertTrue(NativeLiveActivityLogic.showsDistancePace("Cycling"))
        XCTAssertFalse(NativeLiveActivityLogic.showsDistancePace("Hiking"))
    }

    func testOneSamplePerSecondAndPauseAwareClock() {
        var samples: [HRSample] = []
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(NativeLiveActivityLogic.recordSample(into: &samples, bpm: 120, at: t0))
        XCTAssertFalse(NativeLiveActivityLogic.recordSample(into: &samples, bpm: 140, at: t0))
        XCTAssertTrue(NativeLiveActivityLogic.recordSample(
            into: &samples, bpm: 141, at: t0.addingTimeInterval(1)
        ))
        XCTAssertEqual(samples.map(\.bpm), [120, 141])

        let elapsed = NativeLiveActivityLogic.elapsed(
            start: t0,
            now: t0.addingTimeInterval(120),
            pausedAt: t0.addingTimeInterval(90),
            pausedDuration: 10
        )
        XCTAssertEqual(elapsed, 80, accuracy: 1e-9)
        XCTAssertEqual(
            NativeActiveWorkoutState.elapsedClock(
                from: t0, to: t0.addingTimeInterval(62)
            ),
            "0:01:02"
        )
    }

    func testTargetHapticFiresOnceWhenStrainReachesRange() {
        let range = 10.0...13.8
        XCTAssertFalse(NativeLiveActivityLogic.shouldFireTarget(
            enabled: false, alreadyFired: false, strain21: 12, range: range
        ))
        XCTAssertFalse(NativeLiveActivityLogic.shouldFireTarget(
            enabled: true, alreadyFired: false, strain21: 9.9, range: range
        ))
        XCTAssertTrue(NativeLiveActivityLogic.shouldFireTarget(
            enabled: true, alreadyFired: false, strain21: 10, range: range
        ))
        XCTAssertFalse(NativeLiveActivityLogic.shouldFireTarget(
            enabled: true, alreadyFired: true, strain21: 12, range: range
        ))
    }

    func testStrainBandFollowsWhoopCutoffs() {
        XCTAssertEqual(NativeLiveActivityLogic.strainBand(0).rawValue, "Light")
        let ten = StrainScorer.effortValue(fromWhoopStrain: 10)
        XCTAssertEqual(NativeLiveActivityLogic.strainBand(ten), .moderate)
        let eighteen = StrainScorer.effortValue(fromWhoopStrain: 18)
        XCTAssertEqual(NativeLiveActivityLogic.strainBand(eighteen), .allOut)
    }

    func testPersistedSessionKeepsRouteAndTargetToggles() {
        let suite = "NativeLiveActivity.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            return XCTFail("suite")
        }
        defaults.removePersistentDomain(forName: suite)
        let state = NativeActiveWorkoutState(
            sport: "Running",
            startTs: 1_700_000_000,
            trackRoute: true,
            strainTargetEnabled: true,
            pausedAtTs: 1_700_000_040,
            pausedDuration: 12
        )
        NativeActiveWorkoutState.persist(state, in: defaults)
        XCTAssertEqual(NativeActiveWorkoutState.load(defaults), state)

        let withHR = NativeActiveWorkoutState(
            sport: "Running", startTs: 1_700_000_000, trackRoute: true,
            samples: [HRSample(ts: 1_700_000_000, bpm: 140)]
        )
        NativeActiveWorkoutState.persist(withHR, in: defaults)
        XCTAssertEqual(NativeActiveWorkoutState.load(defaults)?.samples, withHR.samples)
        defaults.removePersistentDomain(forName: suite)
    }

    func testShortSessionIsNotSaved() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertNil(NativeLiveActivityLogic.makeRow(
            sport: "Running",
            startTs: Int(start.timeIntervalSince1970),
            end: start.addingTimeInterval(59),
            elapsed: 59,
            samples: constHR(140, seconds: 59),
            maxHR: 190,
            restingHR: 60,
            profile: UserProfile(),
            route: nil
        ))
    }

    func testSavedRowCarriesRouteDistanceAndCalories() throws {
        let samples = constHR(150, seconds: 10 * 60)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let route = WorkoutRoute(polyline: "abc", distanceM: 1_200, points: nil)
        let row = try XCTUnwrap(NativeLiveActivityLogic.makeRow(
            sport: "Running",
            startTs: Int(start.timeIntervalSince1970),
            end: start.addingTimeInterval(10 * 60),
            elapsed: 10 * 60,
            samples: samples,
            maxHR: 190,
            restingHR: 60,
            profile: UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male"),
            route: route
        ))
        XCTAssertEqual(row.distanceM, 1_200)
        XCTAssertNotNil(row.energyKcal)
        XCTAssertEqual(row.avgHr, 150)
        XCTAssertEqual(row.maxHr, 150)
    }

    func testMetricsRefreshEveryThreeSeconds() {
        XCTAssertFalse(NativeLiveActivityLogic.shouldRefreshMetrics(
            lastTs: 1_700_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_002),
            force: false
        ))
        XCTAssertTrue(NativeLiveActivityLogic.shouldRefreshMetrics(
            lastTs: 1_700_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_003),
            force: false
        ))
        XCTAssertTrue(NativeLiveActivityLogic.shouldRefreshMetrics(
            lastTs: 1_700_000_000,
            now: Date(timeIntervalSince1970: 1_700_000_001),
            force: true
        ))
    }

    func testZoneBarLabelUsesDisplayPercents() {
        let set = HRZones.zones(maxHR: 200)
        XCTAssertEqual(set.zones.count, 5)
        let z1 = NativeLiveActivityLogic.zoneBarLabel(set.zones[0])
        XCTAssertTrue(z1.contains("%"))
        XCTAssertEqual(NativeLiveActivityLogic.zoneBarLabel(set.zones[4]).hasSuffix("100%"), true)
    }

    private func constHR(_ bpm: Int, seconds: Int) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: 1_700_000_000 + $0, bpm: bpm) }
    }
}

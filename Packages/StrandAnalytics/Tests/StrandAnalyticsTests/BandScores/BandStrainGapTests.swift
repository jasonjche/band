import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class BandStrainGapTests: XCTestCase {

    private var params: BandStrain.Params!
    private let hrmax = 190.0
    private let rhr = 60.0

    override func setUpWithError() throws {
        params = try BandScores.Params.bundled().strain
    }

    func testLoadInvertsTheStrainCurve() throws {
        let s = 11.1
        let L = try XCTUnwrap(BandStrain.load(fromStrain: s, params: params))
        XCTAssertEqual(BandStrain.strain(load: L, params: params), s, accuracy: 1e-9)
    }

    func testUncoveredWorkoutRaisesDayAboveStrapOnlyAndAtLeastTheWorkout() throws {
        let background = constHR(75, seconds: 2 * 3600, t0: 0)
        let run = constHR(160, seconds: 30 * 60, t0: 2 * 3600)
        let workout = BandStrain.WorkoutContribution(startTs: 2 * 3600, endTs: 2 * 3600 + 30 * 60,
                                                     samples: run)
        let strapOnly = try XCTUnwrap(BandStrain.strain(background, maxHR: hrmax, restingHR: rhr, params: params))
        let workoutS = try XCTUnwrap(BandStrain.strain(run, maxHR: hrmax, restingHR: rhr, params: params))
        let day = try XCTUnwrap(BandStrain.dayStrain(background, workouts: [workout],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertGreaterThan(day, strapOnly)
        XCTAssertGreaterThanOrEqual(day, workoutS - 1e-9)
        let expected = try XCTUnwrap(BandStrain.strain(background + run, maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(day, expected, accuracy: 1e-9)
    }

    func testUncoveredWorkoutWithoutSamplesInvertsStoredStrain() throws {
        let background = constHR(75, seconds: 2 * 3600)
        let run = constHR(160, seconds: 30 * 60, t0: 2 * 3600)
        let workoutS = try XCTUnwrap(BandStrain.strain(run, maxHR: hrmax, restingHR: rhr, params: params))
        let workout = BandStrain.WorkoutContribution(startTs: 2 * 3600, endTs: 2 * 3600 + 30 * 60,
                                                     storedStrain21: workoutS)
        let strapOnly = try XCTUnwrap(BandStrain.strain(background, maxHR: hrmax, restingHR: rhr, params: params))
        let day = try XCTUnwrap(BandStrain.dayStrain(background, workouts: [workout],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertGreaterThan(day, strapOnly)
        XCTAssertGreaterThanOrEqual(day, workoutS - 1e-9)
    }

    func testFullyCoveredWorkoutMatchesTodaysStrain() throws {
        let background = constHR(75, seconds: 2 * 3600)
        let run = constHR(160, seconds: 30 * 60, t0: 2 * 3600)
        let strap = background + run
        let workout = BandStrain.WorkoutContribution(startTs: 2 * 3600, endTs: 2 * 3600 + 30 * 60,
                                                     samples: run)
        let today = try XCTUnwrap(BandStrain.strain(strap, maxHR: hrmax, restingHR: rhr, params: params))
        let day = try XCTUnwrap(BandStrain.dayStrain(strap, workouts: [workout],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(day, today, accuracy: 0)
    }

    func testCoverageAtThresholdDoesNotAddLoad() throws {
        let background = constHR(75, seconds: 3600)
        let window = 100
        let start = 3600
        let covered = constHR(160, seconds: window / 2, t0: start)
        let strap = background + covered
        let workoutHR = constHR(160, seconds: window, t0: start)
        let workout = BandStrain.WorkoutContribution(startTs: start, endTs: start + window,
                                                     samples: workoutHR)
        XCTAssertEqual(BandStrain.strapCoverage(samples: strap, start: start, end: start + window),
                       0.5, accuracy: 0)
        let today = try XCTUnwrap(BandStrain.strain(strap, maxHR: hrmax, restingHR: rhr, params: params))
        let day = try XCTUnwrap(BandStrain.dayStrain(strap, workouts: [workout],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(day, today, accuracy: 0)
    }

    func testTwoUncoveredWorkoutsAddLoadsOnTheSaturatingMap() throws {
        let w1s = constHR(160, seconds: 20 * 60, t0: 3600)
        let w2s = constHR(150, seconds: 20 * 60, t0: 3600 + 30 * 60)
        let w1 = BandStrain.WorkoutContribution(startTs: 3600, endTs: 3600 + 20 * 60, samples: w1s)
        let w2 = BandStrain.WorkoutContribution(startTs: 3600 + 30 * 60, endTs: 3600 + 50 * 60, samples: w2s)
        let s1 = try XCTUnwrap(BandStrain.strain(w1s, maxHR: hrmax, restingHR: rhr, params: params))
        let s2 = try XCTUnwrap(BandStrain.strain(w2s, maxHR: hrmax, restingHR: rhr, params: params))
        let day = try XCTUnwrap(BandStrain.dayStrain([], workouts: [w1, w2],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertGreaterThan(day, max(s1, s2))
        XCTAssertLessThan(day, s1 + s2)
    }

    func testPartialCoverageDoesNotDoubleCountStrapSamplesInsideTheWindow() throws {
        let background = constHR(75, seconds: 3600)
        let run = constHR(160, seconds: 30 * 60, t0: 3600)
        let partialStrap = background + Array(run.prefix(8 * 60))
        let coverage = BandStrain.strapCoverage(samples: partialStrap, start: 3600, end: 3600 + 30 * 60)
        XCTAssertLessThan(coverage, BandStrain.strapCoverageThreshold)
        XCTAssertGreaterThan(coverage, 0)
        let workout = BandStrain.WorkoutContribution(startTs: 3600, endTs: 3600 + 30 * 60, samples: run)
        let day = try XCTUnwrap(BandStrain.dayStrain(partialStrap, workouts: [workout],
                                                     maxHR: hrmax, restingHR: rhr, params: params))
        let expected = try XCTUnwrap(BandStrain.strain(background + run, maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(day, expected, accuracy: 1e-9)
        let doubleCounted = try XCTUnwrap(BandStrain.strain(partialStrap + run, maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertLessThan(day, doubleCounted)
    }

    func testOverlappingCopiesOfOneWorkoutDoNotDoubleLoad() throws {
        let run = constHR(160, seconds: 30 * 60, t0: 3600)
        let apple = BandStrain.WorkoutContribution(startTs: 3600, endTs: 3600 + 30 * 60, samples: run)
        let dup = BandStrain.WorkoutContribution(startTs: 3600 + 60, endTs: 3600 + 30 * 60,
                                                 storedStrain21: 11.0)
        let once = try XCTUnwrap(BandStrain.dayStrain([], workouts: [apple],
                                                      maxHR: hrmax, restingHR: rhr, params: params))
        let both = try XCTUnwrap(BandStrain.dayStrain([], workouts: [apple, dup],
                                                      maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(both, once, accuracy: 1e-12)
    }

    func testEmptyWorkoutsMatchStrain() throws {
        let samples = constHR(90, seconds: 3600)
        let today = BandStrain.strain(samples, maxHR: hrmax, restingHR: rhr, params: params)
        let day = BandStrain.dayStrain(samples, workouts: [], maxHR: hrmax, restingHR: rhr, params: params)
        XCTAssertEqual(day, today)
    }

    func testAnalyzeDayThreadsUncoveredWorkoutLoad() throws {
        let background = constHR(75, seconds: 2 * 3600, t0: 0)
        let run = constHR(160, seconds: 30 * 60, t0: 2 * 3600)
        let workout = BandStrain.WorkoutContribution(
            startTs: 2 * 3600,
            endTs: 2 * 3600 + 30 * 60,
            samples: run)
        let profile = UserProfile(age: 30, sex: "male")
        let day = "1970-01-01"
        let strapOnly = AnalyticsEngine.analyzeDay(
            day: day, hr: background, dayHr: background, profile: profile,
            maxHROverride: hrmax, useBandStrain: true).strain
        let withGap = AnalyticsEngine.analyzeDay(
            day: day, hr: background, dayHr: background, profile: profile,
            maxHROverride: hrmax, useBandStrain: true, strainWorkouts: [workout]).strain
        let covered = AnalyticsEngine.analyzeDay(
            day: day, hr: background + run, dayHr: background + run, profile: profile,
            maxHROverride: hrmax, useBandStrain: true, strainWorkouts: [workout]).strain
        let coveredToday = AnalyticsEngine.analyzeDay(
            day: day, hr: background + run, dayHr: background + run, profile: profile,
            maxHROverride: hrmax, useBandStrain: true).strain
        XCTAssertNotNil(strapOnly)
        XCTAssertNotNil(withGap)
        XCTAssertGreaterThan(withGap ?? 0, strapOnly ?? 0)
        XCTAssertEqual(covered, coveredToday)
    }

    private func constHR(_ bpm: Int, seconds: Int, t0: Int = 0) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: t0 + $0, bpm: bpm) }
    }
}

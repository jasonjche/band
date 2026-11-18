import XCTest
@testable import StrandAnalytics
import WhoopStore

final class ActivityScoringTests: XCTestCase {

    func testKindSplitsCardioStrengthMixedAndRecovery() {
        XCTAssertEqual(ActivityScoring.kind("Running"), .cardio)
        XCTAssertEqual(ActivityScoring.kind("Walking"), .cardio)
        XCTAssertEqual(ActivityScoring.kind("Cycling"), .cardio)
        XCTAssertEqual(ActivityScoring.kind("Weightlifting"), .strength)
        XCTAssertEqual(ActivityScoring.kind("Powerlifting"), .strength)
        XCTAssertEqual(ActivityScoring.kind("Bodybuilding"), .strength)
        XCTAssertEqual(ActivityScoring.kind("Yoga"), .mixed)
        XCTAssertEqual(ActivityScoring.kind("Pilates"), .mixed)
        XCTAssertEqual(ActivityScoring.kind("HIIT"), .mixed)
        XCTAssertEqual(ActivityScoring.kind("Meditation"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Stretching"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Breathwork"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Sauna"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Dry Sauna"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Ice Bath"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Cold Plunge"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Massage Therapy"), .recovery)
        XCTAssertEqual(ActivityScoring.kind("Restorative Yoga"), .recovery)
        XCTAssertFalse(ActivityScoring.contributesActivityStrain("Ice Bath"))
        XCTAssertTrue(ActivityScoring.contributesActivityStrain("Yoga"))
        XCTAssertTrue(ActivityScoring.contributesActivityStrain("Running"))
    }

    func testOneHertzGravityCannotCountReps() {
        XCTAssertFalse(ActivityScoring.canCountReps(sampleRateHz: 1))
        XCTAssertFalse(ActivityScoring.canCountRepsFromStoredGravity)
        XCTAssertTrue(ActivityScoring.canCountReps(sampleRateHz: 100))
        XCTAssertFalse(ActivityScoring.canCountReps(sampleRateHz: 2))
    }

    func testMuscularLoadIsRelativeVolumeOverBodyWeight() throws {
        let sets = [
            set(weight: 80, reps: 5),
            set(weight: 80, reps: 5),
        ]
        let result = ActivityScoring.muscularLoad(
            sport: "Weightlifting", sets: sets, bodyWeightKg: 80, cardioStrain21: 3.1
        )
        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.relativeVolume, 10, accuracy: 1e-9)
        XCTAssertEqual(unwrapped.intensity, ActivityScoring.defaultIntensity, accuracy: 1e-9)
        XCTAssertGreaterThan(unwrapped.muscularStrain21, 0)
        XCTAssertLessThan(unwrapped.combinedStrain21, 21)
        XCTAssertEqual(unwrapped.cardioPercent + unwrapped.muscularPercent, 100)
        XCTAssertEqual(unwrapped.kind, .strength)
    }

    func testWarmupsAndMissingWeightDoNotCount() {
        let empty = ActivityScoring.muscularLoad(
            sport: "Weightlifting",
            sets: [set(weight: 40, reps: 10, warmup: true)],
            bodyWeightKg: 80,
            cardioStrain21: 2
        )
        XCTAssertNil(empty)
        XCTAssertNil(ActivityScoring.muscularLoad(
            sport: "Running",
            sets: [set(weight: 100, reps: 5)],
            bodyWeightKg: 80,
            cardioStrain21: 10
        ))
        XCTAssertNil(ActivityScoring.muscularLoad(
            sport: "Meditation",
            sets: [set(weight: 100, reps: 5)],
            bodyWeightKg: 80,
            cardioStrain21: 1
        ))
    }

    func testRatedSetsRaiseIntensity() {
        let easy = ActivityScoring.workingIntensity([set(weight: 60, reps: 8, rpe: 5)])
        let hard = ActivityScoring.workingIntensity([set(weight: 60, reps: 8, rpe: 9)])
        XCTAssertEqual(easy, 0.5, accuracy: 1e-9)
        XCTAssertEqual(hard, 0.9, accuracy: 1e-9)
        XCTAssertGreaterThan(
            ActivityScoring.strain21(relativeVolume: 80, intensity: 0.9),
            ActivityScoring.strain21(relativeVolume: 80, intensity: 0.5)
        )
    }

    func testCombineSharesTheCeiling() {
        let parts = ActivityScoring.combine(cardio21: 3.1, muscular21: 3.3)
        XCTAssertEqual(parts.combined, 21 * (1 - (1 - 3.1 / 21) * (1 - 3.3 / 21)), accuracy: 1e-9)
        XCTAssertEqual(parts.cardioShare + parts.muscularShare, 1, accuracy: 1e-9)
        let percents = ActivityScoring.percentPair(cardioShare: 0.48, muscularShare: 0.52)
        XCTAssertEqual(percents.cardio, 48)
        XCTAssertEqual(percents.muscular, 52)
    }

    func testYogaWithoutLogsHasNoMuscularSplit() {
        XCTAssertNil(ActivityScoring.muscularLoad(
            sport: "Yoga", sets: [], bodyWeightKg: 80, cardioStrain21: 4
        ))
        XCTAssertEqual(ActivityScoring.kind("Hot Yoga"), .mixed)
    }

    private var ord = 0

    private func set(weight: Double?, reps: Int?, rpe: Double? = nil,
                     warmup: Bool = false) -> LiftSetRow {
        ord += 1
        return LiftSetRow(
            id: "s\(ord)", deviceId: "dev", sessionId: "sess", ord: ord,
            exercise: "Squat", primaryMuscle: .quads, secondaryMuscles: [],
            setIndex: ord, weightKg: weight, reps: reps, rpe: rpe,
            isWarmup: warmup, startTs: nil, endTs: nil, restSec: nil, note: nil
        )
    }
}

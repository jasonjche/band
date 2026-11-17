import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// Tests Calories.estimateDayCalories — whole-day Mifflin–St Jeor BMR plus Keytel extra
/// above the day-path 50% HRR gate. Pure-function tests; no DB. Not cloud/clinical parity.
final class DayCaloriesTests: XCTestCase {

    private func hrDay(bpm: Int, n: Int, start: Int = 0) -> [HRSample] {
        (0..<n).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    func testDayCaloriesEmptyIsZero() {
        XCTAssertEqual(
            Calories.estimateDayCalories([], profile: UserProfile(), hrmax: 190.0, restingHR: 55.0),
            0.0, accuracy: 1e-12)
    }

    func testDayEnergyEmptyComponentsAreZero() {
        let estimate = Calories.estimateDayEnergy([], profile: UserProfile(),
                                                  hrmax: 190.0, restingHR: 55.0)
        XCTAssertEqual(estimate.restingKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.activeKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.totalKcal, 0, accuracy: 1e-12)
        XCTAssertEqual(estimate.observedSeconds, 0, accuracy: 1e-12)
    }

    func testDayCaloriesMatchesBoutAtOneHzWhenAllActive() {
        // All-active 1 Hz: day BMR over last-first equals the bout BMR share, and Keytel extra
        // matches the bout's gross Keytel, so the totals agree. They diverge on rest or gaps.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let hr = hrDay(bpm: 130, n: 600)  // 10 min above the active threshold, dense 1 Hz
        let day = Calories.estimateDayCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0)
        let bout = Calories.estimateBoutCalories(hr, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(day, bout, accuracy: 1e-6)
    }

    func testMifflinStJeorMatchesPublishedForm() {
        XCTAssertEqual(Calories.mifflinStJeorBmr(weightKg: 80, heightCm: 180, age: 35, sex: "male"),
                       1755, accuracy: 1e-9)
        XCTAssertEqual(Calories.mifflinStJeorBmr(weightKg: 80, heightCm: 180, age: 30, sex: "male"),
                       1780, accuracy: 1e-9)
        XCTAssertEqual(Calories.mifflinStJeorBmr(weightKg: 65, heightCm: 165, age: 30, sex: "female"),
                       1370.25, accuracy: 1e-9)
        let mid = Calories.mifflinStJeorBmr(weightKg: 70, heightCm: 170, age: 30, sex: "nonbinary")
        XCTAssertEqual(mid, 1534.5, accuracy: 1e-9)
    }

    func testGaplessOneHzDayIsBMRPlusActiveExtra() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let block = 8 * 3_600
        let day = hrDay(bpm: 55, n: block)
            + hrDay(bpm: 130, n: block, start: block)
            + hrDay(bpm: 70, n: block, start: 2 * block)
        let energy = Calories.estimateDayEnergy(day, profile: profile,
                                                hrmax: 185.0, restingHR: 55.0)
        let bmr = Calories.mifflinStJeorBmr(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        XCTAssertEqual(energy.restingKcal, bmr, accuracy: 1.0)
        XCTAssertGreaterThan(energy.activeKcal, 0)
        XCTAssertEqual(energy.totalKcal, energy.restingKcal + energy.activeKcal, accuracy: 1e-9)
        XCTAssertEqual(energy.observedSeconds, 86_400, accuracy: 1)
    }

    func testDayCaloriesRestingDayIsLowerThanActiveDay() {
        // A whole day at resting HR burns far less than the same length all-active day,
        // and the resting-day total is positive (BMR floor).
        let profile = UserProfile(weightKg: 70, heightCm: 170, age: 30, sex: "nonbinary")
        // Day activeThreshold = 55 + 0.50*(185-55) = 120 bpm; 60 < 120 (resting), 150 >= 120 (active).
        let restingDay = Calories.estimateDayCalories(hrDay(bpm: 60, n: 3600), profile: profile,
                                                      hrmax: 185.0, restingHR: 55.0)
        let activeDay = Calories.estimateDayCalories(hrDay(bpm: 150, n: 3600), profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        XCTAssertGreaterThan(restingDay, 0.0, "resting day must burn > 0 (BMR floor)")
        XCTAssertGreaterThan(activeDay, restingDay, "active day must exceed resting day")
    }

    func testSedentaryFullDayApproximatesBMR() {
        // A full 24 h at resting HR (below the day active gate) must total ≈ the subject's BMR:
        // the day estimator floors every sub-threshold second at the resting metabolic rate, so
        // an all-rest day is BMR by construction. Standard male test subject's revised
        // Harris–Benedict BMR ≈ 1825 kcal. This is an APPROXIMATE estimate, not medical advice.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let sedentary = hrDay(bpm: 55, n: 86_400)   // 24 h, all at resting HR
        let total = Calories.estimateDayCalories(sedentary, profile: profile,
                                                 hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(total, 1755, accuracy: 1.0,
                       "a sedentary full day must total ≈ Mifflin–St Jeor BMR (~1755 kcal)")
    }

    func testLightActivityDayIsFarBelowOldInflatedTotal() {
        // The bug: at the OLD 30% day gate (~94 bpm for this subject) ordinary low-intensity
        // daytime HR (~100 bpm walking/standing) was credited the FULL Keytel gross-exercise
        // rate, inflating the day total by ~1000+ kcal. The 50% day gate (120 bpm) now treats
        // that HR as resting, so a realistic mixed light day (8 h sleep @55, 8 h sedentary @70,
        // 8 h light activity @100) collapses toward BMR instead of the old runaway figure.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let block = 8 * 3_600
        let lightDay = hrDay(bpm: 55, n: block)
            + hrDay(bpm: 70, n: block, start: block)
            + hrDay(bpm: 100, n: block, start: 2 * block)
        let total = Calories.estimateDayCalories(lightDay, profile: profile,
                                                 hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(total, 1755, accuracy: 1.0,
                       "a light-activity day must land near BMR, not the old inflated total")
        // Teeth: the OLD 30%-gate model credited the 8 h @100 bpm block at the full Keytel
        // active rate (~3551 kcal for that block alone), so the old day total was ≈ 4768 kcal.
        // Pin that we are now WELL below it (more than 2000 kcal lower).
        XCTAssertLessThan(total, 4768.0 - 2000.0,
                          "the light-activity day must drop far below the old inflated ~4768 kcal")
    }

    func testSparseHRTracksElapsedTimeNotSampleCount() {
        // A 10-minute effort at a steady active HR, sampled two ways over the SAME ~600 s span:
        // densely at 1 Hz, and sparsely at one sample / 10 s (the WHOOP 5/MG case). Energy must
        // track elapsed time, so the sparse estimate lands close to the dense one — NOT ~1/10th
        // of it, as the old one-second-per-sample count produced. (BOUT path only.)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let dense = (0..<600).map { HRSample(ts: $0, bpm: 130) }
        let sparse = stride(from: 0, to: 600, by: 10).map { HRSample(ts: $0, bpm: 130) }
        let denseKcal = Calories.estimateBoutCalories(dense, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let sparseKcal = Calories.estimateBoutCalories(sparse, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(sparseKcal, denseKcal, accuracy: denseKcal * 0.05,
                       "sparse HR must be counted over elapsed time, not undercounted per sample")
        // Teeth: a per-sample count (60 samples) would be ~1/10th of the dense total.
        XCTAssertGreaterThan(sparseKcal, denseKcal * 0.5)
    }

    func testSparseDayCaloriesTrackElapsedTimeNotSampleCount() {
        // The daily path must be cadence-invariant too: WHOOP 5/MG's ~30 s HR and a 1 Hz
        // stream over the same ten active minutes represent the same elapsed work.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let dense = (0..<600).map { HRSample(ts: $0, bpm: 130) }
        let sparse = stride(from: 0, to: 600, by: 30).map { HRSample(ts: $0, bpm: 130) }
        let denseEnergy = Calories.estimateDayEnergy(dense, profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        let sparseEnergy = Calories.estimateDayEnergy(sparse, profile: profile,
                                                      hrmax: 185.0, restingHR: 55.0)
        XCTAssertEqual(sparseEnergy.observedSeconds, 600, accuracy: 1)
        XCTAssertEqual(sparseEnergy.restingKcal, denseEnergy.restingKcal, accuracy: 1e-9)
        XCTAssertEqual(sparseEnergy.activeKcal, denseEnergy.activeKcal, accuracy: 1e-9)
        XCTAssertEqual(sparseEnergy.totalKcal, denseEnergy.totalKcal, accuracy: 1e-9)
    }

    func testDayEnergyParityVectorOracle() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let bmr = Calories.mifflinStJeorBmr(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let rate = bmr / 86_400.0
        let full = Calories.estimateDayEnergy(hrDay(bpm: 55, n: 86_400), profile: profile,
                                              hrmax: 185, restingHR: 55)
        XCTAssertEqual(full.restingKcal, bmr, accuracy: 1e-6)
        XCTAssertEqual(full.activeKcal, 0, accuracy: 1e-9)
        XCTAssertEqual(full.observedSeconds, 86_400, accuracy: 1)

        let dense = Calories.estimateDayEnergy((0..<600).map { HRSample(ts: $0, bpm: 130) },
                                               profile: profile, hrmax: 185, restingHR: 55)
        let sparse = Calories.estimateDayEnergy(
            stride(from: 0, to: 600, by: 30).map { HRSample(ts: $0, bpm: 130) },
            profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(dense.restingKcal, rate * 600, accuracy: 1e-6)
        XCTAssertEqual(sparse.restingKcal, dense.restingKcal, accuracy: 1e-6)
        XCTAssertEqual(sparse.activeKcal, dense.activeKcal, accuracy: 1e-6)

        let gapped = Calories.estimateDayEnergy(
            [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)],
            profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(gapped.restingKcal, rate * gapped.observedSeconds, accuracy: 1e-6)
        XCTAssertGreaterThan(gapped.observedSeconds, 3_000)
        XCTAssertLessThan(gapped.activeKcal, dense.activeKcal)
    }

    func testWearGapIsCappedNotCreditedInFull() {
        // Two active samples an hour apart must NOT credit a full hour of active burn — the
        // per-sample interval is capped at mergeGapS (150 s). The pre-gap sample contributes
        // 150 s and the tail 1 s, so the total equals a 151 s continuous equivalent, not 3600 s.
        // (BOUT path only.)
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)]
        let cappedEquiv = (0...150).map { HRSample(ts: $0, bpm: 130) }   // 151 s continuous
        let gappedKcal = Calories.estimateBoutCalories(gapped, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        let equivKcal = Calories.estimateBoutCalories(cappedEquiv, profile: profile, hrmax: 185.0, restingHR: 55.0).0
        XCTAssertEqual(gappedKcal, equivKcal, accuracy: equivKcal * 0.001,
                       "an inter-sample gap must be capped at mergeGapS, not credited in full")
    }

    func testDayPathProratesBMRAcrossGapsButCapsActive() {
        // Two isolated high readings an hour apart: BMR continues across the hour (metabolism
        // does not require a sample), but active Keytel extra is still cadence-capped.
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = [HRSample(ts: 0, bpm: 130), HRSample(ts: 3600, bpm: 130)]
        let active120s = hrDay(bpm: 130, n: 120)
        let active3660s = hrDay(bpm: 130, n: 3660)
        let gapEnergy = Calories.estimateDayEnergy(gapped, profile: profile,
                                                   hrmax: 185.0, restingHR: 55.0)
        let shortEnergy = Calories.estimateDayEnergy(active120s, profile: profile,
                                                     hrmax: 185.0, restingHR: 55.0)
        let continuousEnergy = Calories.estimateDayEnergy(active3660s, profile: profile,
                                                          hrmax: 185.0, restingHR: 55.0)
        XCTAssertGreaterThan(gapEnergy.observedSeconds, 3_000)
        XCTAssertGreaterThan(gapEnergy.restingKcal, shortEnergy.restingKcal)
        XCTAssertEqual(gapEnergy.activeKcal, shortEnergy.activeKcal, accuracy: 1e-6,
                       "a long gap must carry only cadence-capped active seconds")
        XCTAssertLessThan(gapEnergy.activeKcal, continuousEnergy.activeKcal,
                          "a sensor gap must not be treated as continuous exercise")
    }

    func testCalendarElapsedCreditsFullDayBMR() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let morning = hrDay(bpm: 70, n: 600)
        let soFar = Calories.estimateDayEnergy(morning, profile: profile,
                                               hrmax: 185, restingHR: 55)
        let projected = Calories.estimateDayEnergy(morning, profile: profile,
                                                   hrmax: 185, restingHR: 55,
                                                   elapsedSeconds: 86_400)
        let bmr = Calories.mifflinStJeorBmr(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        XCTAssertLessThan(soFar.restingKcal, 50)
        XCTAssertEqual(projected.restingKcal, bmr, accuracy: 1e-6)
        XCTAssertEqual(projected.activeKcal, soFar.activeKcal, accuracy: 1e-9)
        XCTAssertGreaterThan(projected.totalKcal, 1_700)
    }

    func testSummaryEnergyIsBMRPlusWorkoutExtra() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let rest = Calories.estimateSummaryEnergy(elapsedSeconds: 86_400, profile: profile,
                                                  hrmax: 185, restingHR: 55, workouts: [])
        XCTAssertEqual(rest.totalKcal, 1755, accuracy: 1e-6)
        let withWO = Calories.estimateSummaryEnergy(
            elapsedSeconds: 86_400, profile: profile, hrmax: 185, restingHR: 55,
            workouts: [Calories.SteadyBout(durationSec: 2_400, avgHR: 150, maxHR: 175)])
        XCTAssertGreaterThan(withWO.activeKcal, 0)
        XCTAssertEqual(withWO.restingKcal, rest.restingKcal, accuracy: 1e-9)
        XCTAssertEqual(
            Calories.estimateSteadyCalories(durationSec: 60, avgHR: 80, profile: profile,
                                            hrmax: 185, restingHR: 55),
            1755 / 86_400.0 * 60, accuracy: 1e-6)
    }

    // A timestamp safely inside UTC day 2026-01-02 (2026-01-02T12:00:00Z).
    private let dayUtc = "2026-01-02"
    private let noonUtc = 1_767_355_200

    private func hr(_ tsOffsetSec: Int, _ bpm: Int) -> HRSample {
        HRSample(ts: noonUtc + tsOffsetSec, bpm: bpm)
    }

    func testAnalyzeDayCaloriesIgnoreAdjacentDayHr() throws {
        // analyzeDay must filter HR to the target UTC day before summing calories — the
        // IntelligenceEngine read window spans ~42h, so adjacent-day HR must NOT inflate the
        // day's activeKcalEst (the critical "full-window double-count" regression).
        let inDay = (0..<600).map { hr($0, 120) }
        // Same in-day HR plus 600 samples ~36h earlier (a different UTC day, inside the window).
        let withAdjacent = inDay + (0..<600).map { hr(-36 * 3_600 - $0, 120) }
        let a = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: inDay, profile: UserProfile()).daily.activeKcalEst)
        let b = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: withAdjacent, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(a, b, accuracy: 1e-6, "adjacent-day HR must not change the day's calories")
    }

    func testAnalyzeDayDayHrCoversFullCalendarDay() throws {
        // Simulate the past-day clip: the night-window HR only reaches midday; the full
        // calendar-day HR also has the afternoon. activeKcalEst must use dayHr when supplied,
        // so the full-day total exceeds the clipped night-window total (the undercount fix).
        let nightWindow = (0..<600).map { hr($0, 150) }
        let fullDay = nightWindow + (0..<600).map { hr(3 * 3_600 + $0, 150) }
        let clipped = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, profile: UserProfile()).daily.activeKcalEst)
        let full = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: nightWindow, dayHr: fullDay, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertGreaterThan(full, clipped,
                             "full calendar-day calories must exceed the clipped night-window total")
    }

    func testAnalyzeDayDayHrNilFallsBackToWindowHr() throws {
        // With no calendar-day stream, the total falls back to the window `hr` — identical to
        // passing that same window explicitly as dayHr (the (dayHr ?? hr) fallback).
        let window = (0..<600).map { hr($0, 120) }
        let fallback = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, profile: UserProfile()).daily.activeKcalEst)
        let explicit = try XCTUnwrap(AnalyticsEngine.analyzeDay(
            day: dayUtc, hr: window, dayHr: window, profile: UserProfile()).daily.activeKcalEst)
        XCTAssertEqual(fallback, explicit, accuracy: 1e-9)
    }

    /// A dropout in an otherwise dense day carries RESTING energy across the gap but not ACTIVE energy.
    ///
    /// Active duration is capped at the inferred cadence (1 s here), so the two dense blocks credit
    /// exactly as much active energy as one continuous block of the same sample count — no magic
    /// number, just the invariant. Resting is capped at the wider `dayMaxObservedGapS` and so DOES
    /// grow, which is the intended asymmetry: metabolism continues across a gap, exercise is not
    /// evidenced by one. Capping active at 60 s instead would have credited the reading before the gap
    /// with a full minute of exercise it never demonstrated. Twin of the Kotlin test.
    func testDropoutInADenseDayCarriesRestingButNotActive() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let gapped = hrDay(bpm: 130, n: 120, start: 0) + hrDay(bpm: 130, n: 120, start: 200)
        let continuous = hrDay(bpm: 130, n: 240)
        let g = Calories.estimateDayEnergy(gapped, profile: profile, hrmax: 185, restingHR: 55)
        let c = Calories.estimateDayEnergy(continuous, profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(g.activeKcal, c.activeKcal, accuracy: 1e-9,
                       "active energy must not grow across a sensor gap")
        XCTAssertGreaterThan(g.restingKcal, c.restingKcal, "resting energy SHOULD carry across the gap")
        XCTAssertLessThan(g.observedSeconds, 240.0 + 81.0, "but only as far as the observed-gap cap")
    }

    /// Two readings in the same second are reachable — `hrSample` is keyed (deviceId, ts) and the day
    /// feed unions devices, so a two-strap day has one per strap. Only the LAST of a tied run receives
    /// the interval, so without a tiebreak the day's active energy depended on the order the feed
    /// happened to arrive in, and on a sort stability Swift does not guarantee.
    ///
    /// Pinned twice: the result must not depend on input order, and a tie must hand the interval to the
    /// LOWER reading. Twin of the Kotlin test.
    func testTiedTimestampsAreOrderIndependentAndResolveToTheLowerReading() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 35, sex: "male")
        let tied = [HRSample(ts: 0, bpm: 150), HRSample(ts: 0, bpm: 60), HRSample(ts: 60, bpm: 60)]
        let forward = Calories.estimateDayEnergy(tied, profile: profile, hrmax: 185, restingHR: 55)
        let reversed = Calories.estimateDayEnergy(tied.reversed(), profile: profile, hrmax: 185, restingHR: 55)
        XCTAssertEqual(forward.activeKcal, reversed.activeKcal, accuracy: 1e-12,
                       "feed order must not change the day's energy")
        XCTAssertEqual(forward.restingKcal, reversed.restingKcal, accuracy: 1e-12)
        XCTAssertEqual(forward.activeKcal, 0.0, accuracy: 1e-12,
                       "the tie resolves to the lower reading, so no active energy is credited")
    }
}

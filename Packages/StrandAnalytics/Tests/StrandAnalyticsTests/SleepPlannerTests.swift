import XCTest
@testable import StrandAnalytics

final class SleepPlannerTests: XCTestCase {

    func testGoalFractionsMatchWhoop() {
        XCTAssertEqual(SleepPlanner.Goal.peak.fraction, 1.00, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.Goal.perform.fraction, 0.85, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.Goal.getBy.fraction, 0.70, accuracy: 1e-12)
    }

    func testProjectTonightIsOneMoreLedgerStep() throws {
        let p = try BandScores.Params.bundled().sleepLedger
        let asleep = [480.0, 450.0]
        let load = [0.0, 8.0]
        let nap = [0.0, 0.0]
        let todayHat = 10.0
        let todayNap = 20.0
        let need = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: load, napForNeed: nap,
            todayStrainHat: todayHat, todayNapMin: todayNap, params: p
        )
        let full = BandSleepLedger.run(
            asleep: asleep + [.nan],
            loadForNeed: load + [todayHat],
            napForNeed: nap + [todayNap],
            params: p
        )
        XCTAssertEqual(need.totalMin, full.need[2], accuracy: 1e-12)
        XCTAssertEqual(need.strainMin, p.a * todayHat, accuracy: 1e-12)
        XCTAssertEqual(need.napCreditMin, p.knap * todayNap, accuracy: 1e-12)
        XCTAssertEqual(need.debtMin, p.b * full.debt[2], accuracy: 1e-12)
        XCTAssertEqual(need.load, todayHat, accuracy: 1e-12)
    }

    func testPlannedStrainOnlyMovesTheStrainTerm() throws {
        let p = try BandScores.Params.bundled().sleepLedger
        let asleep = [480.0, 480.0, 480.0]
        let load = [0.0, 4.0, 6.0]
        let nap = [0.0, 0.0, 0.0]
        let today = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: load, napForNeed: nap,
            todayStrainHat: 8.0, todayNapMin: 0, params: p
        )
        let planned = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: load, napForNeed: nap,
            todayStrainHat: 12.0, todayNapMin: 0, params: p
        )
        XCTAssertEqual(planned.strainMin - today.strainMin, p.a * 4.0, accuracy: 1e-9)
        XCTAssertEqual(planned.debtMin, today.debtMin, accuracy: 1e-12)
        XCTAssertEqual(planned.napCreditMin, today.napCreditMin, accuracy: 1e-12)
        XCTAssertGreaterThan(planned.totalMin, today.totalMin)
    }

    func testNapCreditLowersTonightNeed() throws {
        let p = try BandScores.Params.bundled().sleepLedger
        let asleep = [480.0]
        let load = [0.0]
        let nap = [0.0]
        let none = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: load, napForNeed: nap,
            todayStrainHat: 5.0, todayNapMin: 0, params: p
        )
        let withNap = SleepPlanner.projectTonight(
            asleep: asleep, loadForNeed: load, napForNeed: nap,
            todayStrainHat: 5.0, todayNapMin: 40, params: p
        )
        XCTAssertEqual(none.totalMin - withNap.totalMin, p.knap * 40, accuracy: 1e-9)
    }

    func testMissingTodayLoadIsZeroStrain() throws {
        let p = try BandScores.Params.bundled().sleepLedger
        let need = SleepPlanner.projectTonight(
            asleep: [480], loadForNeed: [0], napForNeed: [0],
            todayStrainHat: .nan, todayNapMin: .nan, params: p
        )
        XCTAssertEqual(need.strainMin, 0, accuracy: 1e-12)
        XCTAssertEqual(need.napCreditMin, 0, accuracy: 1e-12)
        XCTAssertEqual(need.load, 0, accuracy: 1e-12)
    }

    func testInBedByPeakPerformGetBy() {
        let typical = SleepPlanner.TypicalSleep(
            efficiency: 0.90, latencyMin: 15, efficiencyNights: 14, latencyNights: 14,
            usingDefaultEfficiency: false, usingDefaultLatency: false
        )
        let wake = 7 * 60
        let need = 480.0
        let peak = SleepPlanner.inBedMinutes(wakeMinutes: wake, needMin: need, goal: .peak, typical: typical)
        let perform = SleepPlanner.inBedMinutes(wakeMinutes: wake, needMin: need, goal: .perform, typical: typical)
        let getBy = SleepPlanner.inBedMinutes(wakeMinutes: wake, needMin: need, goal: .getBy, typical: typical)
        // 480 / 0.9 + 15 = 548.33 → 548 min before 07:00 → 21:52
        XCTAssertEqual(peak, 21 * 60 + 52)
        // 408 / 0.9 + 15 = 468.33 → 468 → 23:12
        XCTAssertEqual(perform, 23 * 60 + 12)
        // 336 / 0.9 + 15 = 388.33 → 388 → 00:32
        XCTAssertEqual(getBy, 32)
        XCTAssertLessThan(peak, perform)
        XCTAssertGreaterThan(((perform - peak) + 24 * 60) % (24 * 60), 0)
    }

    func testInBedWrapsBeforeMidnight() {
        let typical = SleepPlanner.TypicalSleep(
            efficiency: 0.90, latencyMin: 0, efficiencyNights: 14, latencyNights: 14,
            usingDefaultEfficiency: false, usingDefaultLatency: false
        )
        let bed = SleepPlanner.inBedMinutes(wakeMinutes: 60, needMin: 480, goal: .peak, typical: typical)
        // 480 / 0.9 = 533.33 → 533 min before 01:00 → 16:07 previous calendar day
        XCTAssertEqual(bed, 16 * 60 + 7)
    }

    func testTypicalSleepUsesMedianAndDefaults() {
        var nights: [SleepPlanner.NightSample] = (0..<20).map { i in
            SleepPlanner.NightSample(efficiency: 0.80 + Double(i) * 0.005, latencyMin: 10 + Double(i))
        }
        let typical = SleepPlanner.typicalSleep(nights, window: 30)
        XCTAssertFalse(typical.usingDefaultEfficiency)
        XCTAssertFalse(typical.usingDefaultLatency)
        XCTAssertEqual(typical.efficiencyNights, 20)
        XCTAssertEqual(typical.latencyNights, 20)
        XCTAssertEqual(typical.efficiency, BandScores.median(nights.compactMap(\.efficiency)), accuracy: 1e-12)
        XCTAssertEqual(typical.latencyMin, BandScores.median(nights.compactMap(\.latencyMin)), accuracy: 1e-12)

        nights = Array(repeating: SleepPlanner.NightSample(), count: 5)
        let cold = SleepPlanner.typicalSleep(nights)
        XCTAssertTrue(cold.usingDefaultEfficiency)
        XCTAssertTrue(cold.usingDefaultLatency)
        XCTAssertEqual(cold.efficiency, SleepPlanner.defaultEfficiency, accuracy: 1e-12)
        XCTAssertEqual(cold.latencyMin, SleepPlanner.defaultLatencyMin, accuracy: 1e-12)
    }

    func testTypicalSleepHonoursFourteenToThirtyWindow() {
        let nights = (0..<40).map { i in
            SleepPlanner.NightSample(efficiency: 0.70 + Double(i) * 0.001, latencyMin: Double(i))
        }
        let typical = SleepPlanner.typicalSleep(nights, window: 30)
        XCTAssertEqual(typical.efficiencyNights, 30)
        XCTAssertEqual(typical.latencyNights, 30)
        let last30 = Array(nights.suffix(30))
        XCTAssertEqual(typical.efficiency, BandScores.median(last30.compactMap(\.efficiency)), accuracy: 1e-12)
    }

    func testNormalizedEfficiencyAcceptsPercentOrFraction() {
        XCTAssertEqual(SleepPlanner.normalizedEfficiency(0.92), 0.92, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.normalizedEfficiency(92), 0.92, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.normalizedEfficiency(0), 0, accuracy: 1e-12)
        XCTAssertEqual(SleepPlanner.normalizedEfficiency(-1), 0, accuracy: 1e-12)
    }

    func testOnsetLatencyIsInitialWakeRun() {
        let start = 1_700_000_000
        let json = """
        [{"start":\(start),"end":\(start + 12 * 60),"stage":"wake"},\
        {"start":\(start + 12 * 60),"end":\(start + 60 * 60),"stage":"light"}]
        """
        XCTAssertEqual(try XCTUnwrap(SleepPlanner.onsetLatencyMinutes(stagesJSON: json)), 12, accuracy: 1e-9)
        let asleepFirst = """
        [{"start":\(start),"end":\(start + 60 * 60),"stage":"light"}]
        """
        XCTAssertEqual(try XCTUnwrap(SleepPlanner.onsetLatencyMinutes(stagesJSON: asleepFirst)), 0, accuracy: 1e-12)
        XCTAssertNil(SleepPlanner.onsetLatencyMinutes(stagesJSON: "{\"light\":250}"))
        XCTAssertNil(SleepPlanner.onsetLatencyMinutes(stagesJSON: nil))
    }

    func testDoesNotInventASecondNeedFormula() throws {
        let src = try String(contentsOfFile: #filePath
            .replacingOccurrences(of: "Tests/StrandAnalyticsTests/SleepPlannerTests.swift",
                                  with: "Sources/StrandAnalytics/SleepPlanner.swift"))
        XCTAssertTrue(src.contains("BandSleepLedger.run("))
        XCTAssertFalse(src.contains("1.7"))
        XCTAssertFalse(src.contains("personalizedNeedHours"))
        XCTAssertFalse(src.contains("SleepDebt.ledger"))
    }
}

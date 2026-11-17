import XCTest
@testable import bandcheck

final class AgreementTests: XCTestCase {
    func testMaeAndBiasAndWithinTol() {
        let pairs = [
            Pair(day: "2026-01-01", band: 10, whoop: 8),
            Pair(day: "2026-01-02", band: 6, whoop: 8),
            Pair(day: "2026-01-03", band: 8, whoop: 8),
        ]
        let a = agree("x", pairs, tolerance: 1.5)
        XCTAssertEqual(a.n, 3)
        XCTAssertEqual(a.mae, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.bias, 0, accuracy: 1e-9)
        XCTAssertEqual(a.withinTol, 1.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(a.worstDay, "2026-01-01")
    }

    func testEmptySeriesIsNanNotZero() {
        let a = agree("empty", [], tolerance: 1)
        XCTAssertEqual(a.n, 0)
        XCTAssertTrue(a.mae.isNaN)
        XCTAssertTrue(a.withinTol.isNaN)
    }

    func testStrain21FromStoredEffort() {
        XCTAssertEqual(strain21(fromStoredEffort100: 100)!, 21, accuracy: 1e-9)
        XCTAssertEqual(strain21(fromStoredEffort100: 50)!, 10.5, accuracy: 1e-9)
        XCTAssertNil(strain21(fromStoredEffort100: nil))
    }
}

final class OverlapTests: XCTestCase {
    func testMatchRequiresHalfTheShorterSpan() {
        let pred = [TimeSpan(start: 0, end: 600, day: "d")]
        let refHit = [TimeSpan(start: 100, end: 700, day: "d")]
        let hit = matchSpans(pred, refHit)
        XCTAssertEqual(hit.truePositives, 1)
        XCTAssertEqual(hit.precision, 1, accuracy: 1e-9)
        XCTAssertEqual(hit.recall, 1, accuracy: 1e-9)

        let refMiss = [TimeSpan(start: 500, end: 1100, day: "d")]
        let miss = matchSpans(pred, refMiss)
        XCTAssertEqual(miss.truePositives, 0)
        XCTAssertEqual(miss.falsePositives.count, 1)
        XCTAssertEqual(miss.falsePositives[0].start, 0)
        XCTAssertEqual(miss.falsePositives[0].durationSec, 600)
    }

    func testGreedyOneToOne() {
        let pred = [
            TimeSpan(start: 0, end: 100, day: "d"),
            TimeSpan(start: 200, end: 300, day: "d"),
        ]
        let ref = [TimeSpan(start: 0, end: 100, day: "d")]
        let m = matchSpans(pred, ref)
        XCTAssertEqual(m.truePositives, 1)
        XCTAssertEqual(m.predicted, 2)
        XCTAssertEqual(m.reference, 1)
        XCTAssertEqual(m.falsePositives.count, 1)
    }
}

final class DayKeyTests: XCTestCase {
    func testLogicalRollsAtFourAM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: -5 * 3600)!
        // 2026-11-17 03:30 local = still the previous logical day.
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 17; c.hour = 3; c.minute = 30
        let early = cal.date(from: c)!
        XCTAssertEqual(DayKey.logical(early, calendar: cal), "2026-11-16")
        c.hour = 4; c.minute = 0
        let on = cal.date(from: c)!
        XCTAssertEqual(DayKey.logical(on, calendar: cal), "2026-11-17")
    }

    func testJournalTitleKeyFoldsPunctuation() {
        XCTAssertEqual(journalTitleKey("Shared your bed?"), journalTitleKey("shared your bed"))
        XCTAssertNotEqual(journalTitleKey("Did you share your bed?"), journalTitleKey("Shared your bed?"))
    }
}

final class InvariantTests: XCTestCase {
    func testStepsUndercountAtTenPercent() {
        let days = [
            StepsDay(day: "a", strap: 99, apple: 8202, resolved: 8202),
            StepsDay(day: "b", strap: 900, apple: 1000, resolved: 1000),
            StepsDay(day: "c", strap: nil, apple: 5000, resolved: 5000),
        ]
        let under = stepsUndercount(days)
        XCTAssertEqual(under.map(\.day), ["a"])
    }

    func testFusionPrefersAppleStepsOverStrapEstimate() {
        let days = resolveStepsDays(strapByDay: ["d": 99], appleByDay: ["d": 8202])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].resolved ?? -1, 8202, accuracy: 1e-9)
    }

    func testJournalDuplicateTitles() {
        let d = journalDuplicateTitles([
            "Shared your bed?",
            "shared your bed",
            "Did you share your bed?",
        ])
        XCTAssertEqual(d["shared your bed"]?.count, 2)
        XCTAssertNil(d[journalTitleKey("Did you share your bed?")])
    }

    func testVo2WithoutApple() {
        let series = [
            MetricPointRow(deviceId: "my-whoop-noop", day: "2026-11-16", key: "vo2max_est", value: 48),
            MetricPointRow(deviceId: "apple-health", day: "2026-11-10", key: "vo2max", value: 44),
        ]
        let apple = [
            AppleDailyRow(day: "2026-11-10", steps: 8000, vo2max: 44),
            AppleDailyRow(day: "2026-11-16", steps: 8000, vo2max: nil),
        ]
        XCTAssertEqual(vo2WithoutApple(series: series, apple: apple), ["2026-11-16"])
    }
}

final class ThresholdTests: XCTestCase {
    func testRegressionWhenMaeExceedsCap() {
        let a = SeriesAgreement(name: "replay.recovery", n: 10, mae: 12, bias: 1,
                                withinTol: 0.4, tolerance: 8, worstDay: "2026-01-01", worstAbsErr: 20)
        let t = Thresholds(
            agreement: ["replay.recovery": .init(maxMae: 10, maxAbsBias: 5, minWithinTol: 0.3, minN: 5)],
            detection: .init(minPrecision: 0, minRecall: 0, minReference: 0),
            invariants: Thresholds.defaults.invariants)
        let fails = evaluateGates(agreements: [a], detection: [:], invariants: [], thresholds: t)
        XCTAssertEqual(fails.map(\.check), ["replay.recovery"])
    }

    func testEmptyNDoesNotFailMae() {
        let a = SeriesAgreement(name: "stored_computed.day_strain", n: 0, mae: .nan, bias: .nan,
                                withinTol: .nan, tolerance: 1.5, worstDay: nil, worstAbsErr: nil)
        let t = Thresholds(
            agreement: ["stored_computed.day_strain": .init(maxMae: 1, maxAbsBias: 1, minWithinTol: 0.9, minN: 0)],
            detection: Thresholds.defaults.detection,
            invariants: Thresholds.defaults.invariants)
        XCTAssertTrue(evaluateGates(agreements: [a], detection: [:], invariants: [], thresholds: t).isEmpty)
    }

    func testLoadSnakeCaseJSON() throws {
        let json = """
        {"agreement":{"replay.recovery":{"max_mae":10,"max_abs_bias":5,"min_within_tol":0.3,"min_n":5}},
         "detection":{"min_precision":0.1,"min_recall":0.2,"min_reference":1},
         "invariants":{"max_steps_undercount_days":2,"max_duplicate_daily_metric":0,"max_auto_overlap":0,
           "max_workouts_without_hr":3,"max_journal_duplicate_titles":4,"max_metrics_without_source":5,
           "max_unresolved_steps_days":6}}
        """
        let t = try JSONDecoder().decode(Thresholds.self, from: Data(json.utf8))
        XCTAssertEqual(t.agreement["replay.recovery"]?.maxMae, 10)
        XCTAssertEqual(t.invariants.maxWorkoutsWithoutHR, 3)
        XCTAssertEqual(t.detection.minRecall, 0.2, accuracy: 1e-9)
    }

    func testInvariantCap() {
        let r = InvariantResult(name: "steps_undercount", pass: false, failCount: 2, checked: 2, note: "")
        var t = Thresholds.defaults
        t.invariants.maxStepsUndercountDays = 1
        let fails = evaluateGates(agreements: [], detection: [:], invariants: [r], thresholds: t)
        XCTAssertEqual(fails.first?.check, "steps_undercount")
    }

    func testHeldOutCThresholdIsLoaded() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("thresholds.json")
        let t = try Thresholds.load(path: url.path)
        XCTAssertEqual(t.agreement["eval.strain_c_heldout"]!.maxMae, 1.1, accuracy: 1e-12)
        XCTAssertNil(t.agreement["eval.strain_a_heldout"])
        XCTAssertNil(t.agreement["eval.strain_b_heldout"])
    }

    func testZoneMinutesPutsRemainderInSedentaryBin() {
        let start = Date(timeIntervalSince1970: 0)
        let w = WhoopWorkout(start: start, end: start.addingTimeInterval(3600),
                             startTs: 0, endTs: 3600, day: "d", strain: 10,
                             durationMin: 60, z1: 40, z2: 40, z3: 0, z4: 0, z5: 0, activity: "Run")
        let m = zoneMinutes6(w)
        XCTAssertEqual(m.count, 6)
        XCTAssertEqual(m[0], 12, accuracy: 1e-9) // 20% below z1
        XCTAssertEqual(m[1], 24, accuracy: 1e-9)
        XCTAssertEqual(m[2], 24, accuracy: 1e-9)
        XCTAssertEqual(m[3] + m[4] + m[5], 0, accuracy: 1e-9)
    }
}

final class StrainEvalTests: XCTestCase {
    func testAI32WeightAtZone1MidpointIsOne() {
        XCTAssertEqual(StrainEval.ai32Weight(pctHRR: 55), 0.9999914251, accuracy: 1e-9)
        XCTAssertEqual(StrainEval.ai32Weight(pctHRR: 15), 0.0166046142, accuracy: 1e-9)
        XCTAssertEqual(StrainEval.ai32Weight(pctHRR: 95), 9.5677684838, accuracy: 1e-9)
    }

    func testAI32SoftCapOnHourZone1() {
        let load = 60 * StrainEval.ai32Weight(pctHRR: 55)
        XCTAssertEqual(StrainEval.ai32Strain(load: load), 9.6946605014, accuracy: 1e-9)
    }

    func testPatentWeightSteps() {
        XCTAssertEqual(StrainEval.patentWeight(v: 0, t1: 0.5, t2: 0.8), 0)
        XCTAssertEqual(StrainEval.patentWeight(v: 0.4, t1: 0.5, t2: 0.8), 1)
        XCTAssertEqual(StrainEval.patentWeight(v: 0.5, t1: 0.5, t2: 0.8), 1)
        XCTAssertEqual(StrainEval.patentWeight(v: 0.7, t1: 0.5, t2: 0.8), 18)
        XCTAssertEqual(StrainEval.patentWeight(v: 0.9, t1: 0.5, t2: 0.8), 42)
    }

    func testSplitIsTimeOrderedSeventyThirty() {
        let items = Array(0..<10)
        let (train, test) = StrainEval.splitTrainTest(items)
        XCTAssertEqual(train, [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(test, [7, 8, 9])
    }

    func testHeldOutCMatchesBandStrainOnSyntheticZoneMinutes() {
        // 20 identical 60 min zone-1 bouts. WHOOP label = production BandStrain on those
        // minutes (golden 7.9857940949). Held-out C must replay that map, not a private row.
        let t0: TimeInterval = 1_735_689_600 // 2025-01-01 UTC, after the 2024-11 zone switch
        var workouts: [WhoopWorkout] = []
        for i in 0..<20 {
            let start = Date(timeIntervalSince1970: t0 + Double(i) * 3600)
            workouts.append(WhoopWorkout(
                start: start, end: start.addingTimeInterval(3600),
                startTs: Int(start.timeIntervalSince1970),
                endTs: Int(start.timeIntervalSince1970) + 3600,
                day: "2025-01-01", strain: 7.985794094921714, durationMin: 60,
                z1: 100, z2: 0, z3: 0, z4: 0, z5: 0, activity: "Run",
                energyKcal: nil, avgHR: 130, maxHR: 160))
        }
        let got = StrainEval.heldOutAgreements(
            workouts: workouts, rhrByDay: ["2025-01-01": 63], hrMax: 198)
        XCTAssertEqual(got.map(\.name), [
            "eval.strain_a_heldout", "eval.strain_b_heldout", "eval.strain_c_heldout",
        ])
        let c = got.first { $0.name == "eval.strain_c_heldout" }!
        XCTAssertEqual(c.n, 6) // 20 * 0.30
        XCTAssertEqual(c.mae, 0, accuracy: 1e-6)
        XCTAssertEqual(c.bias, 0, accuracy: 1e-6)
        XCTAssertEqual(c.withinTol, 1, accuracy: 1e-12)
        let empty = StrainEval.heldOutAgreements(workouts: [], rhrByDay: [:], hrMax: 198)
        XCTAssertEqual(empty.map(\.n), [0, 0, 0])
    }
}

final class RhrDefinitionTests: XCTestCase {
    func testHoldoutTakesLastThirtyPercent() {
        let pairs = (1...10).map {
            Pair(day: String(format: "2026-01-%02d", $0), band: Double($0), whoop: Double($0))
        }
        let held = holdout(pairs)
        XCTAssertEqual(held.map(\.day), ["2026-01-08", "2026-01-09", "2026-01-10"])
    }
}

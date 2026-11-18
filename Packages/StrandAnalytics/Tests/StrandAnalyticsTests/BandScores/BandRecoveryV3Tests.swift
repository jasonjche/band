import XCTest
@testable import StrandAnalytics

final class BandScoresRecoveryV3Tests: XCTestCase {

    func testOracleWhoopSleepGoldenMatchesTo1e9() throws {
        try assertScoreOracle(resource: "golden_recovery_v3")
    }

    func testOraclePerfOursGoldenMatchesTo1e9() throws {
        try assertScoreOracle(resource: "golden_recovery_v3_perf_ours")
    }

    func testBundledV3ParamsArePerfOursTrain() throws {
        let params = try BandScores.Params.bundled()
        XCTAssertEqual(params.schemaVersion, 2)
        XCTAssertEqual(params.recoveryV3.schemaVersion, 5)
        XCTAssertEqual(params.recoveryV3.variant, "head_perf_ours_train")
        XCTAssertEqual(params.recoveryV3.warmupNights, 21)
        XCTAssertEqual(params.recoveryV3.halfLifeDays, 10, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.zScale, 8.6076235845313, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.b0, 0.5831048802710344, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.wHrv, 0.8125248327804836, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.wSleep, 0.15955536837785575, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.hingeHvn, 0.55, accuracy: 0)
        XCTAssertEqual(params.recoveryV3.hingeWeight, -8.0, accuracy: 0)
        XCTAssertEqual(
            BandRecoveryV3.alpha(halfLifeDays: 10),
            0.06696700846319259,
            accuracy: 1e-15
        )
    }

    func testHvnHingeZeroAtAndAboveThreshold() {
        XCTAssertEqual(BandRecoveryV3.hvnHinge(asleep: 231, need: 420, threshold: 0.55), 0, accuracy: 1e-15)
        XCTAssertEqual(BandRecoveryV3.hvnHinge(asleep: 420, need: 420, threshold: 0.55), 0, accuracy: 1e-15)
        XCTAssertEqual(BandRecoveryV3.hvnHinge(asleep: 180, need: 420, threshold: 0.55),
                       0.55 - 180.0 / 420.0, accuracy: 1e-15)
        XCTAssertEqual(BandRecoveryV3.hvnHinge(asleep: 180, need: 0, threshold: 0.55), 0, accuracy: 0)
        XCTAssertEqual(BandRecoveryV3.hvnHinge(asleep: .nan, need: 420, threshold: 0.55), 0, accuracy: 0)
    }

    func testLogisticHingeMatchesPythonAndLeavesLongNights() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        let long = BandRecoveryV3.logistic(z: 0, sleepPct: 80, params: params, asleep: 420, need: 420)
        let atT = BandRecoveryV3.logistic(z: 0, sleepPct: 80, params: params, asleep: 231, need: 420)
        let short = BandRecoveryV3.logistic(z: 0, sleepPct: 80, params: params, asleep: 180, need: 420)
        let missing = BandRecoveryV3.logistic(z: 0, sleepPct: 80, params: params)
        XCTAssertEqual(long, 65.39143299177093, accuracy: 1e-9)
        XCTAssertEqual(atT, long, accuracy: 1e-12)
        XCTAssertEqual(missing, long, accuracy: 1e-12)
        XCTAssertEqual(short, 41.69908581278962, accuracy: 1e-9)
        XCTAssertLessThan(short, long)
    }

    func testRunHingeLeavesLongNightsIdenticalToDisabled() throws {
        var params = try BandScores.Params.bundled().recoveryV3
        let n = 40
        let hrv = [Double](repeating: 55, count: n)
        let sleep = [Double](repeating: 80, count: n)
        let asleep = [Double](repeating: 420, count: n)
        let need = [Double](repeating: 420, count: n)
        let sources = [BandScores.DaySource](repeating: .strap, count: n)
        let withHinge = BandRecoveryV3.run(
            hrv: hrv, sleepPct: sleep, sources: sources, params: params,
            asleep: asleep, need: need
        )
        params.hingeWeight = 0
        let off = BandRecoveryV3.run(
            hrv: hrv, sleepPct: sleep, sources: sources, params: params,
            asleep: asleep, need: need
        )
        for t in 0..<n {
            switch (withHinge.recovery[t].isFinite, off.recovery[t].isFinite) {
            case (false, false):
                break
            case (true, true):
                XCTAssertEqual(withHinge.recovery[t], off.recovery[t], accuracy: 1e-12, "t=\(t)")
            default:
                XCTFail("publish mismatch t=\(t)")
            }
        }
    }

    func testRunHingeLowersOnlyShortNights() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        let n = 40
        var asleep = [Double](repeating: 420, count: n)
        asleep[n - 1] = 180
        let need = [Double](repeating: 420, count: n)
        let hrv = [Double](repeating: 55, count: n)
        let sleep = [Double](repeating: 80, count: n)
        let sources = [BandScores.DaySource](repeating: .strap, count: n)
        var offParams = params
        offParams.hingeWeight = 0
        let on = BandRecoveryV3.run(
            hrv: hrv, sleepPct: sleep, sources: sources, params: params,
            asleep: asleep, need: need
        )
        let off = BandRecoveryV3.run(
            hrv: hrv, sleepPct: sleep, sources: sources, params: offParams,
            asleep: asleep, need: need
        )
        let last = n - 1
        XCTAssertTrue(on.recovery[last].isFinite)
        XCTAssertEqual(on.recovery[last - 1], off.recovery[last - 1], accuracy: 1e-12)
        XCTAssertLessThan(on.recovery[last], off.recovery[last])
    }

    func testWarmupWithholdsUntilFiniteZCount() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        let n = 40
        let hrv = [Double](repeating: 55, count: n)
        let sleep = [Double](repeating: 80, count: n)
        let sources = [BandScores.DaySource](repeating: .strap, count: n)
        let got = BandRecoveryV3.run(hrv: hrv, sleepPct: sleep, sources: sources, params: params)
        let warmup = params.warmupNights
        for t in 0..<n {
            if t == 0 {
                XCTAssertTrue(got.z[t].isNaN, "z on first night")
                XCTAssertTrue(got.recovery[t].isNaN, "no publish without a prior EWMA")
            } else if t < warmup {
                XCTAssertTrue(got.z[t].isFinite, "z after first ingest t=\(t)")
                XCTAssertTrue(got.recovery[t].isNaN, "still warming t=\(t)")
            } else {
                XCTAssertTrue(got.recovery[t].isFinite, "published t=\(t)")
                XCTAssertGreaterThanOrEqual(got.recovery[t], 1)
                XCTAssertLessThanOrEqual(got.recovery[t], 99)
            }
        }
    }

    func testMissingNightsCarryStateAndDoNotUpdate() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        let n = 45
        var hrv = [Double](repeating: 60, count: n)
        let sleep = [Double](repeating: 80, count: n)
        hrv[10] = .nan
        hrv[11] = .nan
        hrv[12] = .nan
        let sources = [BandScores.DaySource](repeating: .imported, count: n)
        let got = BandRecoveryV3.run(hrv: hrv, sleepPct: sleep, sources: sources, params: params)
        XCTAssertTrue(got.recovery[10].isNaN)
        XCTAssertTrue(got.recovery[11].isNaN)
        XCTAssertTrue(got.recovery[12].isNaN)
        XCTAssertEqual(got.baseline[11], got.baseline[10], accuracy: 1e-15)
        XCTAssertEqual(got.baseline[12], got.baseline[11], accuracy: 1e-15)
        XCTAssertEqual(got.baseline[13], got.baseline[12], accuracy: 1e-15,
                       "missing nights do not move EWMA; next baseline is the carried value")
        let warmup = params.warmupNights
        // t=0 inits EWMA; t=10..12 add no residual, so first publish is t = warmup + 3.
        let firstPub = warmup + 3
        for t in 0..<firstPub {
            XCTAssertTrue(got.recovery[t].isNaN, "missing nights delay publish t=\(t)")
        }
        XCTAssertTrue(got.recovery[firstPub].isFinite, "publishes once finite-z count hits N")
        var published = 0
        for t in firstPub..<n where got.recovery[t].isFinite {
            published += 1
            XCTAssertGreaterThan(got.recovery[t], 1)
            XCTAssertLessThan(got.recovery[t], 99)
        }
        XCTAssertGreaterThan(published, 0)
    }

    func testRunWarmupGoldenMatchesTo1e9() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden_recovery_v3_run.json")
        let golden = try JSONDecoder().decode(RecoveryV3RunGolden.self, from: Data(contentsOf: url))
        XCTAssertEqual(golden.warmupNights, 21)
        var params = try BandScores.Params.bundled().recoveryV3
        params.b0 = golden.head.b0
        params.wHrv = golden.head.wHrv
        params.wSleep = golden.head.wSleep
        params.warmupNights = golden.warmupNights
        let sources: [BandScores.DaySource] = golden.sources.map {
            $0 == "strap" ? .strap : .imported
        }
        let hrv = golden.hrv.map { $0 ?? .nan }
        let got = BandRecoveryV3.run(
            hrv: hrv, sleepPct: golden.sleepPerf, sources: sources, params: params
        )
        XCTAssertEqual(got.recovery.count, golden.recovery.count)
        var nFin = 0
        var maxErr = 0.0
        for t in 0..<golden.recovery.count {
            let want = golden.recovery[t]
            let rec = got.recovery[t]
            if want == nil {
                XCTAssertTrue(rec.isNaN, "t=\(t) expected null recovery")
            } else {
                let w = try XCTUnwrap(want)
                XCTAssertEqual(rec, w, accuracy: 1e-9, "recovery t=\(t)")
                maxErr = max(maxErr, abs(rec - w))
                nFin += 1
            }
            if t < golden.z.count {
                switch (BandScores.finite(got.z[t]), golden.z[t]) {
                case (nil, nil):
                    break
                case let (a?, b?):
                    XCTAssertEqual(a, b, accuracy: 1e-9, "z t=\(t)")
                default:
                    XCTFail("z nil mismatch t=\(t)")
                }
            }
            if t < golden.baseline.count {
                switch (BandScores.finite(got.baseline[t]), golden.baseline[t]) {
                case (nil, nil):
                    break
                case let (a?, b?):
                    XCTAssertEqual(a, b, accuracy: 1e-9, "baseline t=\(t)")
                default:
                    XCTFail("baseline nil mismatch t=\(t)")
                }
            }
        }
        XCTAssertEqual(nFin, golden.nPublished)
        XCTAssertGreaterThan(nFin, 0)
        XCTAssertLessThanOrEqual(maxErr, 1e-9)
        XCTAssertTrue(got.recovery[golden.switchIndex].isNaN, "switch night restarts")
    }

    func testClipsRecoveryAt1And99() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        let n = 40
        var high = [Double](repeating: 55, count: n)
        var low = [Double](repeating: 55, count: n)
        var sleepHigh = [Double](repeating: 80, count: n)
        var sleepLow = [Double](repeating: 80, count: n)
        high[n - 1] = 5_000
        sleepHigh[n - 1] = 100
        low[n - 1] = 1
        sleepLow[n - 1] = 0
        let sources = [BandScores.DaySource](repeating: .strap, count: n)
        let hi = BandRecoveryV3.run(hrv: high, sleepPct: sleepHigh, sources: sources, params: params)
        let lo = BandRecoveryV3.run(hrv: low, sleepPct: sleepLow, sources: sources, params: params)
        XCTAssertEqual(hi.recovery[n - 1], 99, accuracy: 1e-12)
        XCTAssertEqual(lo.recovery[n - 1], 1, accuracy: 1e-12)
        XCTAssertEqual(hi.z[n - 1], 6, accuracy: 1e-12)
        XCTAssertEqual(lo.z[n - 1], -6, accuracy: 1e-12)
    }

    func testSourceSwitchRestartsAndAfterWarmupStaysWithin3Mae() throws {
        let params = try BandScores.Params.bundled().recoveryV3
        XCTAssertEqual(params.warmupNights, 21)
        let n = 80
        let tSwitch = 25
        var hrv: [Double] = []
        var sleep: [Double] = []
        for t in 0..<n {
            hrv.append(50.0 + 8.0 * sin(Double(t) / 7.0) + (t % 5 == 0 ? 12.0 : 0.0))
            sleep.append(75.0 + 10.0 * cos(Double(t) / 5.0))
        }
        let imported = [BandScores.DaySource](repeating: .imported, count: n)
        let noSwitch = BandRecoveryV3.run(hrv: hrv, sleepPct: sleep, sources: imported, params: params)

        var maes: [String: Double] = [:]
        for (k, p) in [(0.7, 0.9), (0.7, 1.1), (1.3, 0.9), (1.3, 1.1)] {
            var mapped = hrv
            var sources = imported
            for t in tSwitch..<n {
                sources[t] = .strap
                mapped[t] = k * pow(max(mapped[t], 1.0), p)
            }
            let got = BandRecoveryV3.run(hrv: mapped, sleepPct: sleep, sources: sources, params: params)
            for t in tSwitch..<(tSwitch + params.warmupNights) {
                XCTAssertTrue(got.recovery[t].isNaN, "warmup after switch t=\(t) k=\(k) p=\(p)")
            }
            var sum = 0.0
            var count = 0
            for t in (tSwitch + params.warmupNights)..<n {
                let a = got.recovery[t]
                let b = noSwitch.recovery[t]
                XCTAssertTrue(a.isFinite, "published t=\(t) k=\(k) p=\(p)")
                XCTAssertTrue(b.isFinite, "no-switch published t=\(t)")
                sum += abs(a - b)
                count += 1
            }
            XCTAssertGreaterThan(count, 10)
            let mae = sum / Double(count)
            maes["k=\(k) p=\(p)"] = mae
            // whoopfit6 synthetic at N=21: MAE 1.27–1.35 vs no-switch after warmup.
            XCTAssertLessThanOrEqual(mae, 2.0, "k=\(k) p=\(p) mae=\(mae) n=\(count)")
        }
        // Keep the measured numbers in the failure message if a later map regresses.
        XCTAssertEqual(maes.count, 4)
    }

    func testEvaluateLeavesRound2RecoveryUntouchedAndEmitsV3AfterWarmup() throws {
        let params = try BandScores.Params.bundled()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "golden_synthetic", withExtension: "json"))
        let golden = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        let inputs = golden.days.map(\.asInput)
        let got = BandScores.evaluate(days: inputs, params: params)
        XCTAssertEqual(got.count, golden.outputs.count)
        var v3Count = 0
        for (g, e) in zip(got, golden.outputs) {
            switch (g.recovery, e.recovery) {
            case (nil, nil):
                break
            case let (a?, b?):
                XCTAssertEqual(a, b, accuracy: 1e-9, "round-2 recovery \(e.day)")
            default:
                XCTFail("round-2 recovery nil mismatch \(e.day)")
            }
            if g.recoveryV3 != nil { v3Count += 1 }
        }
        XCTAssertGreaterThan(v3Count, 0)
        XCTAssertTrue(got.prefix(params.recoveryV3.warmupNights).allSatisfy { $0.recoveryV3 == nil })
    }

    // MARK: - golden loader

    private func assertScoreOracle(resource: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: resource, withExtension: "json"),
            "missing \(resource).json",
            file: file, line: line
        )
        let golden = try JSONDecoder().decode(RecoveryV3Golden.self, from: Data(contentsOf: url))
        var params = try BandScores.Params.bundled().recoveryV3
        params.b0 = golden.head.b0
        params.wHrv = golden.head.wHrv
        params.wSleep = golden.head.wSleep
        let got = BandRecoveryV3.score(
            hrv: golden.hrv, sleepPct: golden.sleepPerf, params: params, zScale: golden.zScale
        )
        XCTAssertEqual(got.recovery.count, golden.recovery.count, file: file, line: line)
        var nFin = 0
        var maxErr = 0.0
        for t in 0..<golden.recovery.count {
            let want = golden.recovery[t]
            let rec = got.recovery[t]
            if want == nil {
                XCTAssertTrue(rec.isNaN, "t=\(t) expected null recovery", file: file, line: line)
                continue
            }
            let w = try XCTUnwrap(want)
            XCTAssertEqual(rec, w, accuracy: 1e-9, "recovery t=\(t)", file: file, line: line)
            maxErr = max(maxErr, abs(rec - w))
            nFin += 1
            if t < golden.z.count {
                switch (BandScores.finite(got.z[t]), golden.z[t]) {
                case (nil, nil):
                    break
                case let (a?, b?):
                    XCTAssertEqual(a, b, accuracy: 1e-9, "z t=\(t)", file: file, line: line)
                default:
                    XCTFail("z nil mismatch t=\(t)", file: file, line: line)
                }
            }
            if t < golden.baseline.count {
                switch (BandScores.finite(got.baseline[t]), golden.baseline[t]) {
                case (nil, nil):
                    break
                case let (a?, b?):
                    XCTAssertEqual(a, b, accuracy: 1e-9, "baseline t=\(t)", file: file, line: line)
                default:
                    XCTFail("baseline nil mismatch t=\(t)", file: file, line: line)
                }
            }
        }
        XCTAssertGreaterThan(nFin, 0, file: file, line: line)
        XCTAssertLessThanOrEqual(maxErr, 1e-9, file: file, line: line)
    }
}

private struct RecoveryV3Golden: Decodable {
    var alpha: Double
    var zScale: Double
    var head: Head
    var hrv: [Double]
    var sleepPerf: [Double]
    var baseline: [Double?]
    var z: [Double?]
    var recovery: [Double?]

    enum CodingKeys: String, CodingKey {
        case alpha, hrv, baseline, z, recovery, head
        case zScale = "z_scale"
        case sleepPerf = "sleep_perf"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alpha = try c.decode(Double.self, forKey: .alpha)
        zScale = try c.decode(Double.self, forKey: .zScale)
        head = try c.decode(Head.self, forKey: .head)
        hrv = try c.decode([Double].self, forKey: .hrv)
        sleepPerf = try c.decode([Double].self, forKey: .sleepPerf)
        baseline = try c.decodeIfPresent([Double?].self, forKey: .baseline) ?? []
        z = try c.decodeIfPresent([Double?].self, forKey: .z) ?? []
        recovery = try c.decode([Double?].self, forKey: .recovery)
    }

    struct Head: Decodable {
        var b0: Double
        var wHrv: Double
        var wSleep: Double
        enum CodingKeys: String, CodingKey {
            case b0
            case wHrv = "w_hrv"
            case wSleep = "w_sleep"
        }
    }
}

private struct RecoveryV3RunGolden: Decodable {
    var warmupNights: Int
    var switchIndex: Int
    var nPublished: Int
    var head: RecoveryV3Golden.Head
    var hrv: [Double?]
    var sleepPerf: [Double]
    var sources: [String]
    var baseline: [Double?]
    var z: [Double?]
    var recovery: [Double?]

    enum CodingKeys: String, CodingKey {
        case hrv, baseline, z, recovery, head, sources
        case warmupNights = "warmup_nights"
        case switchIndex = "switch_index"
        case nPublished = "n_published"
        case sleepPerf = "sleep_perf"
    }
}

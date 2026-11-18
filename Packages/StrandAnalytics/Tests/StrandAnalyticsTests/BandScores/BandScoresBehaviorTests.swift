import XCTest
@testable import StrandAnalytics

final class BandScoresBehaviorTests: XCTestCase {

    func testCausalityPerturbingFutureDoesNotChangePast() throws {
        let params = try BandScores.Params.bundled()
        let days = try loadDays("golden_synthetic")
        let base = BandScores.evaluate(days: days, params: params)

        var perturbed = days
        var last = perturbed[perturbed.count - 1]
        last.hrvMs = (last.hrvMs ?? 60) + 40
        last.onsetMin = (last.onsetMin ?? 1400) - 90
        last.energyKcal = (last.energyKcal ?? 2000) + 800
        perturbed[perturbed.count - 1] = last
        let after = BandScores.evaluate(days: perturbed, params: params)

        XCTAssertEqual(base.count, after.count)
        for i in 0..<(base.count - 1) {
            XCTAssertEqual(base[i].need, after[i].need)
            XCTAssertEqual(base[i].debt, after[i].debt)
            XCTAssertEqual(base[i].cons, after[i].cons)
            XCTAssertEqual(base[i].perf, after[i].perf)
            XCTAssertEqual(base[i].recovery, after[i].recovery)
            XCTAssertEqual(base[i].zHrv, after[i].zHrv)
            XCTAssertEqual(base[i].baselineHrvLn, after[i].baselineHrvLn)
            XCTAssertEqual(base[i].strainHat, after[i].strainHat)
        }
        XCTAssertNotEqual(base.last?.zHrv, after.last?.zHrv)
        XCTAssertNotEqual(base.last?.cons, after.last?.cons)
        XCTAssertNotEqual(base.last?.strainHat, after.last?.strainHat)
        XCTAssertEqual(base.last?.baselineHrvLn, after.last?.baselineHrvLn,
                       "tonight's HRV is scored against the prior baseline and does not update it until after")
    }

    func testMissingNightDecaysDebtWithoutShortfall() throws {
        let params = try BandScores.Params.bundled()
        let p = params.sleepLedger
        let asleep = [480.0, Double.nan, 480.0]
        let load = [0.0, 0.0, 0.0]
        let nap = [0.0, 0.0, 0.0]
        let series = BandSleepLedger.run(asleep: asleep, loadForNeed: load, napForNeed: nap, params: p)
        XCTAssertEqual(series.debt[0], p.initDebt, accuracy: 1e-12)
        // asleep[1] is the missing night; the decay is applied when stepping to t=2.
        XCTAssertEqual(series.debt[2], BandScores.clip(p.decay * series.debt[1], 0, p.cap), accuracy: 1e-12)
        XCTAssertLessThan(series.debt[2], series.debt[1])
        XCTAssertGreaterThan(series.debt[2], 0)
    }

    func testDebtCapAndFloor() throws {
        var p = try BandScores.Params.bundled().sleepLedger
        p.cap = 40
        p.initDebt = 36
        p.gain = 1
        p.credit = 0
        p.decay = 1
        p.bias = 20
        p.base = 500
        p.a = 0
        p.knap = 0
        // Huge shortfall every night → hits cap.
        let asleep = [200.0, 200.0, 200.0, 200.0]
        let load = [0.0, 0.0, 0.0, 0.0]
        let nap = [0.0, 0.0, 0.0, 0.0]
        let series = BandSleepLedger.run(asleep: asleep, loadForNeed: load, napForNeed: nap, params: p)
        XCTAssertEqual(series.debt[0], 36, accuracy: 1e-12)
        for t in 1..<4 {
            XCTAssertEqual(series.debt[t], 40, accuracy: 1e-12)
        }

        p.credit = 2
        p.gain = 0
        p.bias = 0
        p.decay = 0.5
        p.initDebt = 10
        let extra = BandSleepLedger.run(
            asleep: [700, 700, 700, 700], loadForNeed: load, napForNeed: nap, params: p
        )
        XCTAssertGreaterThanOrEqual(extra.debt[3], 0)
        XCTAssertEqual(extra.debt[3], 0, accuracy: 1e-12)
    }

    func testNapCreditLowersNeedAndDoesNotEnterAsleep() throws {
        let params = try BandScores.Params.bundled()
        let p = params.sleepLedger
        let asleep = [480.0, 480.0]
        let load = [0.0, 8.0]
        let napNone = [0.0, 0.0]
        let napSome = [0.0, 40.0]
        let without = BandSleepLedger.run(asleep: asleep, loadForNeed: load, napForNeed: napNone, params: p)
        let withNap = BandSleepLedger.run(asleep: asleep, loadForNeed: load, napForNeed: napSome, params: p)
        XCTAssertEqual(without.need[1] - withNap.need[1], p.knap * 40, accuracy: 1e-9)
        XCTAssertEqual(without.debt[1], withNap.debt[1], accuracy: 1e-12,
                       "naps credit need, they do not enter the debt state on the same night")
    }

    func testOutlierDoesNotUpdateBaseline() throws {
        var x = (0..<20).map { 4.1 + 0.08 * sin(Double($0)) }
        x[15] = 12.0
        let cfg = BandBaselines.Config(
            method: .ewma, halfLife: 10, window: 28, outlierK: 4.5, zScale: 0.16, floor: 0.03
        )
        let series = BandBaselines.run(x: x, config: cfg, minP: 8)
        XCTAssertGreaterThan(series.scale[15], 1e-4)
        XCTAssertGreaterThan(abs(x[15] - series.baseline[15]), 4.5 * series.scale[15])
        XCTAssertEqual(series.baseline[16], series.baseline[15], accuracy: 1e-12)
        XCTAssertNotEqual(series.z[15], series.z[14])
    }

    private func loadDays(_ name: String) throws -> [BandScores.DayInput] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        let golden = try JSONDecoder().decode(GoldenFile.self, from: data)
        return golden.days.map(\.asInput)
    }
}


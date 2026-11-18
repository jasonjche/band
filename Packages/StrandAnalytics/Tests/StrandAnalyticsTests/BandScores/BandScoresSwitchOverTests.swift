import XCTest
@testable import StrandAnalytics

final class BandScoresSwitchOverTests: XCTestCase {

    func testSwitchGoldenMatchesTo1e9() throws {
        let golden = try loadSwitchGolden()
        let params = try BandScores.Params.bundled()
        XCTAssertEqual(golden.paramsSchemaVersion, params.schemaVersion)
        let inputs = golden.days.map(\.asInput)
        XCTAssertTrue(inputs.contains(where: { $0.source == .strap }))
        XCTAssertTrue(inputs.contains(where: { $0.source == .imported }))
        let got = BandScores.evaluate(days: inputs, params: params)
        XCTAssertEqual(got.count, golden.outputs.count)
        for (g, e) in zip(got, golden.outputs) {
            XCTAssertEqual(g.day, e.day)
            assertClose("\(e.day) strain_hat", g.strainHat, e.strainHat)
            assertClose("\(e.day) load_for_need", g.loadForNeed, e.loadForNeed)
            assertClose("\(e.day) nap_for_need", g.napForNeed, e.napForNeed)
            assertClose("\(e.day) debt", g.debt, e.debt)
            assertClose("\(e.day) need", g.need, e.need)
            assertClose("\(e.day) sri_raw", g.sriRaw, e.sriRaw)
            assertClose("\(e.day) cons", g.cons, e.cons)
            assertClose("\(e.day) perf", g.perf, e.perf)
            assertClose("\(e.day) baseline_hrv_ln", g.baselineHrvLn, e.baselineHrvLn)
            assertClose("\(e.day) z_hrv", g.zHrv, e.zHrv)
            assertClose("\(e.day) z_rhr", g.zRhr, e.zRhr)
            assertClose("\(e.day) z_rr", g.zRr, e.zRr)
            assertClose("\(e.day) z_temp", g.zTemp, e.zTemp)
            assertClose("\(e.day) z_spo2", g.zSpo2, e.zSpo2)
            assertClose("\(e.day) recovery", g.recovery, e.recovery)
        }
    }

    func testNoSwitchEqualsCurrentPipeline() throws {
        let params = try BandScores.Params.bundled()
        let days = try loadDays("golden_synthetic")
        let base = BandScores.evaluate(days: days, params: params)

        var imported = days
        for i in imported.indices { imported[i].source = .imported }
        var strap = days
        for i in strap.indices { strap[i].source = .strap }

        let asImported = BandScores.evaluate(days: imported, params: params)
        let asStrap = BandScores.evaluate(days: strap, params: params)
        XCTAssertEqual(base.count, asImported.count)
        for i in base.indices {
            XCTAssertEqual(base[i].recovery, asImported[i].recovery)
            XCTAssertEqual(base[i].zHrv, asImported[i].zHrv)
            XCTAssertEqual(base[i].baselineHrvLn, asImported[i].baselineHrvLn)
            XCTAssertEqual(base[i].recovery, asStrap[i].recovery)
            XCTAssertEqual(base[i].zHrv, asStrap[i].zHrv)
        }
    }

    func testSwitchK07P09ReturnsWithin2PointsIn2Nights() throws {
        // Policy (c) is Kalman vs Kalman: the 2-point recovery is measured against the
        // same head without the k·HRV^p map. Default mode stays EWMA (goldens untouched).
        var params = try BandScores.Params.bundled()
        params.hrvBaselineMode = .kalman
        let days = try loadDays("golden_synthetic")
        let tSwitch = 36
        XCTAssertGreaterThan(days.count, tSwitch + 3)

        let noSwitch = BandScores.evaluate(days: days, params: params)

        var switched = days
        for i in switched.indices {
            if i >= tSwitch {
                switched[i].source = .strap
                if let h = switched[i].hrvMs, h.isFinite {
                    switched[i].hrvMs = 0.7 * pow(max(h, 1.0), 0.9)
                }
            } else {
                switched[i].source = .imported
            }
        }
        let got = BandScores.evaluate(days: switched, params: params)

        var within2: Int?
        for offset in 0..<min(8, got.count - tSwitch) {
            let t = tSwitch + offset
            guard let a = got[t].recovery, let b = noSwitch[t].recovery else { continue }
            if abs(a - b) <= 2.0 {
                within2 = offset
                break
            }
        }
        XCTAssertNotNil(within2, "recovery never returned within 2 points of the no-switch run")
        XCTAssertLessThanOrEqual(within2 ?? 99, 2, "first night within 2 points was \(within2 ?? -1)")
    }

    func testMissingNightsAroundSwitchDoNotNaNLater() throws {
        let params = try BandScores.Params.bundled()
        let days = try loadDays("golden_synthetic")
        let tSwitch = 36
        var switched = days
        for i in switched.indices {
            switched[i].source = i >= tSwitch ? .strap : .imported
            if i >= tSwitch, let h = switched[i].hrvMs, h.isFinite {
                switched[i].hrvMs = 0.7 * pow(max(h, 1.0), 0.9)
            }
        }
        // Wipe physiology on the night before, the switch night, and the night after.
        for i in [tSwitch - 1, tSwitch, tSwitch + 1] {
            switched[i].hrvMs = nil
            switched[i].rhr = nil
            switched[i].resp = nil
            switched[i].temp = nil
            switched[i].spo2 = nil
        }
        let got = BandScores.evaluate(days: switched, params: params)
        XCTAssertEqual(got.count, switched.count)
        for row in got {
            if let rec = row.recovery {
                XCTAssertTrue(rec.isFinite, "recovery NaN on \(row.day)")
            }
            if let z = row.zHrv {
                XCTAssertTrue(z.isFinite, "zHrv NaN on \(row.day)")
            }
        }
        // A later complete night must still publish a finite recovery (Kalman state not poisoned).
        var later: Double?
        for row in got[(tSwitch + 2)...] {
            if let rec = row.recovery, rec.isFinite {
                later = rec
                break
            }
        }
        XCTAssertNotNil(later)
        XCTAssertGreaterThan(later ?? -1, 1)
        XCTAssertLessThan(later ?? 99, 99)
    }

    private func loadSwitchGolden() throws -> GoldenFile {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden_switch.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GoldenFile.self, from: data)
    }

    private func loadDays(_ name: String) throws -> [BandScores.DayInput] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        let golden = try JSONDecoder().decode(GoldenFile.self, from: data)
        return golden.days.map(\.asInput)
    }

    private func assertClose(_ name: String, _ got: Double?, _ exp: Double?,
                             file: StaticString = #filePath, line: UInt = #line) {
        switch (got, exp) {
        case (nil, nil):
            return
        case let (g?, e?):
            XCTAssertEqual(g, e, accuracy: 1e-9, "\(name) got \(g) expected \(e)", file: file, line: line)
        default:
            XCTFail("\(name) nil mismatch got=\(String(describing: got)) exp=\(String(describing: exp))",
                    file: file, line: line)
        }
    }
}

import XCTest
@testable import StrandAnalytics

final class BandScoresOracleTests: XCTestCase {

    func testBundledParamsDecode() throws {
        let params = try BandScores.Params.bundled()
        XCTAssertEqual(params.schemaVersion, 2)
        XCTAssertEqual(params.baselinesMinP, 8)
        XCTAssertEqual(params.sleepLedger.variant, "vs_baseline")
        XCTAssertEqual(params.baselines.hrvLn.halfLife, 10, accuracy: 0)
        XCTAssertEqual(params.baselines.rhr.halfLife, 7, accuracy: 0)
        XCTAssertEqual(params.consistency.nNights, 5)
    }

    func testSyntheticOracleMatchesTo1e9() throws {
        try assertOracle(resource: "golden_synthetic")
    }

    func testAnonymisedOracleMatchesTo1e9() throws {
        try assertOracle(resource: "golden_anonymised")
    }

    private func assertOracle(resource: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let golden = try loadGolden(resource)
        let params = try BandScores.Params.bundled()
        XCTAssertEqual(golden.paramsSchemaVersion, params.schemaVersion, file: file, line: line)
        let inputs = golden.days.map(\.asInput)
        let got = BandScores.evaluate(days: inputs, params: params)
        XCTAssertEqual(got.count, golden.outputs.count, file: file, line: line)
        for (g, e) in zip(got, golden.outputs) {
            XCTAssertEqual(g.day, e.day, file: file, line: line)
            assertClose("\(e.day) strain_hat", g.strainHat, e.strainHat, file: file, line: line)
            assertClose("\(e.day) load_for_need", g.loadForNeed, e.loadForNeed, file: file, line: line)
            assertClose("\(e.day) nap_for_need", g.napForNeed, e.napForNeed, file: file, line: line)
            assertClose("\(e.day) debt", g.debt, e.debt, file: file, line: line)
            assertClose("\(e.day) need", g.need, e.need, file: file, line: line)
            assertClose("\(e.day) sri_raw", g.sriRaw, e.sriRaw, file: file, line: line)
            assertClose("\(e.day) cons", g.cons, e.cons, file: file, line: line)
            assertClose("\(e.day) perf", g.perf, e.perf, file: file, line: line)
            assertClose("\(e.day) baseline_hrv_ln", g.baselineHrvLn, e.baselineHrvLn, file: file, line: line)
            assertClose("\(e.day) z_hrv", g.zHrv, e.zHrv, file: file, line: line)
            assertClose("\(e.day) z_rhr", g.zRhr, e.zRhr, file: file, line: line)
            assertClose("\(e.day) z_rr", g.zRr, e.zRr, file: file, line: line)
            assertClose("\(e.day) z_temp", g.zTemp, e.zTemp, file: file, line: line)
            assertClose("\(e.day) z_spo2", g.zSpo2, e.zSpo2, file: file, line: line)
            assertClose("\(e.day) recovery", g.recovery, e.recovery, file: file, line: line)
        }
    }

    private func assertClose(_ name: String, _ got: Double?, _ exp: Double?,
                             file: StaticString, line: UInt) {
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

    private func loadGolden(_ name: String) throws -> GoldenFile {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "missing \(name).json in test resources"
        )
        return try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
    }
}

struct GoldenFile: Decodable {
    var name: String
    var paramsSchemaVersion: Int
    var days: [Day]
    var outputs: [Out]
    var switchIndex: Int?

    enum CodingKeys: String, CodingKey {
        case name, days, outputs
        case paramsSchemaVersion = "params_schema_version"
        case switchIndex = "switch_index"
    }

    struct Nap: Decodable {
        var onsetMin: Int
        var wakeMin: Int
        enum CodingKeys: String, CodingKey {
            case onsetMin = "onset_min"
            case wakeMin = "wake_min"
        }
    }

    struct Day: Decodable {
        var day: String
        var energyKcal: Double?
        var edwards: Double?
        var z45Min: Double?
        var asleep: Double?
        var inbed: Double?
        var napMin: Double?
        var onsetMin: Int?
        var wakeMin: Int?
        var naps: [Nap]
        var hrvMs: Double?
        var rhr: Double?
        var resp: Double?
        var temp: Double?
        var spo2: Double?
        var source: String?

        enum CodingKeys: String, CodingKey {
            case day, edwards, asleep, inbed, naps, rhr, resp, temp, spo2, source
            case energyKcal = "energy_kcal"
            case z45Min = "z45_min"
            case napMin = "nap_min"
            case onsetMin = "onset_min"
            case wakeMin = "wake_min"
            case hrvMs = "hrv_ms"
        }

        var asInput: BandScores.DayInput {
            BandScores.DayInput(
                day: day, energyKcal: energyKcal, edwards: edwards, z45Min: z45Min,
                asleep: asleep, inbed: inbed, napMin: napMin, onsetMin: onsetMin, wakeMin: wakeMin,
                naps: naps.map { BandScores.NapSpan(onsetMin: $0.onsetMin, wakeMin: $0.wakeMin) },
                hrvMs: hrvMs, rhr: rhr, resp: resp, temp: temp, spo2: spo2,
                source: BandScores.DaySource(rawValue: source ?? "imported") ?? .imported
            )
        }
    }

    struct Out: Decodable {
        var day: String
        var strainHat: Double?
        var loadForNeed: Double?
        var napForNeed: Double?
        var debt: Double?
        var need: Double?
        var sriRaw: Double?
        var cons: Double?
        var perf: Double?
        var baselineHrvLn: Double?
        var zHrv: Double?
        var zRhr: Double?
        var zRr: Double?
        var zTemp: Double?
        var zSpo2: Double?
        var recovery: Double?

        enum CodingKeys: String, CodingKey {
            case day, debt, need, cons, perf, recovery
            case strainHat = "strain_hat"
            case loadForNeed = "load_for_need"
            case napForNeed = "nap_for_need"
            case sriRaw = "sri_raw"
            case baselineHrvLn = "baseline_hrv_ln"
            case zHrv = "z_hrv"
            case zRhr = "z_rhr"
            case zRr = "z_rr"
            case zTemp = "z_temp"
            case zSpo2 = "z_spo2"
        }
    }
}

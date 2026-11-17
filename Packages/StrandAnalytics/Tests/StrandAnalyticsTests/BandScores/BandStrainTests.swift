import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class BandStrainTests: XCTestCase {

    private var params: BandStrain.Params!
    private let hrmax = 190.0
    private let rhr = 60.0

    override func setUpWithError() throws {
        params = try BandScores.Params.bundled().strain
    }

    func testBundledStrainParamsMatchWhoopfit7() throws {
        XCTAssertEqual(params.schemaVersion, BandStrain.expectedSchemaVersion)
        XCTAssertEqual(params.maxStrain, 21, accuracy: 0)
        XCTAssertEqual(params.k, 0.08011972378384052, accuracy: 0)
        XCTAssertEqual(params.p, 0.4396708723454066, accuracy: 0)
        XCTAssertEqual(params.wSed, 0.09704433288568518, accuracy: 0)
        XCTAssertEqual(params.qSed, 1.5728628122368362, accuracy: 0)
        XCTAssertEqual(params.defaultRhr, 60, accuracy: 0)
        XCTAssertEqual(params.wZones.count, 6)
        XCTAssertEqual(params.wZones[0], 0.38171990940526646, accuracy: 0)
        XCTAssertEqual(params.wZones[5], 5.221773376556997, accuracy: 0)
    }

    func testGoldenSyntheticMatchesTo1e6() throws {
        let golden = try loadGolden()
        XCTAssertEqual(golden.profile.rhr, rhr, accuracy: 0)
        XCTAssertEqual(golden.profile.hrmax, hrmax, accuracy: 0)

        let cases: [(String, [HRSample], Double, Double)] = [
            ("T1_16h_60bpm", constHR(60, seconds: 16 * 3600),
             golden.tests.t1.portStrain, golden.tests.t1.portL),
            ("T2_16h_75bpm", constHR(75, seconds: 16 * 3600),
             golden.tests.t2.portStrain, golden.tests.t2.portL),
            ("T3_16h_75_plus_45min_run", t3(),
             golden.tests.t3.portStrain, golden.tests.t3.portL),
            ("T4_2h_hard", t4(),
             golden.tests.t4.portStrain, golden.tests.t4.portL),
            ("T5_16h_90bpm", constHR(90, seconds: 16 * 3600),
             golden.tests.t5.portStrain, golden.tests.t5.portL),
            ("T6_8h_sleep60_16h_wake75", t6(),
             golden.tests.t6.portStrain, golden.tests.t6.portL),
        ]
        for (id, samples, wantS, wantL) in cases {
            let L = BandStrain.load(
                times: samples.map { Double($0.ts) },
                hr: samples.map { Double($0.bpm) },
                maxHR: hrmax, restingHR: rhr, params: params
            )
            let s = try XCTUnwrap(BandStrain.strain(samples, maxHR: hrmax, restingHR: rhr, params: params))
            XCTAssertEqual(L, wantL, accuracy: 1e-6, "\(id) L")
            XCTAssertEqual(s, wantS, accuracy: 1e-6, "\(id) strain")
        }
    }

    func testWeightKnotsMatchGoldenTo1e6() throws {
        let golden = try loadGolden()
        for knot in golden.wKnots {
            let w = BandStrain.weight(hr: Double(knot.bpm), maxHR: hrmax, restingHR: rhr, params: params)
            XCTAssertEqual(w, knot.wPerMin, accuracy: 1e-6, "w(\(knot.bpm))")
        }
    }

    func testGapCapDoesNotFillAHole() throws {
        let golden = try loadGolden()
        let continuous = constHR(162, seconds: 10 * 60)
        let hole = twoBlocksWithHole(bpm: 162, blockS: 5 * 60, holeS: 10 * 60)
        let sCont = try XCTUnwrap(BandStrain.strain(continuous, maxHR: hrmax, restingHR: rhr, params: params))
        let sHole = try XCTUnwrap(BandStrain.strain(hole, maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertEqual(sCont, golden.gapIllustration.continuous.portStrain, accuracy: 1e-6)
        XCTAssertEqual(sHole, golden.gapIllustration.withHole.portStrain, accuracy: 1e-6)
        let dtHole = BandStrain.durationsSeconds(hole.map { Double($0.ts) })
        XCTAssertEqual(dtHole.max() ?? 0, 60, accuracy: 1e-9, "hole credited at most 60 s")
    }

    func testHrAtOrBelowRestingIsZero() {
        XCTAssertEqual(BandStrain.weight(hr: 60, maxHR: hrmax, restingHR: rhr, params: params), 0, accuracy: 1e-15)
        XCTAssertEqual(BandStrain.weight(hr: 50, maxHR: hrmax, restingHR: rhr, params: params), 0, accuracy: 1e-15)
        let s = BandStrain.strain(constHR(60, seconds: 3600), maxHR: hrmax, restingHR: rhr, params: params)
        XCTAssertEqual(s ?? -1, 0, accuracy: 1e-15)
    }

    func testWeightIsMonotoneInHr() {
        var prev = -1.0
        for bpm in stride(from: 50, through: 200, by: 1) {
            let w = BandStrain.weight(hr: Double(bpm), maxHR: hrmax, restingHR: rhr, params: params)
            XCTAssertGreaterThanOrEqual(w, prev - 1e-12, "w(\(bpm))")
            prev = w
        }
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(BandStrain.strain([], maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertNil(BandStrain.strain(times: [], hr: [], maxHR: hrmax, restingHR: rhr, params: params))
        XCTAssertNil(BandStrain.strain(constHR(75, seconds: 60), maxHR: 0, restingHR: rhr, params: params))
    }

    func testBucketedStaysWithinFiveHundredthsOnGoldens() throws {
        let goldens: [(String, [HRSample])] = [
            ("T1", constHR(60, seconds: 16 * 3600)),
            ("T2", constHR(75, seconds: 16 * 3600)),
            ("T3", t3()),
            ("T4", t4()),
            ("T5", constHR(90, seconds: 16 * 3600)),
            ("T6", t6()),
        ]
        for (id, samples) in goldens {
            let per = try XCTUnwrap(BandStrain.strain(samples, maxHR: hrmax, restingHR: rhr, params: params))
            let buckets = downsample(samples, bucketSeconds: 300)
            let buck = try XCTUnwrap(BandStrain.strain(times: buckets.map(\.0), hr: buckets.map(\.1),
                                                       maxHR: hrmax, restingHR: rhr, params: params))
            XCTAssertEqual(buck, per, accuracy: 0.05, "\(id) bucketed vs per-sample")
        }
    }

    // MARK: - series

    private func constHR(_ bpm: Int, seconds: Int, t0: Int = 0) -> [HRSample] {
        (0..<seconds).map { HRSample(ts: t0 + $0, bpm: bpm) }
    }

    private func t3() -> [HRSample] {
        var out = constHR(75, seconds: 16 * 3600)
        let t0 = 16 * 3600
        out += constHR(105, seconds: 10 * 60, t0: t0)
        out += constHR(124, seconds: 20 * 60, t0: t0 + 10 * 60)
        out += constHR(143, seconds: 15 * 60, t0: t0 + 30 * 60)
        return out
    }

    private func t4() -> [HRSample] {
        var out = constHR(143, seconds: 30 * 60)
        out += constHR(162, seconds: 60 * 60, t0: 30 * 60)
        out += constHR(181, seconds: 30 * 60, t0: 90 * 60)
        return out
    }

    private func t6() -> [HRSample] {
        var out = constHR(60, seconds: 8 * 3600)
        out += constHR(75, seconds: 16 * 3600, t0: 8 * 3600)
        return out
    }

    private func twoBlocksWithHole(bpm: Int, blockS: Int, holeS: Int) -> [HRSample] {
        var out = constHR(bpm, seconds: blockS)
        out += constHR(bpm, seconds: blockS, t0: blockS + holeS)
        return out
    }

    private func downsample(_ samples: [HRSample], bucketSeconds: Int) -> [(Double, Double)] {
        guard !samples.isEmpty, bucketSeconds > 0 else { return [] }
        let t0 = samples[0].ts
        var sums: [Int: (sum: Double, n: Int, ts: Int)] = [:]
        for s in samples {
            let b = ((s.ts - t0) / bucketSeconds) * bucketSeconds + t0
            let cur = sums[b] ?? (0, 0, b)
            sums[b] = (cur.sum + Double(s.bpm), cur.n + 1, b)
        }
        return sums.keys.sorted().compactMap { key in
            guard let cur = sums[key], cur.n > 0 else { return nil }
            return (Double(cur.ts), cur.sum / Double(cur.n))
        }
    }

    private func loadGolden() throws -> Golden {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent("golden_band_strain.json")
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }
}

private struct Golden: Decodable {
    var profile: Profile
    var wKnots: [Knot]
    var tests: Tests
    var gapIllustration: Gap
    enum CodingKeys: String, CodingKey {
        case profile, tests
        case wKnots = "w_knots"
        case gapIllustration = "gap_illustration"
    }
    struct Profile: Decodable { var rhr: Double; var hrmax: Double }
    struct Knot: Decodable {
        var bpm: Int
        var wPerMin: Double
        enum CodingKeys: String, CodingKey {
            case bpm
            case wPerMin = "w_per_min"
        }
    }
    struct Vec: Decodable {
        var portStrain: Double
        var portL: Double
        enum CodingKeys: String, CodingKey {
            case portStrain = "port_strain"
            case portL = "port_L"
        }
    }
    struct Tests: Decodable {
        var t1: Vec
        var t2: Vec
        var t3: Vec
        var t4: Vec
        var t5: Vec
        var t6: Vec
        enum CodingKeys: String, CodingKey {
            case t1 = "T1_16h_60bpm"
            case t2 = "T2_16h_75bpm"
            case t3 = "T3_16h_75_plus_45min_run"
            case t4 = "T4_2h_hard"
            case t5 = "T5_16h_90bpm"
            case t6 = "T6_8h_sleep60_16h_wake75"
        }
    }
    struct Gap: Decodable {
        var withHole: Vec
        var continuous: Vec
        enum CodingKeys: String, CodingKey {
            case withHole = "with_10min_hole"
            case continuous = "continuous_10min"
        }
    }
}

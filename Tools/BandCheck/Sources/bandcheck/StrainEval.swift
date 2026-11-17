import Foundation
import StrandAnalytics

/// Held-out comparison of three workout-strain curves against WHOOP activity strain.
///
/// A — WHOOP patent shape (WO2015134654A1), thresholds + arctan (N, p) fitted on the
///     earlier 70 % of workouts.
/// B — DX23876/noop AI-32 curve (ryanbr/noop#2438), published constants, no fit.
/// C — production `BandStrain` over WHOOP zone minutes (no fit).
///
/// Production BandStrain is left unchanged: on this wearer's export, A does not beat C
/// on held-out MAE with a bootstrap CI excluding 0, and B is worse. 1 Hz strap HR does
/// not overlap the export, so day strain cannot be shown to improve.
enum StrainEval {
    static let trainFraction = 0.70
    static let tolerance = 1.5
    static let hrrMidpoints = [55.0, 65.0, 75.0, 85.0, 95.0]
    static let maxHRMidpoints = [0.55, 0.65, 0.75, 0.85, 0.95]
    static let belowMinShare = 0.15

    /// WHOOP switched display zones from %HRmax to %HRR in 2024-11 (#2438).
    static let whoopHRRSince: Date = {
        var c = DateComponents()
        c.year = 2024; c.month = 11; c.day = 1
        c.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    struct PatentParams: Equatable {
        var t1: Double
        var t2: Double
        var n: Double
        var p: Double
    }

    struct Prepared {
        var day: String
        var startTs: Int
        var whoop: Double
        var minutes6: [Double]
        var belowShare: Double
        var xb: Double
        var mids: [Double]
        var durationMin: Double
    }

    static func heldOutAgreements(workouts: [WhoopWorkout],
                                  rhrByDay: [String: Double],
                                  hrMax: Double) -> [SeriesAgreement] {
        guard let params = BandStrain.bundledParams() else { return [] }
        return heldOutAgreements(workouts: workouts, rhrByDay: rhrByDay, hrMax: hrMax, strainParams: params)
    }

    static func heldOutAgreements(workouts: [WhoopWorkout],
                                  rhrByDay: [String: Double],
                                  hrMax: Double,
                                  strainParams: BandStrain.Params) -> [SeriesAgreement] {
        let prepared = workouts.compactMap { prepare($0, rhr: rhrByDay[$0.day], hrMax: hrMax) }
            .sorted { $0.startTs < $1.startTs }
        let (train, test) = splitTrainTest(prepared)
        guard !test.isEmpty else {
            return [
                agree("eval.strain_a_heldout", [], tolerance: tolerance),
                agree("eval.strain_b_heldout", [], tolerance: tolerance),
                agree("eval.strain_c_heldout", [], tolerance: tolerance),
            ]
        }
        let patent = train.count >= 8 ? fitPatent(train) : PatentParams(t1: 0.5, t2: 0.8, n: 40, p: 0)
        var aPairs: [Pair] = []
        var bPairs: [Pair] = []
        var cPairs: [Pair] = []
        for (i, w) in test.enumerated() {
            let tag = w.day + "#h\(i)"
            aPairs.append(Pair(day: tag, band: patentStrain(w, params: patent), whoop: w.whoop))
            bPairs.append(Pair(day: tag, band: ai32Strain(w), whoop: w.whoop))
            cPairs.append(Pair(day: tag, band: BandStrain.strain(zoneMinutes: w.minutes6, params: strainParams),
                               whoop: w.whoop))
        }
        return [
            agree("eval.strain_a_heldout", aPairs, tolerance: tolerance),
            agree("eval.strain_b_heldout", bPairs, tolerance: tolerance),
            agree("eval.strain_c_heldout", cPairs, tolerance: tolerance),
        ]
    }

    static func splitTrainTest<T>(_ items: [T], fraction: Double = trainFraction) -> ([T], [T]) {
        let n = items.count
        if n == 0 { return ([], []) }
        var cut = Int((Double(n) * fraction).rounded(.down))
        if cut <= 0 { cut = 0 }
        if cut >= n { cut = max(0, n - 1) }
        return (Array(items.prefix(cut)), Array(items.suffix(from: cut)))
    }

    // MARK: - B (AI-32)

    /// Per-minute weight at intensity `x` in %HRR.
    /// `w(x) = exp(0.5646·(x−55)/10) / (1 + exp(−(x−20)/3))`
    static func ai32Weight(pctHRR x: Double) -> Double {
        let x = min(max(x, 0), 120)
        let exp = Darwin.exp(0.5646 * (x - 55) / 10)
        let step = 1 / (1 + Darwin.exp(-(x - 20) / 3))
        return exp * step
    }

    /// `b = 5.4591·ln(1 + load/12.2245)`, then `21b / (b^8 + 21^8)^{1/8}`.
    static func ai32Strain(load: Double) -> Double {
        let b = 5.4591 * log1p(max(load, 0) / 12.2245)
        if b <= 0 { return 0 }
        let p = 8.0
        let m = max(b, 21.0)
        let s = 21 * b / (m * pow(pow(b / m, p) + pow(21 / m, p), 1 / p))
        return min(s, 21)
    }

    static func ai32Strain(_ w: Prepared) -> Double {
        ai32Strain(load: ai32Load(w))
    }

    static func ai32Load(_ w: Prepared) -> Double {
        var L = (w.minutes6.first ?? 0) * ai32Weight(pctHRR: w.xb)
        for i in 0..<5 {
            let mins = w.minutes6.count > i + 1 ? w.minutes6[i + 1] : 0
            let x = i < w.mids.count ? w.mids[i] : 0
            L += mins * ai32Weight(pctHRR: x)
        }
        return L
    }

    // MARK: - A (patent)

    /// 0 at rest, 1 up to `t1`, 18 between `t1` and `t2`, 42 above `t2`. `v` is HR-reserve fraction.
    static func patentWeight(v: Double, t1: Double, t2: Double) -> Double {
        if v <= 0 { return 0 }
        if v <= t1 { return 1 }
        if v <= t2 { return 18 }
        return 42
    }

    static func patentStrain(load: Double, params: PatentParams) -> Double {
        let w1 = max(patentWeight(v: 1, t1: params.t1, t2: params.t2), 1e-9)
        let x = load / (w1 * 24 * 60)
        let z = params.n * (x - params.p)
        return 0.5 * (atan(z) / (.pi / 2) + 1) * 21
    }

    static func patentStrain(_ w: Prepared, params: PatentParams) -> Double {
        patentStrain(load: patentLoad(w, t1: params.t1, t2: params.t2), params: params)
    }

    static func patentLoad(_ w: Prepared, t1: Double, t2: Double) -> Double {
        var L = (w.minutes6.first ?? 0) * patentWeight(v: w.xb / 100, t1: t1, t2: t2)
        for i in 0..<5 {
            let mins = w.minutes6.count > i + 1 ? w.minutes6[i + 1] : 0
            let v = (i < w.mids.count ? w.mids[i] : 0) / 100
            L += mins * patentWeight(v: v, t1: t1, t2: t2)
        }
        return L
    }

    static func fitPatent(_ train: [Prepared]) -> PatentParams {
        let y = train.map(\.whoop)
        var bestMAE = Double.infinity
        var best = PatentParams(t1: 0.5, t2: 0.8, n: 40, p: 0)
        let t1s: [Double] = [0.30, 0.40, 0.50, 0.55, 0.60, 0.65, 0.70]
        let t2s: [Double] = [0.70, 0.75, 0.80, 0.85, 0.90, 0.95]
        let ns: [Double] = [5, 10, 20, 40, 80, 160, 320]
        let ps: [Double] = [-0.02, 0, 0.01, 0.02, 0.04, 0.08]
        for t1 in t1s {
            for t2 in t2s where t2 > t1 + 0.04 {
                let xs = train.map { patentLoad($0, t1: t1, t2: t2) / max(patentWeight(v: 1, t1: t1, t2: t2), 1e-9) / (24 * 60) }
                for n in ns {
                    for p in ps {
                        var err = 0.0
                        for i in 0..<y.count {
                            let z = n * (xs[i] - p)
                            let pred = 0.5 * (atan(z) / (.pi / 2) + 1) * 21
                            err += abs(pred - y[i])
                        }
                        err /= Double(y.count)
                        if err < bestMAE {
                            bestMAE = err
                            best = PatentParams(t1: t1, t2: t2, n: n, p: p)
                        }
                    }
                }
            }
        }
        let t1 = best.t1, t2 = best.t2
        let xs = train.map { patentLoad($0, t1: t1, t2: t2) / max(patentWeight(v: 1, t1: t1, t2: t2), 1e-9) / (24 * 60) }
        for nMul in [0.5, 0.7, 0.85, 1.0, 1.15, 1.4, 2.0, 3.0] {
            let n = best.n * nMul
            for dp in [-0.03, -0.015, -0.008, 0.0, 0.008, 0.015, 0.03] {
                let p = best.p + dp
                var err = 0.0
                for i in 0..<y.count {
                    let z = n * (xs[i] - p)
                    err += abs(0.5 * (atan(z) / (.pi / 2) + 1) * 21 - y[i])
                }
                err /= Double(y.count)
                if err < bestMAE {
                    bestMAE = err
                    best = PatentParams(t1: t1, t2: t2, n: n, p: p)
                }
            }
        }
        return best
    }

    // MARK: - prepare

    static func prepare(_ w: WhoopWorkout, rhr: Double?, hrMax: Double) -> Prepared? {
        guard let whoop = w.strain, w.durationMin > 0 else { return nil }
        let minutes6 = zoneMinutes6(w)
        let covered = [w.z1, w.z2, w.z3, w.z4, w.z5].reduce(0, +) / 100
        let below = max(0, 1 - covered)
        let rest = rhr ?? BandStrain.defaultRestingHR
        let mids = zoneMidpoints(start: w.start, rhr: rest, hrMax: hrMax)
        let xb = belowIntensity(below: below, shares: [w.z1, w.z2, w.z3, w.z4, w.z5].map { $0 / 100 },
                                mids: mids, avg: w.avgHR, rhr: rest, hrMax: hrMax) ?? 30
        return Prepared(day: w.day, startTs: w.startTs, whoop: whoop, minutes6: minutes6,
                        belowShare: below, xb: xb, mids: mids, durationMin: w.durationMin)
    }

    static func zoneMidpoints(start: Date, rhr: Double, hrMax: Double) -> [Double] {
        if start >= whoopHRRSince { return hrrMidpoints }
        guard hrMax > rhr else { return hrrMidpoints }
        return maxHRMidpoints.map { max(0, ($0 * hrMax - rhr) / (hrMax - rhr) * 100) }
    }

    /// Intensity (%HRR) of time below zone 1, recovered from average HR (DX23876 calibration).
    static func belowIntensity(below: Double, shares: [Double], mids: [Double],
                               avg: Double?, rhr: Double, hrMax: Double) -> Double? {
        let edge = (mids.first ?? 55) - 5
        if below < belowMinShare { return edge - 10 }
        guard let avg, hrMax > rhr else { return nil }
        let bpm = mids.map { rhr + $0 / 100 * (hrMax - rhr) }
        let inside = zip(shares, bpm).reduce(0.0) { $0 + $1.0 * $1.1 }
        let belowBpm = (avg - inside) / below
        return max(0, min(edge, (belowBpm - rhr) / (hrMax - rhr) * 100))
    }
}

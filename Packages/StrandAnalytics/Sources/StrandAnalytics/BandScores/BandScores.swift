import Foundation

/// Fitted Band score models (load, sleep ledger, SRI, sleep performance, recovery).
/// Pure Double (IEEE-754 binary64) arithmetic. No app or database imports.
public enum BandScores {

    /// Clip that preserves NaN. Spec: `min(hi, max(lo, x))`.
    public static func clip(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        guard x.isFinite else { return x }
        return min(hi, max(lo, x))
    }

    public static func ewmaAlpha(halfLifeDays: Double) -> Double {
        let hl = max(halfLifeDays, 0.25)
        return 1.0 - pow(0.5, 1.0 / hl)
    }

    public static func nan(_ value: Double?) -> Double {
        value ?? .nan
    }

    public static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }

    public static func median(_ values: [Double]) -> Double {
        let xs = values.sorted()
        let n = xs.count
        guard n > 0 else { return .nan }
        let mid = n / 2
        if n % 2 == 1 { return xs[mid] }
        return 0.5 * (xs[mid - 1] + xs[mid])
    }

    public static func populationStd(_ values: [Double]) -> Double {
        let n = values.count
        guard n > 0 else { return .nan }
        let mu = values.reduce(0, +) / Double(n)
        var ss = 0.0
        for v in values { let d = v - mu; ss += d * d }
        return sqrt(ss / Double(n))
    }

    public static func sampleStd(_ values: [Double]) -> Double {
        let n = values.count
        guard n > 0 else { return .nan }
        if n <= 2 { return populationStd(values) }
        let mu = values.reduce(0, +) / Double(n)
        var ss = 0.0
        for v in values { let d = v - mu; ss += d * d }
        return sqrt(ss / Double(n - 1))
    }

    /// Where tonight's overnight physiology came from. Defaults to `.imported` so existing
    /// fixtures (every day one source) keep the EWMA path byte-identical.
    public enum DaySource: String, Sendable, Equatable {
        case imported
        case strap
    }

    /// One night of portable inputs. Clock minutes are local 0…1439.
    public struct DayInput: Sendable, Equatable {
        public var day: String
        public var energyKcal: Double?
        public var edwards: Double?
        public var z45Min: Double?
        public var asleep: Double?
        public var inbed: Double?
        public var napMin: Double?
        public var onsetMin: Int?
        public var wakeMin: Int?
        public var naps: [NapSpan]
        public var hrvMs: Double?
        public var rhr: Double?
        public var resp: Double?
        public var temp: Double?
        public var spo2: Double?
        public var source: DaySource

        public init(day: String, energyKcal: Double? = nil, edwards: Double? = nil,
                    z45Min: Double? = nil, asleep: Double? = nil, inbed: Double? = nil,
                    napMin: Double? = nil, onsetMin: Int? = nil, wakeMin: Int? = nil,
                    naps: [NapSpan] = [], hrvMs: Double? = nil, rhr: Double? = nil,
                    resp: Double? = nil, temp: Double? = nil, spo2: Double? = nil,
                    source: DaySource = .imported) {
            self.day = day; self.energyKcal = energyKcal; self.edwards = edwards
            self.z45Min = z45Min; self.asleep = asleep; self.inbed = inbed
            self.napMin = napMin; self.onsetMin = onsetMin; self.wakeMin = wakeMin
            self.naps = naps; self.hrvMs = hrvMs; self.rhr = rhr
            self.resp = resp; self.temp = temp; self.spo2 = spo2
            self.source = source
        }
    }

    public struct NapSpan: Sendable, Equatable {
        public var onsetMin: Int
        public var wakeMin: Int
        public init(onsetMin: Int, wakeMin: Int) {
            self.onsetMin = onsetMin; self.wakeMin = wakeMin
        }
    }

    public struct DayOutput: Sendable, Equatable {
        public var day: String
        public var strainHat: Double?
        public var loadForNeed: Double?
        public var napForNeed: Double?
        public var debt: Double?
        public var need: Double?
        public var sriRaw: Double?
        public var cons: Double?
        public var perf: Double?
        public var baselineHrvLn: Double?
        public var zHrv: Double?
        public var zRhr: Double?
        public var zRr: Double?
        public var zTemp: Double?
        public var zSpo2: Double?
        public var recovery: Double?
        /// Round-5 ms-EWMA logistic. Nil during the current source's warm-up.
        public var recoveryV3: Double?
    }

    /// Causal pipeline: load → ledger → SRI → sleep performance → baselines → recovery.
    public static func evaluate(days: [DayInput], params: Params) -> [DayOutput] {
        let n = days.count
        guard n > 0 else { return [] }

        var strainHat = [Double](repeating: .nan, count: n)
        for t in 0..<n {
            strainHat[t] = BandLoadIndex.strainHat(
                energyKcal: nan(days[t].energyKcal),
                edwards: nan(days[t].edwards),
                z45Min: nan(days[t].z45Min),
                params: params.loadIndex
            )
        }
        var loadForNeed = [Double](repeating: .nan, count: n)
        var napForNeed = [Double](repeating: .nan, count: n)
        if n > 1 {
            for t in 1..<n {
                loadForNeed[t] = strainHat[t - 1]
                napForNeed[t] = days[t - 1].napMin ?? 0
            }
        }

        let asleep = days.map { nan($0.asleep) }
        let inbed = days.map { nan($0.inbed) }
        let ledger = BandSleepLedger.run(
            asleep: asleep, loadForNeed: loadForNeed, napForNeed: napForNeed, params: params.sleepLedger
        )

        let masks = days.map { day -> [Int8] in
            BandConsistency.mask(
                onsetMin: day.onsetMin, wakeMin: day.wakeMin,
                naps: day.naps.map { ($0.onsetMin, $0.wakeMin) }
            )
        }
        let cons = BandConsistency.run(masks: masks, params: params.consistency)
        let perf = BandSleepPerformance.run(
            asleep: asleep, need: ledger.need, cons: cons.mapped, inbed: inbed, params: params.sleepPerformance
        )

        let hrvLn = days.map { d -> Double in
            guard let h = d.hrvMs, h.isFinite else { return .nan }
            return log(max(h, 1.0))
        }
        let rhr = days.map { nan($0.rhr) }
        let resp = days.map { nan($0.resp) }
        let temp = days.map { nan($0.temp) }
        let spo2 = days.map { nan($0.spo2) }

        // RHR / resp / temp / SpO2 stay on the existing EWMA/median path (switch_over.md:
        // only HRV jumps source). HRV uses EWMA until the first source change, then the
        // local-level Kalman with one-shot P inflation. No source change → bit-identical EWMA.
        let hrvB = BandBaselines.run(
            x: hrvLn, config: params.baselines.hrvLn, minP: params.baselinesMinP,
            sources: days.map(\.source), kalman: params.hrvKalman,
            mode: params.hrvBaselineMode
        )
        let rhrB = BandBaselines.run(x: rhr, config: params.baselines.rhr, minP: params.baselinesMinP)
        let rrB = BandBaselines.run(x: resp, config: params.baselines.resp, minP: params.baselinesMinP)
        let tempB = BandBaselines.run(x: temp, config: params.baselines.temp, minP: params.baselinesMinP)
        let spo2B = BandBaselines.run(x: spo2, config: params.baselines.spo2, minP: params.baselinesMinP)

        let recovery = BandRecovery.run(
            zHrv: hrvB.z, zRhr: rhrB.z, zRr: rrB.z, zTemp: tempB.z, zSpo2: spo2B.z,
            perf: perf, params: params.recovery
        )
        let hrvMs = days.map { nan($0.hrvMs) }
        let recoveryV3 = BandRecoveryV3.run(
            hrv: hrvMs, sleepPct: perf, sources: days.map(\.source), params: params.recoveryV3
        )

        return (0..<n).map { t in
            DayOutput(
                day: days[t].day,
                strainHat: finite(strainHat[t]),
                loadForNeed: finite(loadForNeed[t]),
                napForNeed: finite(napForNeed[t]),
                debt: finite(ledger.debt[t]),
                need: finite(ledger.need[t]),
                sriRaw: finite(cons.sri[t]),
                cons: finite(cons.mapped[t]),
                perf: finite(perf[t]),
                baselineHrvLn: finite(hrvB.baseline[t]),
                zHrv: finite(hrvB.z[t]),
                zRhr: finite(rhrB.z[t]),
                zRr: finite(rrB.z[t]),
                zTemp: finite(tempB.z[t]),
                zSpo2: finite(spo2B.z[t]),
                recovery: finite(recovery[t]),
                recoveryV3: finite(recoveryV3.recovery[t])
            )
        }
    }
}

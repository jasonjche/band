import Foundation

/// Recursive sleep-debt ledger. Tonight's need uses previous-cycle load and naps.
public enum BandSleepLedger {

    public struct Params: Sendable {
        public var variant: String
        public var base: Double
        public var a: Double
        public var b: Double
        public var decay: Double
        public var gain: Double
        public var credit: Double
        public var knap: Double
        public var bias: Double
        public var cap: Double
        public var initDebt: Double
        public var needLo: Double
        public var needHi: Double
    }

    public struct Series: Sendable {
        public var need: [Double]
        public var debt: [Double]
    }

    /// `loadForNeed[t]` and `napForNeed[t]` are already lagged (previous cycle).
    public static func run(asleep: [Double], loadForNeed: [Double], napForNeed: [Double],
                           params: Params) -> Series {
        let n = asleep.count
        var debt = [Double](repeating: .nan, count: n)
        var need = [Double](repeating: .nan, count: n)
        var d = params.initDebt
        for t in 0..<n {
            if t > 0 {
                let prevAsleep = asleep[t - 1]
                let prevLoad = loadForNeed[t - 1]
                let prevNap = napForNeed[t - 1].isFinite ? napForNeed[t - 1] : 0
                if !prevAsleep.isFinite {
                    d = params.decay * d
                } else {
                    let ref: Double
                    if params.variant == "vs_need" {
                        if need[t - 1].isFinite {
                            ref = need[t - 1]
                        } else {
                            let pl = prevLoad.isFinite ? prevLoad : 0
                            ref = params.base + params.a * pl - params.knap * prevNap
                        }
                    } else {
                        let pl = prevLoad.isFinite ? prevLoad : 0
                        ref = params.base + params.a * pl - params.knap * prevNap
                    }
                    let short = max(0.0, ref - prevAsleep)
                    let extra = max(0.0, prevAsleep - ref)
                    d = params.decay * d + params.gain * short - params.credit * extra + params.bias
                }
                d = BandScores.clip(d, 0.0, params.cap)
            }
            debt[t] = d
            let lt = loadForNeed[t]
            let nt = napForNeed[t].isFinite ? napForNeed[t] : 0
            let needRaw = params.base + params.a * (lt.isFinite ? lt : 0) + params.b * d - params.knap * nt
            need[t] = BandScores.clip(needRaw, params.needLo, params.needHi)
        }
        return Series(need: need, debt: debt)
    }
}

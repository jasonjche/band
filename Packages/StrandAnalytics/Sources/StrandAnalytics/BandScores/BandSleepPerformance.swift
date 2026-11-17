import Foundation

/// Sleep performance from hours-vs-our-need, our consistency, and efficiency.
public enum BandSleepPerformance {

    public struct Params: Sendable {
        public var intercept: Double
        public var wHvn: Double
        public var wCons: Double
        public var wEff: Double
        public var hvnPower: Double
        public var hvnCap: Double
    }

    public static func run(asleep: [Double], need: [Double], cons: [Double], inbed: [Double],
                           params: Params) -> [Double] {
        let n = asleep.count
        var out = [Double](repeating: .nan, count: n)
        for t in 0..<n {
            let a = asleep[t], nd = need[t], c = cons[t], ib = inbed[t]
            guard a.isFinite, nd.isFinite, c.isFinite, ib.isFinite, ib > 0 else { continue }
            let hvn = 100.0 * a / max(nd, 200.0)
            let hvnC = BandScores.clip(hvn, 0.0, params.hvnCap)
            let hvnN = 100.0 * pow(max(hvnC / 100.0, 0.0), params.hvnPower)
            let eff = 100.0 * a / ib
            let pred = params.intercept + params.wHvn * hvnN + params.wCons * c + params.wEff * eff
            out[t] = BandScores.clip(pred, 0.0, 100.0)
        }
        return out
    }
}

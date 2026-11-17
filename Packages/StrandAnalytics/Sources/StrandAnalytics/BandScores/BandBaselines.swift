import Foundation

/// Causal (prior-only) EWMA / median / mean baselines with the outlier hold-out rule.
public enum BandBaselines {

    public enum Method: String, Sendable {
        case ewma
        case median
        case mean
    }

    public struct Config: Sendable {
        public var method: Method
        public var halfLife: Double
        public var window: Double
        public var outlierK: Double
        public var zScale: Double
        public var floor: Double
    }

    public struct Bundle: Sendable {
        public var hrvLn: Config
        public var rhr: Config
        public var resp: Config
        public var temp: Config
        public var spo2: Config
    }

    public struct Series: Sendable {
        public var baseline: [Double]
        public var scale: [Double]
        /// `(x_t - baseline_t) / z_scale`, clipped to ±6. Uses the fitted train MAD scale.
        public var z: [Double]
    }

    public static func run(x: [Double], config: Config, minP: Int = 8) -> Series {
        let n = x.count
        var baseline = [Double](repeating: .nan, count: n)
        var scale = [Double](repeating: .nan, count: n)
        let alpha = BandScores.ewmaAlpha(halfLifeDays: config.halfLife)
        var buf: [Double] = []
        var ewma = Double.nan
        var evar = Double.nan
        let win = Int(config.window)

        for t in 0..<n {
            if !buf.isEmpty {
                let b: Double
                var sc: Double
                switch config.method {
                case .ewma:
                    b = ewma
                    sc = (evar.isFinite && evar > 0) ? sqrt(evar) : BandScores.populationStd(buf)
                case .median:
                    let w = win > 0 ? Array(buf.suffix(win)) : buf
                    b = BandScores.median(w)
                    let mad = BandScores.median(w.map { abs($0 - b) })
                    sc = 1.4826 * mad
                case .mean:
                    let w = win > 0 ? Array(buf.suffix(win)) : buf
                    b = w.reduce(0, +) / Double(w.count)
                    sc = BandScores.sampleStd(w)
                }
                if !sc.isFinite || sc < 1e-8 { sc = 1e-8 }
                baseline[t] = b
                scale[t] = sc
            }

            let xt = x[t]
            guard xt.isFinite else { continue }
            var update = true
            if buf.count >= minP,
               config.outlierK.isFinite,
               baseline[t].isFinite,
               scale[t].isFinite,
               scale[t] > 1e-4 {
                if abs(xt - baseline[t]) > config.outlierK * scale[t] {
                    update = false
                }
            }
            guard update else { continue }
            buf.append(xt)
            if !ewma.isFinite {
                ewma = xt
                evar = 0
            } else {
                let resid = xt - ewma
                ewma = (1 - alpha) * ewma + alpha * xt
                evar = (1 - alpha) * evar + alpha * resid * resid
            }
        }

        var z = [Double](repeating: .nan, count: n)
        for t in 0..<n {
            let xt = x[t]
            let b = baseline[t]
            if xt.isFinite && b.isFinite {
                z[t] = BandScores.clip((xt - b) / config.zScale, -6, 6)
            }
        }
        return Series(baseline: baseline, scale: scale, z: z)
    }
}

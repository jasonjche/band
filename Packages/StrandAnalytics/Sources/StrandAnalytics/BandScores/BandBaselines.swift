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
        /// After an HRV source change, Kalman nights use `innov / sqrt(P+r)` instead.
        public var z: [Double]
    }

    /// Default `.ewma` keeps golden_synthetic / golden_anonymised bit-identical.
    /// `.kalman` is policy (c): local-level KF on ln(HRV) for the whole series.
    public enum HrvMode: String, Sendable {
        case ewma
        case kalman
    }

    /// Frozen local-level Kalman for ln(HRV) at a known source change (`switch_over.md` policy c).
    /// q, r, initP are this wearer's WHOOP-CSV calibration; a later export refits them.
    public struct KalmanParams: Sendable {
        public var q: Double
        public var r: Double
        public var inflate: Double
        public var initP: Double

        public init(q: Double, r: Double, inflate: Double, initP: Double) {
            self.q = q; self.r = r; self.inflate = inflate; self.initP = initP
        }

        /// `/tmp/whoopfit4/params/switch_over.md` and `kalman_metrics.json` `qr_hrv`.
        public static let bundled = KalmanParams(
            q: 0.0009070824729060664,
            r: 0.0464331564703044,
            inflate: 16.0,
            initP: 0.07926913283010574
        )
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

    /// EWMA when every day shares one source and `mode == .ewma`.
    /// Kalman for the whole series when `mode == .kalman`.
    /// On a source change with default `.ewma`, splice Kalman z in from that night
    /// (RHR / resp / temp / SpO2 stay on `run(x:config:)`).
    public static func run(x: [Double], config: Config, minP: Int = 8,
                           sources: [BandScores.DaySource],
                           kalman: KalmanParams,
                           mode: HrvMode = .ewma) -> Series {
        let ewma = run(x: x, config: config, minP: minP)
        let tSwitch = firstSourceChange(sources)
        let useKalmanEntirely = (mode == .kalman)
        guard useKalmanEntirely || tSwitch != nil else { return ewma }
        let kf = kalmanLevel(x: x, sources: sources, params: kalman)
        if useKalmanEntirely { return kf }
        guard let tSwitch, tSwitch < x.count else { return ewma }
        var out = ewma
        for t in tSwitch..<x.count {
            out.baseline[t] = kf.baseline[t]
            out.scale[t] = kf.scale[t]
            out.z[t] = kf.z[t]
        }
        return out
    }

    public static func firstSourceChange(_ sources: [BandScores.DaySource]) -> Int? {
        guard sources.count >= 2 else { return nil }
        for t in 1..<sources.count {
            if sources[t] != sources[t - 1] { return t }
        }
        return nil
    }

    /// Local-level Kalman on `x` (ln HRV). Inflates P on every source change.
    /// Missing y skips the measurement update and still adds process noise so later nights stay finite.
    static func kalmanLevel(x: [Double], sources: [BandScores.DaySource],
                            params: KalmanParams) -> Series {
        let n = x.count
        var baseline = [Double](repeating: Double.nan, count: n)
        var scale = [Double](repeating: Double.nan, count: n)
        var z = [Double](repeating: Double.nan, count: n)
        let q = max(params.q, 1e-12)
        let r = max(params.r, 1e-12)
        var P = max(params.initP, 1e-12)
        var level = Double.nan
        var initialized = false

        for t in 0..<n {
            if t > 0, t < sources.count, sources[t] != sources[t - 1] {
                let old = sources[t - 1]
                var varOld = populationVar(x: x, sources: sources, source: old, until: t)
                if !varOld.isFinite || varOld <= 0 { varOld = params.initP }
                P += params.inflate * varOld
            }

            if !initialized {
                if x[t].isFinite {
                    level = x[t]
                    initialized = true
                    let S = P + r
                    baseline[t] = level
                    scale[t] = sqrt(max(S, 1e-12))
                    z[t] = 0
                    let K = P / S
                    P = (1 - K) * P + q
                } else {
                    P += q
                }
                continue
            }

            let S = P + r
            baseline[t] = level
            scale[t] = sqrt(max(S, 1e-12))
            if x[t].isFinite {
                let innov = x[t] - level
                z[t] = BandScores.clip(innov / sqrt(max(S, 1e-12)), -6, 6)
                let K = P / S
                level += K * innov
                P = (1 - K) * P + q
            } else {
                P += q
            }
        }
        return Series(baseline: baseline, scale: scale, z: z)
    }

    private static func populationVar(x: [Double], sources: [BandScores.DaySource],
                                      source: BandScores.DaySource, until: Int) -> Double {
        var sum = 0.0
        var count = 0
        let hi = min(until, x.count, sources.count)
        for i in 0..<hi {
            if sources[i] == source, x[i].isFinite {
                sum += x[i]
                count += 1
            }
        }
        guard count > 0 else { return .nan }
        let mu = sum / Double(count)
        var ss = 0.0
        for i in 0..<hi {
            if sources[i] == source, x[i].isFinite {
                let d = x[i] - mu
                ss += d * d
            }
        }
        return ss / Double(count)
    }
}

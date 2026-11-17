import Foundation

/// Round-5 recovery head: causal EWMA on raw HRV in milliseconds (not ln), logistic of z and a sleep term.
/// Separately tested from round-2 `BandRecovery`. Port: `/tmp/whoopfit5/params/port_notes.md`.
public enum BandRecoveryV3 {

    public static let expectedSchemaVersion = 5
    public static let madK = 1.4826

    public struct Params: Sendable {
        public var schemaVersion: Int
        public var variant: String
        public var halfLifeDays: Double
        public var zScale: Double
        public var zFloor: Double
        public var warmupNights: Int
        public var b0: Double
        public var wHrv: Double
        public var wSleep: Double
        public var sleepCenter: Double
        public var sleepScale: Double
        public var zClip: Double
        public var etaClip: Double
        public var recLo: Double
        public var recHi: Double

        public init(schemaVersion: Int, variant: String, halfLifeDays: Double, zScale: Double,
                    zFloor: Double, warmupNights: Int, b0: Double, wHrv: Double, wSleep: Double,
                    sleepCenter: Double, sleepScale: Double, zClip: Double, etaClip: Double,
                    recLo: Double, recHi: Double) {
            self.schemaVersion = schemaVersion
            self.variant = variant
            self.halfLifeDays = halfLifeDays
            self.zScale = zScale
            self.zFloor = zFloor
            self.warmupNights = warmupNights
            self.b0 = b0
            self.wHrv = wHrv
            self.wSleep = wSleep
            self.sleepCenter = sleepCenter
            self.sleepScale = sleepScale
            self.zClip = zClip
            self.etaClip = etaClip
            self.recLo = recLo
            self.recHi = recHi
        }
    }

    public struct Series: Sendable {
        public var baseline: [Double]
        public var z: [Double]
        public var zScale: [Double]
        /// NaN while the current source is still warming up.
        public var recovery: [Double]
    }

    public static func alpha(halfLifeDays: Double) -> Double {
        BandScores.ewmaAlpha(halfLifeDays: halfLifeDays)
    }

    public static func madScale(_ values: [Double], floor: Double) -> Double {
        let xs = values.filter { $0.isFinite }
        guard !xs.isEmpty else { return floor }
        let med = BandScores.median(xs)
        let mad = BandScores.median(xs.map { abs($0 - med) })
        return max(madK * mad, floor)
    }

    /// Exact port_notes recursion with a frozen z-scale. `nan_to_0` on z and the sleep term.
    /// Always emits a clipped recovery (golden path, including the first night where z is NaN).
    public static func score(hrv: [Double], sleepPct: [Double], params: Params,
                             zScale: Double? = nil) -> Series {
        let n = hrv.count
        let zsc = max(zScale ?? params.zScale, params.zFloor)
        let a = alpha(halfLifeDays: params.halfLifeDays)
        var baseline = [Double](repeating: .nan, count: n)
        var z = [Double](repeating: .nan, count: n)
        var scales = [Double](repeating: zsc, count: n)
        var recovery = [Double](repeating: .nan, count: n)
        var ewma = Double.nan
        for t in 0..<n {
            let x = t < hrv.count ? hrv[t] : .nan
            let sp = t < sleepPct.count ? sleepPct[t] : .nan
            let base = ewma
            baseline[t] = base
            scales[t] = zsc
            if x.isFinite {
                if !ewma.isFinite {
                    ewma = x
                } else {
                    ewma = (1.0 - a) * ewma + a * x
                }
            }
            if x.isFinite, base.isFinite {
                z[t] = BandScores.clip((x - base) / zsc, -params.zClip, params.zClip)
            }
            recovery[t] = logistic(z: z[t], sleepPct: sp, params: params)
        }
        return Series(baseline: baseline, z: z, zScale: scales, recovery: recovery)
    }

    /// Production path: restart EWMA and the residual MAD at a source change; withhold recovery
    /// until `warmupNights` finite-z observations on the current source. Missing HRV carries
    /// state and does not update.
    public static func run(hrv: [Double], sleepPct: [Double],
                           sources: [BandScores.DaySource],
                           params: Params) -> Series {
        let n = hrv.count
        let a = alpha(halfLifeDays: params.halfLifeDays)
        var baseline = [Double](repeating: .nan, count: n)
        var z = [Double](repeating: .nan, count: n)
        var scales = [Double](repeating: params.zScale, count: n)
        var recovery = [Double](repeating: .nan, count: n)
        var ewma = Double.nan
        var residuals: [Double] = []
        var lastSource: BandScores.DaySource?
        for t in 0..<n {
            let src: BandScores.DaySource = t < sources.count ? sources[t] : (lastSource ?? .imported)
            if let lastSource, src != lastSource {
                ewma = .nan
                residuals = []
            }
            lastSource = src
            let x = hrv[t]
            let sp = t < sleepPct.count ? sleepPct[t] : .nan
            let base = ewma
            baseline[t] = base
            var zsc = params.zScale
            if x.isFinite, base.isFinite {
                residuals.append(x - base)
                if residuals.count >= params.warmupNights {
                    zsc = madScale(residuals, floor: params.zFloor)
                }
                z[t] = BandScores.clip((x - base) / max(zsc, params.zFloor), -params.zClip, params.zClip)
            }
            scales[t] = zsc
            if x.isFinite {
                if !ewma.isFinite {
                    ewma = x
                } else {
                    ewma = (1.0 - a) * ewma + a * x
                }
            }
            if z[t].isFinite, residuals.count >= params.warmupNights {
                recovery[t] = logistic(z: z[t], sleepPct: sp, params: params)
            }
        }
        return Series(baseline: baseline, z: z, zScale: scales, recovery: recovery)
    }

    public static func logistic(z: Double, sleepPct: Double, params: Params) -> Double {
        let zz = z.isFinite ? z : 0.0
        let st: Double
        if sleepPct.isFinite {
            st = (sleepPct - params.sleepCenter) / params.sleepScale
        } else {
            st = 0.0
        }
        var eta = params.b0 + params.wHrv * zz + params.wSleep * st
        eta = BandScores.clip(eta, -params.etaClip, params.etaClip)
        return BandScores.clip(100.0 / (1.0 + exp(-eta)), params.recLo, params.recHi)
    }
}

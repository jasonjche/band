import Foundation
import WhoopProtocol

/// Fitted WHOOP-like day/activity strain on the 0–21 axis (PORT.md / whoopfit7).
///
/// Per-sample load `w` on %HRmax, integrated with a median-gap cap, then
/// `21 · (1 − exp(−k · L^p))`. Sleep at or below resting HR contributes 0.
/// Day strain is `strain(L_day)` over the calendar day's HR, never a sum of
/// activity strains. Activity strain is the same map over the workout window.
///
/// Storage elsewhere keeps Effort 0–100 = strain21 × 100/21; this type returns 0–21.
public enum BandStrain {

    public static let expectedSchemaVersion = 1
    public static let defaultRestingHR = 60.0

    public static func bundledParams() -> Params? { cachedParams }
    private static let cachedParams: Params? = try? BandScores.Params.bundled().strain

    public struct Params: Sendable {
        public var schemaVersion: Int
        public var maxStrain: Double
        public var k: Double
        public var p: Double
        public var zoneLoHrmax: [Double]
        public var wZones: [Double]
        public var wSed: Double
        public var qSed: Double
        public var defaultRhr: Double

        public init(schemaVersion: Int, maxStrain: Double, k: Double, p: Double,
                    zoneLoHrmax: [Double], wZones: [Double], wSed: Double, qSed: Double,
                    defaultRhr: Double) {
            self.schemaVersion = schemaVersion
            self.maxStrain = maxStrain
            self.k = k
            self.p = p
            self.zoneLoHrmax = zoneLoHrmax
            self.wZones = wZones
            self.wSed = wSed
            self.qSed = qSed
            self.defaultRhr = defaultRhr
        }
    }

    /// Empty series → nil. Otherwise 0–21, clipped.
    public static func strain(_ samples: [HRSample], maxHR: Double, restingHR: Double,
                              params: Params) -> Double? {
        guard !samples.isEmpty, maxHR > 1e-6 else { return nil }
        let L = load(samples, maxHR: maxHR, restingHR: restingHR, params: params)
        return strain(load: L, params: params)
    }

    /// Same load as `load(times:hr:)` over `HRSample`s, without two full Double copies of the day.
    public static func load(_ samples: [HRSample], maxHR: Double, restingHR: Double,
                            params: Params) -> Double {
        let n = samples.count
        guard n > 0, maxHR > 1e-6 else { return 0 }
        let dt = durationsSeconds(samples)
        let xRest = restingHR / maxHR
        var L = 0.0
        for i in 0..<n {
            L += weight(hr: Double(samples[i].bpm), maxHR: maxHR, xRest: xRest, params: params) * (dt[i] / 60.0)
        }
        return L
    }

    /// `dt_i` from integer timestamps, same rule as `durationsSeconds([Double])`.
    public static func durationsSeconds(_ samples: [HRSample]) -> [Double] {
        let n = samples.count
        if n == 0 { return [] }
        if n == 1 { return [1.0] }
        var raw = [Double]()
        raw.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let d = Double(samples[i + 1].ts - samples[i].ts)
            raw.append(d > 0 ? d : 1.0)
        }
        let cap = max(2.0 * BandScores.median(raw), 60.0)
        var dt = raw
        for i in 0..<dt.count { dt[i] = min(dt[i], cap) }
        dt.append(dt[dt.count - 1])
        return dt
    }

    /// Empty series → nil. `times` in seconds, `hr` in bpm, same length, time-ordered.
    public static func strain(times: [Double], hr: [Double], maxHR: Double, restingHR: Double,
                              params: Params) -> Double? {
        guard !times.isEmpty, !hr.isEmpty, maxHR > 1e-6 else { return nil }
        let L = load(times: times, hr: hr, maxHR: maxHR, restingHR: restingHR, params: params)
        return strain(load: L, params: params)
    }

    public static func load(times: [Double], hr: [Double], maxHR: Double, restingHR: Double,
                            params: Params) -> Double {
        let n = min(times.count, hr.count)
        guard n > 0, maxHR > 1e-6 else { return 0 }
        let dt = durationsSeconds(Array(times.prefix(n)))
        let xRest = restingHR / maxHR
        var L = 0.0
        for i in 0..<n {
            L += weight(hr: hr[i], maxHR: maxHR, xRest: xRest, params: params) * (dt[i] / 60.0)
        }
        return L
    }

    /// Per-minute load `w` at `hr` bpm.
    public static func weight(hr: Double, maxHR: Double, restingHR: Double, params: Params) -> Double {
        guard maxHR > 1e-6 else { return 0 }
        return weight(hr: hr, maxHR: maxHR, xRest: restingHR / maxHR, params: params)
    }

    public static func weight(hr: Double, maxHR: Double, xRest: Double, params: Params) -> Double {
        guard maxHR > 1e-6 else { return 0 }
        let x = min(max(hr / maxHR, 0), 1.5)
        if x <= xRest { return 0 }
        if x < 0.50 {
            let span = max(0.50 - xRest, 1e-6)
            let xb = min(max((x - xRest) / span, 0), 1)
            return params.wSed * pow(xb, max(params.qSed, 0.2))
        }
        let wz = params.wZones
        guard wz.count >= 6 else { return 0 }
        if x < 0.60 { return wz[1] }
        if x < 0.70 { return wz[2] }
        if x < 0.80 { return wz[3] }
        if x < 0.90 { return wz[4] }
        return wz[5]
    }

    /// `L = w0·m0 + … + w5·m5` with `m` in minutes, then the same sat-exp map.
    public static func strain(zoneMinutes minutes6: [Double], params: Params) -> Double {
        strain(load: load(zoneMinutes: minutes6, params: params), params: params)
    }

    public static func load(zoneMinutes minutes6: [Double], params: Params) -> Double {
        let n = min(minutes6.count, params.wZones.count)
        var L = 0.0
        for i in 0..<n { L += minutes6[i] * params.wZones[i] }
        return L
    }

    public static func strain(load L: Double, params: Params) -> Double {
        let L = max(L, 0)
        if L == 0 { return 0 }
        let k = max(params.k, 1e-15)
        let p = min(max(params.p, 0.15), 3.0)
        let s = params.maxStrain * (1.0 - exp(-k * pow(L, p)))
        return min(max(s, 0), params.maxStrain)
    }

    /// Stored Effort 0–100 = strain21 × 100/21. Nil stays nil.
    public static func effort100(_ strain21: Double?) -> Double? {
        strain21.map { StrainScorer.effortValue(fromWhoopStrain: $0) }
    }

    /// Each sample is credited with `dt_i = t_{i+1} − t_i`, capped at
    /// `max(2 × median positive interval, 60 s)`. Last sample reuses the previous `dt`.
    /// `dt ≤ 0` is treated as 1 s. Empty → `[]`; a single sample → `[1]`.
    public static func durationsSeconds(_ times: [Double]) -> [Double] {
        let n = times.count
        if n == 0 { return [] }
        if n == 1 { return [1.0] }
        var raw = [Double]()
        raw.reserveCapacity(n - 1)
        for i in 0..<(n - 1) {
            let d = times[i + 1] - times[i]
            raw.append(d > 0 ? d : 1.0)
        }
        let cap = max(2.0 * BandScores.median(raw), 60.0)
        var dt = raw.map { min($0, cap) }
        dt.append(dt[dt.count - 1])
        return dt
    }
}

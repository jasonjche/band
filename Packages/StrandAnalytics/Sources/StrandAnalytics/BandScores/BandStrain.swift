import Foundation
import WhoopProtocol

/// Fitted WHOOP-like day/activity strain on the 0–21 axis (PORT.md / whoopfit7).
///
/// Per-sample load `w` on %HRmax, integrated with a median-gap cap, then
/// `21 · (1 − exp(−k · L^p))`. Sleep at or below resting HR contributes 0.
/// Day strain is `strain(L_day)` over the calendar day's strap HR, never a sum of
/// activity strains. Activity strain is the same map over the workout window.
/// When a workout's window has under 50% strap-HR coverage, that workout's load is
/// added to `L_day` (strap samples inside the window are dropped so they are not
/// counted twice) and the 0–21 map saturates. Day strain is then at least the day's
/// highest activity strain.
///
/// Storage elsewhere keeps Effort 0–100 = strain21 × 100/21; this type returns 0–21.
public enum BandStrain {

    public static let expectedSchemaVersion = 1
    public static let defaultRestingHR = 60.0
    /// Strap-HR seconds / window seconds below which a workout's load is added to `L_day`.
    public static let strapCoverageThreshold = 0.5

    /// A logged workout that may fill a hole in the day's strap HR.
    public struct WorkoutContribution: Equatable {
        public var startTs: Int
        public var endTs: Int
        public var samples: [HRSample]
        public var storedStrain21: Double?

        public init(startTs: Int, endTs: Int, samples: [HRSample] = [], storedStrain21: Double? = nil) {
            self.startTs = startTs
            self.endTs = endTs
            self.samples = samples
            self.storedStrain21 = storedStrain21
        }
    }

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

    /// Inverse of `strain(load:)`: `L = (−ln(1 − S/maxStrain)/k)^(1/p)`.
    public static func load(fromStrain s: Double, params: Params) -> Double? {
        guard s > 0, s < params.maxStrain, params.k > 0, params.p > 0 else { return nil }
        return pow(-log(1 - s / params.maxStrain) / params.k, 1 / params.p)
    }

    /// Unique strap-HR seconds in `[start, end)` divided by the window length.
    public static func strapCoverage(samples: [HRSample], start: Int, end: Int) -> Double {
        let duration = end - start
        guard duration > 0 else { return 0 }
        var seen = Set<Int>()
        seen.reserveCapacity(min(samples.count, duration))
        for s in samples where s.ts >= start && s.ts < end {
            seen.insert(s.ts)
        }
        return Double(seen.count) / Double(duration)
    }

    /// Day strain with additive load from workouts whose strap-HR coverage is below 50%.
    /// When every workout is covered (or `workouts` is empty), identical to `strain(samples, ...)`.
    public static func dayStrain(_ samples: [HRSample],
                                 workouts: [WorkoutContribution],
                                 maxHR: Double, restingHR: Double,
                                 params: Params) -> Double? {
        let workouts = collapseOverlapping(workouts)
        let prepared = workouts.map { w -> (w: WorkoutContribution, coverage: Double, load: Double?, strain21: Double?) in
            let coverage = strapCoverage(samples: samples, start: w.startTs, end: w.endTs)
            let pair = workoutLoadAndStrain21(w, maxHR: maxHR, restingHR: restingHR, params: params)
            return (w, coverage, pair.load, pair.strain21)
        }
        let gaps = prepared.filter { $0.coverage < strapCoverageThreshold }
        if gaps.isEmpty {
            return strain(samples, maxHR: maxHR, restingHR: restingHR, params: params)
        }
        let excluded = samples.filter { s in
            !gaps.contains { $0.w.startTs <= s.ts && s.ts < $0.w.endTs }
        }
        var L = load(excluded, maxHR: maxHR, restingHR: restingHR, params: params)
        var maxActivity = 0.0
        for item in prepared {
            if let s = item.strain21 { maxActivity = max(maxActivity, s) }
            if item.coverage < strapCoverageThreshold, let extra = item.load {
                L += extra
            }
        }
        return max(strain(load: L, params: params), maxActivity)
    }

    /// Keep one row per overlapping session so an Apple import and a strap/manual copy
    /// of the same window cannot add load twice. Prefer the row that has HR samples.
    static func collapseOverlapping(_ workouts: [WorkoutContribution]) -> [WorkoutContribution] {
        let sorted = workouts.sorted {
            $0.startTs < $1.startTs || ($0.startTs == $1.startTs && $0.endTs < $1.endTs)
        }
        var kept: [WorkoutContribution] = []
        for w in sorted {
            if let i = kept.firstIndex(where: { overlapFraction($0, w) >= 0.5 }) {
                kept[i] = prefer(kept[i], w)
            } else {
                kept.append(w)
            }
        }
        return kept
    }

    private static func overlapFraction(_ a: WorkoutContribution, _ b: WorkoutContribution) -> Double {
        let start = max(a.startTs, b.startTs)
        let end = min(a.endTs, b.endTs)
        let span = min(max(0, a.endTs - a.startTs), max(0, b.endTs - b.startTs))
        guard span > 0, end > start else { return 0 }
        return Double(end - start) / Double(span)
    }

    private static func prefer(_ a: WorkoutContribution, _ b: WorkoutContribution) -> WorkoutContribution {
        if a.samples.isEmpty != b.samples.isEmpty { return a.samples.isEmpty ? b : a }
        if (a.storedStrain21 ?? 0) != (b.storedStrain21 ?? 0) {
            return (a.storedStrain21 ?? 0) >= (b.storedStrain21 ?? 0) ? a : b
        }
        return a
    }

    private static func workoutLoadAndStrain21(_ w: WorkoutContribution,
                                               maxHR: Double, restingHR: Double,
                                               params: Params) -> (load: Double?, strain21: Double?) {
        if !w.samples.isEmpty {
            let L = load(w.samples, maxHR: maxHR, restingHR: restingHR, params: params)
            return (L, strain(load: L, params: params))
        }
        if let s = w.storedStrain21, s > 0 {
            let clipped = min(s, params.maxStrain)
            let L = clipped < params.maxStrain ? load(fromStrain: clipped, params: params) : nil
            return (L, clipped)
        }
        return (nil, nil)
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

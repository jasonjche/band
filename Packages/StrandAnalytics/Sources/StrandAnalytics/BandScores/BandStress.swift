import Foundation
import WhoopProtocol

/// Baseline-relative 0–3 stress for Band's Native Stress Monitor.
///
/// Estimate only. There is no WHOOP stress series to fit. HR (and optional RMSSD)
/// versus the wearer's own overnight resting HR / HRV, 5-minute grain, existing
/// Low (<1) / Medium (<2) / High (≥2) bands.
///
/// DaytimeStress.baselineRelative is the unused hourly Oura-style scorer: waking
/// 06–22 only, logistic squash that maps baseline to 1.5 Medium, gravity masking,
/// RMSSD gated off. It does not meet sitting-at-rest → Low, sleep scoring, or
/// logged-workout exclusion, so this type does not call it.
public enum BandStress {

    /// Documented fallback when no night's resting HR exists.
    /// Same default `BandStrain` uses for %HRR.
    public static let defaultRestingHR = BandStrain.defaultRestingHR

    /// Prior nights used when today's `restingHr` / `avgHrv` is missing.
    public static let recentBaselineDays = 30

    /// Linear bpm per 0–3 band. High (2.0) is +24 bpm over the state baseline.
    /// DaytimeStress's validated High margin is +15 bpm over a daytime P10 floor
    /// via logistic squash (baseline → 1.5). Sitting at rest must read Low, so
    /// this is a linear ramp from overnight RHR instead. 12 is the round width
    /// that puts ordinary daytime (about RHR+14 on the plausibility set) in
    /// Medium and sitting near RHR in Low.
    public static let bpmPerBand: Double = 12

    /// RMSSD milliseconds per band, used only when the bucket has enough R-R.
    /// Typical night-to-night RMSSD spread is about 10–20 ms.
    public static let rmssdPerBand: Double = 20

    /// Mix on the HRV term. Daytime wrist RMSSD is artifact-dominated
    /// (`DaytimeStress.daytimeRMSSDScoringEnabled` is false); 0.25 keeps HR-only
    /// in charge when R-R is sparse or noisy.
    public static let hrvWeight: Double = 0.25

    /// Clamp on the HRV term so an artifact 400 ms RMSSD cannot zero the score.
    public static let hrvTermClamp: Double = 2

    /// Shared High-band floor (2.0) with the existing Native labels.
    public static let highBandFloor: Double = 2.0

    /// Native chart / store grain.
    public static let bucketSeconds: Int = 300

    public struct Baselines: Equatable, Sendable {
        public var wakeRestingHR: Double
        public var sleepRestingHR: Double
        public var rmssd: Double?

        public init(wakeRestingHR: Double, sleepRestingHR: Double, rmssd: Double?) {
            self.wakeRestingHR = wakeRestingHR
            self.sleepRestingHR = sleepRestingHR
            self.rmssd = rmssd
        }

        /// No personal history: both states use `defaultRestingHR`, HR-only.
        public static let fallback = Baselines(
            wakeRestingHR: BandStress.defaultRestingHR,
            sleepRestingHR: BandStress.defaultRestingHR,
            rmssd: nil
        )

        /// Day's overnight RHR, else median of recent nights, else 60.
        /// HRV baseline is day's `avgHrv`, else recent median, else nil (HR-only).
        /// Wake and sleep slots currently share that overnight RHR so a later
        /// daytime floor cannot leak into sleep scoring.
        public static func resolve(dayRestingHR: Double?, recentRestingHRs: [Double],
                                   dayRMSSD: Double?, recentRMSSDs: [Double]) -> Baselines {
            let rhr = positive(dayRestingHR) ?? median(recentRestingHRs) ?? BandStress.defaultRestingHR
            let hrv = positive(dayRMSSD) ?? median(recentRMSSDs)
            return Baselines(wakeRestingHR: rhr, sleepRestingHR: rhr, rmssd: hrv)
        }
    }

    public enum Outcome: Equatable, Sendable {
        case value(Double)
        case excluded
        case gap
    }

    /// Workout windows are excluded. Missing HR is a gap. Otherwise 0–3.
    public static func evaluate(bpm: Double?, rmssd: Double? = nil,
                                isWorkout: Bool, isAsleep: Bool,
                                baselines: Baselines) -> Outcome {
        if isWorkout { return .excluded }
        guard let bpm else { return .gap }
        return .value(score(bpm: bpm, rmssd: rmssd, isAsleep: isAsleep, baselines: baselines))
    }

    /// 0–3 for a bucket that has HR and is not a workout.
    public static func score(bpm: Double, rmssd: Double? = nil, isAsleep: Bool,
                             baselines: Baselines) -> Double {
        let ref = isAsleep ? baselines.sleepRestingHR : baselines.wakeRestingHR
        let hrTerm = (bpm - ref) / bpmPerBand
        let raw: Double
        if let rmssd, let base = baselines.rmssd, rmssdPerBand > 0 {
            let hrvTerm = clamp((base - rmssd) / rmssdPerBand, -hrvTermClamp, hrvTermClamp)
            raw = (1 - hrvWeight) * hrTerm + hrvWeight * hrvTerm
        } else {
            raw = hrTerm
        }
        return clamp(raw, 0, 3)
    }

    /// RMSSD per `bucketSeconds` bucket via `HRVAnalyzer`. Buckets with too few
    /// clean beats are omitted (HR-only).
    public static func rmssdByBucket(rr: [(ts: Int, ms: Double)],
                                     bucketSeconds: Int = bucketSeconds) -> [Int: Double] {
        guard bucketSeconds > 0 else { return [:] }
        var groups: [Int: [Double]] = [:]
        for sample in rr {
            let key = floorDiv(sample.ts, bucketSeconds) * bucketSeconds
            groups[key, default: []].append(sample.ms)
        }
        var out: [Int: Double] = [:]
        out.reserveCapacity(groups.count)
        for (key, values) in groups {
            if let rmssd = HRVAnalyzer.analyze(rawRR: values).rmssd {
                out[key] = rmssd
            }
        }
        return out
    }

    /// Share of scored overnight windows in the High band, 0...100. Nil when
    /// nothing scored. Empty windows are gaps, not Low.
    public static func overnightHighShare(hr: [HRSample], startTs: Int, endTs: Int,
                                          baselines: Baselines,
                                          windowSeconds: Int = bucketSeconds) -> Double? {
        overnightHighShare(
            samples: hr.map { (ts: $0.ts, bpm: Double($0.bpm)) },
            startTs: startTs, endTs: endTs, baselines: baselines,
            windowSeconds: windowSeconds
        )
    }

    public static func overnightHighShare(samples: [(ts: Int, bpm: Double)],
                                          startTs: Int, endTs: Int,
                                          baselines: Baselines,
                                          windowSeconds: Int = bucketSeconds) -> Double? {
        let levels = windowLevels(
            samples: samples, startTs: startTs, endTs: endTs,
            baselines: baselines, windowSeconds: windowSeconds
        )
        return highShare(levels)
    }

    public static func windowLevels(samples: [(ts: Int, bpm: Double)],
                                    startTs: Int, endTs: Int,
                                    baselines: Baselines,
                                    windowSeconds: Int = bucketSeconds) -> [Double?] {
        guard endTs > startTs, windowSeconds > 0 else { return [] }
        var buckets: [Int: (sum: Double, n: Int)] = [:]
        for sample in samples where sample.ts >= startTs && sample.ts < endTs {
            let idx = (sample.ts - startTs) / windowSeconds
            var entry = buckets[idx] ?? (0, 0)
            entry.sum += sample.bpm
            entry.n += 1
            buckets[idx] = entry
        }
        return buckets.keys.sorted().map { key in
            let entry = buckets[key]!
            let mean = entry.sum / Double(entry.n)
            return score(bpm: mean, isAsleep: true, baselines: baselines)
        }
    }

    public static func highShare(_ levels: [Double?], floor: Double = highBandFloor) -> Double? {
        var high = 0
        var scored = 0
        for level in levels {
            guard let level else { continue }
            scored += 1
            if level >= floor { high += 1 }
        }
        guard scored > 0 else { return nil }
        return Double(high) / Double(scored) * 100
    }

    /// True when `[bucketTs, bucketTs + bucketSeconds)` overlaps `[start, end)`.
    public static func overlaps(bucketTs: Int, start: Int, end: Int,
                                bucketSeconds: Int = bucketSeconds) -> Bool {
        guard end > start, bucketSeconds > 0 else { return false }
        return bucketTs < end && (bucketTs + bucketSeconds) > start
    }

    static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b, r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? q - 1 : q
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    static func median(_ values: [Double]) -> Double? {
        let xs = values.filter { $0.isFinite && $0 > 0 }.sorted()
        guard !xs.isEmpty else { return nil }
        let n = xs.count
        if n % 2 == 1 { return xs[n / 2] }
        return 0.5 * (xs[n / 2 - 1] + xs[n / 2])
    }
}

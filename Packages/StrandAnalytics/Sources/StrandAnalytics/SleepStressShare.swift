import Foundation
import WhoopProtocol

// SleepStressShare.swift — share of an overnight HR series spent in the Stress Monitor HIGH band.
//
// DISPLAY ONLY. Never written to a score, never stored, never a recovery / rest / strain input.
// A new physiological derivation: default-off Experimental on the Native shell, and the row is
// hidden when this returns nil.
//
// Method: slice overnight HR into fixed windows, score each window with the SAME 0–3 function
// the Stress Monitor's intraday series uses (`DaytimeStress.rawScore` + `squash`), and report
// the percent of scored windows whose level is at or above `DaytimeStress.highBandFloor`.
// That is the HIGH band (2–3) on the shared scale; there is no second threshold.
//
// Baseline: the night's own windows, the way `.dayRelative` uses the day's own hours.
// `DaytimeStress.ScoringMode.baselineRelative` is a DAYTIME 10th-percentile HR floor
// (`daytime_hr`, ~15 bpm above waking calm). Applied overnight it would read recumbent sleep
// as systematically low. The nightly `resting_hr` baseline is the other way around (too low
// a floor for a relative-to-this-night share) and needs a history this display-only row does
// not have. So each night is its own calm reference: lower-quartile window mean HR, spread
// from the across-window SD, then the shared logistic. A flat night sits at ~1.5 (not HIGH);
// a night with a tense stretch surfaces that stretch against its own calm windows.
//
// HR-only: `DaytimeStress.daytimeRMSSDScoringEnabled` holds RMSSD out of the live 0–3 series
// (daytime wrist RMSSD is artifact-dominated). Overnight recumbent RMSSD is cleaner, but
// using it here would be a second formula for the same 0–3 scale. Follow the gate; `rawScore`
// already no-ops a nil RMSSD term, so this is HR z only.
//
// Tests recover multiple injected shares (0 / 25 / 50 / 75 / 100), not a single match.

public enum SleepStressShare {

    /// Window length in seconds. DaytimeStress buckets at one hour because its calm reference
    /// and sustained-high flag count hours; a night's share of *time* is more honest at five
    /// minutes (a 20-minute spike is four windows, not swallowed by an hour). Each window
    /// still uses DaytimeStress's 0–3 function.
    public static let windowSeconds: Int = 300

    /// HIGH-band floor on the shared 0–3 scale. Alias of `DaytimeStress.highBandFloor` so this
    /// row and the Stress Monitor cannot pick different cutoffs.
    public static var highBandFloor: Double { DaytimeStress.highBandFloor }

    /// Minimum HR samples in a window before its mean is trusted. Same sample-density as
    /// `DaytimeStress.minHourHRSamples` (~5 min at 1 Hz inside an hour), scaled to this window.
    public static func minWindowHRSamples(windowSeconds: Int = windowSeconds) -> Int {
        max(2, DaytimeStress.minHourHRSamples * windowSeconds / DaytimeStress.bucketSeconds)
    }

    /// Share of scored 0–3 levels at or above `DaytimeStress.highBandFloor`, as 0...100.
    /// Nil when no level is present. `nil` entries are unscored windows, not low stress.
    public static func percent(levels: [Double?]) -> Double? {
        var high = 0
        var scored = 0
        for level in levels {
            guard let level else { continue }
            scored += 1
            if level >= DaytimeStress.highBandFloor { high += 1 }
        }
        guard scored > 0 else { return nil }
        return Double(high) / Double(scored) * 100
    }

    /// Score each window mean HR with the night-relative 0–3 function and return the HIGH share.
    /// `nil` entries are left unscored (too little data), matching DaytimeStress's hour gate.
    public static func percent(meanHRs: [Double?]) -> Double? {
        let hrs = meanHRs.compactMap { $0 }
        guard !hrs.isEmpty else { return nil }
        let refHR = DaytimeStress.calmReference(hrs, calmIsLow: true)
        let sdHR = DaytimeStress.std(hrs, mean: DaytimeStress.mean(hrs))
        let levels: [Double?] = meanHRs.map { hr in
            guard let hr else { return nil }
            return DaytimeStress.squash(
                DaytimeStress.rawScore(hr: hr, meanHR: refHR, sdHR: sdHR,
                                       rmssd: nil, meanRMSSD: nil, sdRMSSD: 0)
            )
        }
        return percent(levels: levels)
    }

    /// Window overnight HR from `startTs` (inclusive) to `endTs` (exclusive) and return the
    /// HIGH-band share of scored windows.
    public static func percent(hr: [HRSample], startTs: Int, endTs: Int,
                               windowSeconds: Int = windowSeconds) -> Double? {
        guard endTs > startTs, windowSeconds > 0 else { return nil }
        var buckets: [Int: [Double]] = [:]
        for sample in hr where sample.ts >= startTs && sample.ts < endTs {
            let idx = (sample.ts - startTs) / windowSeconds
            buckets[idx, default: []].append(Double(sample.bpm))
        }
        let minN = minWindowHRSamples(windowSeconds: windowSeconds)
        let meanHRs: [Double?] = buckets.keys.sorted().map { key in
            let xs = buckets[key]!
            return xs.count >= minN ? DaytimeStress.mean(xs) : nil
        }
        return percent(meanHRs: meanHRs)
    }
}

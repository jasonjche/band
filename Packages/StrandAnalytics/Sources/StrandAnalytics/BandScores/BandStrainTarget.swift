import Foundation

/// Daily strain target (WHOOP Strain Coach): a closed range on the 0–21 axis plus
/// Restore / Maintain / Push, from this morning's recovery and the member's recent
/// day-strain history.
///
/// Personal: last `historyWindow` day strains (need `minHistory`), mapped in BandStrain
/// load space so equal steps are equal physiological load, then converted back.
/// Short / empty history uses `genericRange`, flagged `personalized == false`.
/// Nil only when recovery is unknown. No `Date()`.
public enum BandStrainTarget {

    public static let historyWindow = 42
    public static let minHistory = 14
    public static let minRangeWidth = 1.5

    public static let percentileFloor = 18.0
    public static let percentileSpan = 68.0
    public static let logisticMid = 50.0
    public static let logisticScale = 15.0
    public static let percentileHalfWidth = 14.0
    public static let percentileLoClip = 5.0
    public static let percentileHiClip = 95.0

    public static let genericCenterLo = 7.0
    public static let genericCenterSpan = 9.0
    public static let genericHalfWidth = 3.0

    public enum Label: String, Sendable, Equatable {
        case restore = "Restore"
        case maintain = "Maintain"
        case push = "Push"
    }

    public struct Result: Sendable, Equatable {
        public var range: ClosedRange<Double>
        public var label: Label
        public var personalized: Bool

        public init(range: ClosedRange<Double>, label: Label, personalized: Bool) {
            self.range = range
            self.label = label
            self.personalized = personalized
        }
    }

    /// WHOOP colour bands: Restore ≤ 33, Maintain 34–66, Push ≥ 67.
    public static func label(recovery: Double) -> Label {
        if recovery >= 67 { return .push }
        if recovery <= 33 { return .restore }
        return .maintain
    }

    /// `nil` when recovery is unknown. History shorter than `minHistory` → generic.
    public static func recommend(recovery: Double?, recentStrain21: [Double]) -> Result? {
        guard let recovery, recovery.isFinite else { return nil }
        let band = Self.label(recovery: recovery)
        let windowed = Array(recentStrain21.filter(\.isFinite).suffix(historyWindow))
        if windowed.count >= minHistory {
            return Result(
                range: personalRange(recovery: recovery, history: windowed),
                label: band,
                personalized: true
            )
        }
        return Result(
            range: genericRange(recovery: recovery),
            label: band,
            personalized: false
        )
    }

    /// Smoothed NOOP-shaped band: ~4–10 at recovery 0, ~13–19 at 100.
    public static func genericRange(recovery: Double) -> ClosedRange<Double> {
        let center = genericCenterLo + genericCenterSpan * logistic(recovery)
        return clampedRange(center - genericHalfWidth, center + genericHalfWidth)
    }

    public static func personalRange(recovery: Double, history: [Double]) -> ClosedRange<Double> {
        let xs = history.filter(\.isFinite)
        guard !xs.isEmpty else { return genericRange(recovery: recovery) }
        let values: [Double]
        if let params = BandStrain.bundledParams() {
            values = xs.map { load(strain21: $0, params: params) }
        } else {
            values = xs
        }
        let center = percentileFloor + percentileSpan * logistic(recovery)
        let loP = BandScores.clip(center - percentileHalfWidth, percentileLoClip, 90) / 100
        let hiP = BandScores.clip(center + percentileHalfWidth, 10, percentileHiClip) / 100
        var lo = percentile(values, max(0, min(loP, hiP)))
        var hi = percentile(values, max(loP, hiP))
        if let params = BandStrain.bundledParams() {
            lo = BandStrain.strain(load: lo, params: params)
            hi = BandStrain.strain(load: hi, params: params)
        }
        return clampedRange(lo, hi)
    }

    public static func logistic(_ recovery: Double) -> Double {
        let r = BandScores.clip(recovery, 0, 100)
        return 1.0 / (1.0 + exp(-(r - logisticMid) / logisticScale))
    }

    /// Linear-interpolated quantile. Empty → NaN. One value → that value.
    public static func percentile(_ values: [Double], _ p: Double) -> Double {
        let xs = values.filter(\.isFinite).sorted()
        let n = xs.count
        guard n > 0 else { return .nan }
        if n == 1 { return xs[0] }
        let q = BandScores.clip(p, 0, 1)
        let pos = q * Double(n - 1)
        let lo = Int(pos.rounded(.down))
        let hi = min(n - 1, Int(pos.rounded(.up)))
        if lo == hi { return xs[lo] }
        let w = pos - Double(lo)
        return xs[lo] * (1 - w) + xs[hi] * w
    }

    public static func load(strain21: Double, params: BandStrain.Params) -> Double {
        let maxS = params.maxStrain
        guard maxS > 0, params.k > 0, params.p > 0 else { return 0 }
        let s = BandScores.clip(strain21, 0, maxS - 1e-12)
        if s <= 0 { return 0 }
        let p = min(max(params.p, 0.15), 3.0)
        return pow(-log(1 - s / maxS) / max(params.k, 1e-15), 1 / p)
    }

    private static func clampedRange(_ loIn: Double, _ hiIn: Double) -> ClosedRange<Double> {
        var lo = loIn
        var hi = hiIn
        if hi < lo { swap(&lo, &hi) }
        if hi - lo < minRangeWidth {
            let mid = 0.5 * (lo + hi)
            lo = mid - minRangeWidth / 2
            hi = mid + minRangeWidth / 2
        }
        lo = BandScores.clip(lo, 0, 21)
        hi = BandScores.clip(hi, 0, 21)
        if hi < lo { swap(&lo, &hi) }
        if hi - lo < minRangeWidth {
            if lo <= 0 {
                lo = 0
                hi = min(21, minRangeWidth)
            } else {
                hi = 21
                lo = max(0, 21 - minRangeWidth)
            }
        }
        return lo...hi
    }
}

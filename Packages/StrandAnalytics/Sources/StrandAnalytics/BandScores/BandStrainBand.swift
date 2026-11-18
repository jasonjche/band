import Foundation
import WhoopProtocol

/// WHOOP activity-strain bands on the 0–21 axis.
///
/// Cut-offs: 0–9.9 Light, 10–13.9 Moderate, 14–17.9 Strenuous, 18–21 All Out.
public enum BandStrainBand: String, Sendable, Equatable {
    case light = "Light"
    case moderate = "Moderate"
    case strenuous = "Strenuous"
    case allOut = "All Out"

    public static let lightUpper = 10.0
    public static let moderateUpper = 14.0
    public static let strenuousUpper = 18.0

    public static func band(strain21 raw: Double) -> BandStrainBand {
        // Band the value as displayed (one decimal), so a shown "18.0" is never "Strenuous".
        let strain21 = (raw * 10).rounded() / 10
        if strain21 < lightUpper { return .light }
        if strain21 < moderateUpper { return .moderate }
        if strain21 < strenuousUpper { return .strenuous }
        return .allOut
    }
}

/// Live-activity numbers from the same BandStrain + Keytel path a saved workout uses.
public enum LiveActivityScoring {

    /// Activity strain on the 0–21 axis. Empty series → nil.
    public static func strain21(samples: [HRSample], maxHR: Double, restingHR: Double) -> Double? {
        guard let params = BandStrain.bundledParams() else { return nil }
        return BandStrain.strain(samples, maxHR: maxHR, restingHR: restingHR, params: params)
    }

    /// Stored Effort 0–100 = strain21 × 100/21. Same map `NativeStrain.score` writes on the row.
    public static func effort100(samples: [HRSample], maxHR: Double, restingHR: Double) -> Double? {
        BandStrain.effort100(strain21(samples: samples, maxHR: maxHR, restingHR: restingHR))
    }

    public static func band(strain21: Double) -> BandStrainBand {
        BandStrainBand.band(strain21: strain21)
    }

    /// Keytel bout calories. Nil when there is no window or the estimate is not positive.
    public static func calories(
        samples: [HRSample],
        profile: UserProfile,
        maxHR: Double,
        restingHR: Double
    ) -> Double? {
        guard samples.count >= 2 else { return nil }
        let kcal = Calories.estimateBoutCalories(
            samples, profile: profile, hrmax: maxHR, restingHR: restingHR
        ).0
        return kcal > 0 ? kcal : nil
    }

    public static func averageHr(_ samples: [HRSample]) -> Int? {
        guard !samples.isEmpty else { return nil }
        return Int((Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)).rounded())
    }

    public static func peakHr(_ samples: [HRSample]) -> Int? {
        samples.map(\.bpm).max()
    }

    /// Recovery sports (sauna, ice bath, …) have no activity strain.
    public static func showsActivityStrain(_ sport: String) -> Bool {
        ActivityScoring.contributesActivityStrain(sport)
    }

    /// Distance + pace on the live screen: outdoor run, walk, cycle.
    public static func showsDistancePace(_ sport: String) -> Bool {
        let key = sport.lowercased().filter { !$0.isWhitespace }
        return key == "running" || key == "walking" || key == "cycling"
    }
}

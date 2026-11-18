import Foundation

/// Portable strain hat from cycle energy, Edwards TRIMP, and zone-4–5 minutes.
public enum BandLoadIndex {

    public struct Params: Sendable {
        public var intercept: Double
        public var logEnergy: Double
        public var logEdwards: Double
        public var wZ45: Double
        public var logEnergyMedianTrain: Double
        public var logEdwardsMissing: Double
        public var wZ45Missing: Double
    }

    /// Edwards TRIMP and zone-4–5 minutes for one workout.
    /// `z1…z5` are percents of duration (0…100).
    public static func workout(durationMin: Double, z1: Double, z2: Double, z3: Double, z4: Double, z5: Double)
    -> (edwards: Double, z45: Double) {
        let edwards = durationMin * (1 * z1 + 2 * z2 + 3 * z3 + 4 * z4 + 5 * z5) / 100.0
        let z45 = durationMin * (z4 + z5) / 100.0
        return (edwards, z45)
    }

    public static func strainHat(energyKcal: Double, edwards: Double, z45Min: Double, params: Params) -> Double {
        let logE: Double
        if energyKcal.isFinite {
            logE = log1p(max(energyKcal, 0))
        } else {
            logE = params.logEnergyMedianTrain
        }
        let logEd: Double
        if edwards.isFinite {
            logEd = log1p(max(edwards, 0))
        } else {
            logEd = params.logEdwardsMissing
        }
        let z = z45Min.isFinite ? z45Min : params.wZ45Missing
        return params.intercept + params.logEnergy * logE + params.logEdwards * logEd + params.wZ45 * z
    }
}
